import Foundation
import KaozKit
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Knows where MLX models live on disk and triggers HuggingFace
/// downloads via `swift-huggingface`'s `HubClient`. Sandboxed apps get
/// the hub cache redirected automatically; we surface the on-disk
/// path for the UI to show in the model-management pane (Phase B).
///
/// Phase A2: download + presence check only. The actual embedding
/// pipeline (model load into Metal, mean pooling, forward pass)
/// lands in commit A3 inside `MLXEmbeddingActor`.
@MainActor
public final class MLXModelStore {
    /// Singleton — there's only ever one HF cache directory per app
    /// instance, so a global makes sense.
    static public let shared = MLXModelStore()

    public enum Failure: LocalizedError {
        case insufficientDiskSpace(needed: Int64, available: Int64)
        case downloadFailed(modelID: String, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .insufficientDiskSpace(let needed, let available):
                let need = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Pas assez d'espace disque (besoin : \(need), dispo : \(have))."
            case .downloadFailed(let modelID, let err):
                if MLXModelStore.isTransientNetworkError(err) {
                    return """
                    Échec du téléchargement de « \(modelID) » : \
                    connexion réseau interrompue. Réessaie — le \
                    téléchargement reprend où il s'est arrêté.
                    """
                }
                return """
                Échec du téléchargement de « \(modelID) » : \
                \(err.localizedDescription). Vérifie que le slug est \
                un repo HuggingFace valide (ex : \
                `mlx-community/bge-m3-mlx-4bit`).
                """
            }
        }
    }

    /// True for URLSession errors a retry/resume can plausibly recover
    /// from (dropped connection, timeout, transient DNS) — as opposed
    /// to a 404 / invalid slug, which won't fix itself on retry.
    /// `nonisolated` so `Failure.errorDescription` (nonisolated) and the
    /// download retry loop can both call it.
    nonisolated static public func isTransientNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorResourceUnavailable,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorRequestBodyStreamExhausted:
            return true
        default:
            return false
        }
    }

    /// Expected on-disk size (bytes) from the catalog, used by the
    /// pre-flight check and the install heuristic. Approximate — HF
    /// reshards safetensors occasionally and the real size drifts.
    /// `0` when the slug isn't in the catalog (custom model).
    private func expectedSize(modelID: String) -> Int64 {
        ModelCatalogService.shared.entry(forID: modelID)?.sizeBytes ?? 0
    }

    /// Commit SHA the weights are pinned to, from the catalog. Falls
    /// back to `main` for slugs the catalog doesn't know.
    private func revision(modelID: String) -> String {
        ModelCatalogService.shared.entry(forID: modelID)?.revision ?? "main"
    }

    /// Macro-produced `Downloader` wrapping `HubClient`. Stored once
    /// so the type — opaque from the macro expansion — doesn't leak
    /// into property declarations.
    private let downloader: any Downloader
    private let tokenizerLoader: any TokenizerLoader

    private init() {
        // Default hub stores under `~/.cache/huggingface/hub/`, which
        // becomes `~/Library/Containers/<bundle id>/Data/.cache/...`
        // under the sandbox. Good for now — Phase B will let the
        // user pick a custom location.
        self.downloader = #hubDownloader()
        self.tokenizerLoader = #huggingFaceTokenizerLoader()
    }

    // MARK: - Presence

    /// Root of a model's repo on disk — `cache/models--<org>--<name>/`.
    /// This is where the actual weight files live (under `blobs/`);
    /// the `snapshots/` subdir holds symlinks pointing at them. We
    /// size + check presence at the repo level so symlinks vs.
    /// regular files don't trip us up.
    public func repoDirectory(modelID: String) -> URL? {
        guard let cacheRoot = hubCacheRoot() else { return nil }
        let slug = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let url = cacheRoot.appendingPathComponent(slug, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return url
    }

    /// Resolves the snapshot directory (the one holding the user-facing
    /// symlinks). Prefers the catalog-pinned revision when its snapshot
    /// is on disk, so an older cached revision isn't served after the
    /// manifest bumps `revision`. Falls back to any snapshot for custom
    /// (`main`) slugs or revision drift. `nil` when nothing is on disk.
    public func localDirectory(modelID: String) -> URL? {
        let pinned = revision(modelID: modelID)
        if pinned != "main", let dir = snapshotDirectory(modelID: modelID, revision: pinned) {
            return dir
        }
        guard let repo = repoDirectory(modelID: modelID) else { return nil }
        let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), let firstRevision = revisions.first else {
            return nil
        }
        return firstRevision
    }

    /// The on-disk snapshot directory for a specific revision, or `nil`
    /// if that exact revision isn't cached.
    private func snapshotDirectory(modelID: String, revision: String) -> URL? {
        guard let repo = repoDirectory(modelID: modelID) else { return nil }
        let dir = repo.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return dir
    }

    /// `true` when the model is on disk and its repo size is at
    /// least 90% of the expected size — catches half-downloaded
    /// snapshots while tolerating minor revision drift.
    public func isInstalled(modelID: String) -> Bool {
        let actual = sizeOnDisk(modelID: modelID)
        if actual == 0 { return false }
        let expected = expectedSize(modelID: modelID)
        if expected == 0 { return true }
        return actual >= Int64(Double(expected) * 0.9)
    }

    /// Bytes on disk for a specific model. Sized at the REPO level
    /// (includes the `blobs/` subdir where the real files live —
    /// the `snapshots/` subdir holds symlinks, not regular files).
    public func sizeOnDisk(modelID: String) -> Int64 {
        guard let dir = repoDirectory(modelID: modelID) else { return 0 }
        return (try? diskSize(of: dir)) ?? 0
    }

    // MARK: - Download

    /// Downloads a model from HuggingFace, reporting progress (0…1)
    /// via the closure. Idempotent: if the model is already on disk,
    /// returns the cached path immediately with progress = 1.
    ///
    /// Throws on disk-space shortage or network failure.
    @discardableResult
    public func download(
        modelID: String,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        // Serve the cache only when the *pinned* revision is on disk.
        // A custom (`main`) slug has no pinned SHA, so any cached
        // snapshot counts; a catalog model whose manifest `revision`
        // bumped won't match its stale snapshot, so we re-download the
        // new one instead of serving the old (e.g. a model re-quantized
        // to add a chat template).
        let pinned = revision(modelID: modelID)
        let hasPinnedRevision = pinned == "main"
            || snapshotDirectory(modelID: modelID, revision: pinned) != nil
        if hasPinnedRevision, isInstalled(modelID: modelID),
           let dir = localDirectory(modelID: modelID) {
            progressHandler(1.0)
            return dir
        }

        try preflightDiskSpace(for: modelID)

        // HuggingFace large-file downloads drop connections fairly often
        // ("The network connection was lost"). swift-huggingface caches
        // each completed file and resumes partial blobs, so a bounded
        // retry picks up roughly where it left off instead of restarting
        // from zero. Cancellation and genuine 404s are not retried.
        //
        // swift-huggingface samples the snapshot `Progress` every ~100 ms
        // during the transfer, byte-weighted across files, so forwarding
        // `fractionCompleted` gives a smooth bar instead of a 0→100 % jump.
        progressHandler(0)
        let maxAttempts = 5
        var attempt = 0
        while true {
            attempt += 1
            do {
                _ = try await resolve(
                    configuration: ModelConfiguration(
                        id: modelID,
                        revision: revision(modelID: modelID)
                    ),
                    from: downloader,
                    useLatest: false,
                    progressHandler: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in progressHandler(fraction) }
                    }
                )
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.isTransientNetworkError(error), attempt < maxAttempts, !Task.isCancelled {
                    // Linear backoff (2s, 4s, 6s, 8s), capped, then resume.
                    try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 8)))
                    continue
                }
                throw Failure.downloadFailed(modelID: modelID, underlying: error)
            }
        }
        progressHandler(1.0)

        guard let dir = localDirectory(modelID: modelID) else {
            throw Failure.downloadFailed(
                modelID: modelID,
                underlying: NSError(
                    domain: "MLXModelStore",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Modèle introuvable après téléchargement."]
                )
            )
        }
        return dir
    }

    // MARK: - Cache management

    /// Best-effort: removes the model's snapshot + blob directories.
    public func remove(modelID: String) {
        guard let cacheRoot = hubCacheRoot() else { return }
        let slug = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let repoRoot = cacheRoot.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.removeItem(at: repoRoot)
    }

    /// Total bytes occupied on disk by the whole HF cache.
    public func totalCacheSize() -> Int64 {
        guard let cacheRoot = hubCacheRoot() else { return 0 }
        return (try? diskSize(of: cacheRoot)) ?? 0
    }

    /// Lists all currently-installed model snapshots, newest first.
    /// Built by reading the `models--<org>--<name>/snapshots/<rev>/`
    /// pattern under the hub cache root. Used by the management
    /// view + LRU eviction.
    public struct InstalledModel {
        public let modelID: String
        public let directory: URL
        public let sizeBytes: Int64
        /// Modification date of the snapshot directory — proxy for
        /// "last touched". Used by the LRU eviction pass.
        public let touchedAt: Date
    }

    public func installedModels() -> [InstalledModel] {
        guard let root = hubCacheRoot() else { return [] }
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [InstalledModel] = []
        for repoDir in repos {
            let name = repoDir.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            // Decode `models--<org>--<name>` back to `<org>/<name>`.
            let stripped = name.dropFirst("models--".count)
            let slug = stripped.replacingOccurrences(of: "--", with: "/")

            let snapshotsRoot = repoDir.appendingPathComponent("snapshots", isDirectory: true)
            guard let revisions = try? fm.contentsOfDirectory(
                at: snapshotsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ), let snapshot = revisions.first else {
                continue
            }
            let size = (try? diskSize(of: repoDir)) ?? 0
            let touched = (try? snapshot.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            out.append(InstalledModel(
                modelID: slug,
                directory: snapshot,
                sizeBytes: size,
                touchedAt: touched
            ))
        }
        return out.sorted { $0.touchedAt > $1.touchedAt }
    }

    /// Touches a model's snapshot dir so the LRU pass treats it as
    /// recently used. Called from the embed actor after each load.
    public func touch(modelID: String) {
        guard let dir = localDirectory(modelID: modelID) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: dir.path
        )
    }

    /// LRU eviction. Walks installed models from oldest to newest
    /// and removes them until the total cache size fits under
    /// `capBytes`. Skips `pinned` (typically the currently-active
    /// embedding model) so the wiki doesn't lose its model mid-run.
    /// Returns the slugs evicted.
    @discardableResult
    public func evictIfOverCap(_ capBytes: Int64, pinned: Set<String> = []) -> [String] {
        var current = totalCacheSize()
        if current <= capBytes { return [] }

        // Oldest first.
        let candidates = installedModels()
            .filter { !pinned.contains($0.modelID) }
            .sorted { $0.touchedAt < $1.touchedAt }

        var evicted: [String] = []
        for victim in candidates {
            if current <= capBytes { break }
            remove(modelID: victim.modelID)
            current -= victim.sizeBytes
            evicted.append(victim.modelID)
        }
        return evicted
    }

    /// Root of the HF Hub cache for UI display. Under sandbox this
    /// resolves to `~/Library/Containers/<bundle id>/Data/Library/
    /// Caches/huggingface/hub/` — mirrors swift-huggingface's
    /// `CacheLocationProvider.defaultCacheDirectory()` sandboxed
    /// branch (kind: `<cachesDirectory>/huggingface/hub/`).
    public func hubCacheRoot() -> URL? {
        // swift-huggingface resolves the hub cache differently by environment:
        // the sandboxed app lands under `URL.cachesDirectory` (~/Library/
        // Containers/<id>/Data/Library/Caches/huggingface/hub), while an
        // unsandboxed build (e.g. kaoz) uses `~/.cache/huggingface/hub`.
        // Return whichever actually holds the cache so both work; fall back to
        // the sandbox location for a first download.
        var candidates: [URL] = []
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            candidates.append(URL(fileURLWithPath: hfHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true))
        }
        candidates.append(URL.cachesDirectory
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true))
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return candidates.first
    }

    // MARK: - Helpers

    private func preflightDiskSpace(for modelID: String) throws {
        let size = expectedSize(modelID: modelID)
        let needed = (size > 0 ? size : 500 * 1024 * 1024) * 2
        let available = freeDiskBytes()
        if available < needed {
            throw Failure.insufficientDiskSpace(needed: needed, available: available)
        }
    }

    private func freeDiskBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return 0 }
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private nonisolated func diskSize(of url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
