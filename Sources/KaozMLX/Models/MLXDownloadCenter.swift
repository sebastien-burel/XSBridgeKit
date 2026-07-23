import Foundation
import KaozKit
import Observation

/// `@Observable` orchestrator for MLX model downloads. UI views bind
/// to `inflight[modelID]` to render progress bars; the wiki preload
/// task routes through it too so downloads can be deduplicated
/// (kicking off twice in a row reuses the same task).
///
/// All state lives on the MainActor — that's where UI binds, and the
/// underlying `MLXModelStore` already hops there for progress
/// callbacks, so the boundary is consistent.
@Observable @MainActor
public final class MLXDownloadCenter {
    public init() {}

    /// Progress (0…1) keyed by HuggingFace slug. Absent = not
    /// currently downloading. Present at 1.0 means just finished —
    /// the entry stays around briefly so the UI can flash a
    /// completion state before disappearing.
    public var inflight: [String: Double] = [:]

    /// Latest failure per modelID — surfaced inline in the
    /// management UI. Cleared when a fresh download starts.
    public var lastError: [String: String] = [:]

    @ObservationIgnored private var tasks: [String: Task<URL, Error>] = [:]

    /// Triggers a download (or joins an existing one). Returns the
    /// local directory when done, throws on failure. Idempotent for
    /// already-installed models — returns the cached path immediately.
    @discardableResult
    public func download(_ modelID: String) async throws -> URL {
        if let existing = tasks[modelID] {
            return try await existing.value
        }
        lastError.removeValue(forKey: modelID)
        inflight[modelID] = 0

        let task = Task<URL, Error> { [weak self] in
            do {
                let url = try await MLXModelStore.shared.download(
                    modelID: modelID
                ) { [weak self] progress in
                    self?.inflight[modelID] = progress
                }
                self?.inflight[modelID] = 1.0
                // Brief grace period so the UI can render the
                // "100%" state before the row reverts to the
                // installed checkmark.
                try? await Task.sleep(for: .milliseconds(400))
                self?.inflight.removeValue(forKey: modelID)
                self?.tasks.removeValue(forKey: modelID)
                return url
            } catch {
                self?.inflight.removeValue(forKey: modelID)
                self?.tasks.removeValue(forKey: modelID)
                self?.lastError[modelID] = (error as? LocalizedError)?
                    .errorDescription ?? error.localizedDescription
                throw error
            }
        }
        tasks[modelID] = task
        return try await task.value
    }

    /// Cancels an in-flight download. Best-effort — partial files
    /// stay on disk and get cleaned up by the next launch's GC pass.
    public func cancel(_ modelID: String) {
        tasks[modelID]?.cancel()
        tasks.removeValue(forKey: modelID)
        inflight.removeValue(forKey: modelID)
    }

    /// Wraps `MLXModelStore.remove` so views observing this center
    /// trigger a re-render via the `removalTick` change.
    public var removalTick: Int = 0
    public func remove(_ modelID: String) {
        MLXModelStore.shared.remove(modelID: modelID)
        removalTick &+= 1
        lastError.removeValue(forKey: modelID)
    }
}
