import Foundation
import KaozKit
import Observation

/// Single source of truth for the MLX model catalog, driven by the
/// `TyKaoz/models-manifest` Hugging Face manifest instead of a list
/// compiled into the app.
///
/// Resolution order, freshest wins: **network > disk cache > embedded
/// fallback**. At construction the best already-available catalog loads
/// synchronously (cache, else the embedded minimal fallback) so the
/// first UI read is never empty; `refresh()` then pulls the live
/// manifest and updates the disk cache. Network failure is non-fatal —
/// the app stays usable offline on first launch via the fallback.
@Observable @MainActor
public final class ModelCatalogService {
    static public let shared = ModelCatalogService()

    public enum Source: String { case bundle, cache, network }

    public private(set) var models: [CatalogModel] = []
    public private(set) var updatedAt: String?
    public private(set) var source: Source = .bundle

    /// Read from `main` so the catalog is always current; the weights
    /// each entry points to are pinned by `revision` for reproducibility.
    private static let manifestURL = URL(
        string: "https://huggingface.co/TyKaoz/models-manifest/resolve/main/models.json"
    )!

    private init() {
        if let data = Self.readCache(), let manifest = try? Self.decode(data) {
            apply(manifest, source: .cache)
        } else if let manifest = try? Self.decode(Data(Self.bundledManifestJSON.utf8)) {
            apply(manifest, source: .bundle)
        }
    }

    /// Embedding models, in manifest order (the order they appear in
    /// `models.json`).
    public var embeddings: [CatalogModel] { models.filter { $0.category == .embedding } }

    /// Chat models, in manifest order (the order they appear in
    /// `models.json`).
    public var chats: [CatalogModel] { models.filter { $0.category == .chat } }

    /// Look up a catalog entry by its HuggingFace slug.
    public func entry(forID id: String) -> CatalogModel? { models.first { $0.id == id } }

    /// Fetches the live manifest; on success swaps the catalog in and
    /// refreshes the disk cache. Offline or malformed responses are
    /// swallowed so the cache/bundle catalog keeps serving.
    public func refresh() async {
        do {
            var request = URLRequest(url: Self.manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let manifest = try Self.decode(data)
            apply(manifest, source: .network)
            Self.writeCache(data)
        } catch {
            // Keep whatever (cache/bundle) loaded at init.
        }
    }

    // MARK: - Internals

    private func apply(_ manifest: ModelManifest, source: Source) {
        models = manifest.models
        updatedAt = manifest.updatedAt
        self.source = source
    }

    private static func decode(_ data: Data) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    // MARK: - Disk cache

    private static var cacheURL: URL {
        URL.cachesDirectory.appendingPathComponent("tykaoz-models.json", isDirectory: false)
    }
    private static func readCache() -> Data? { try? Data(contentsOf: cacheURL) }
    private static func writeCache(_ data: Data) { try? data.write(to: cacheURL, options: .atomic) }

    // MARK: - Offline fallback

    /// Minimal catalog embedded in the binary, used only when there's no
    /// cache yet and the network is unreachable on first launch. Holds the
    /// recommended embedder plus two light chat models so the app is
    /// usable offline; the full catalog arrives from the network.
    static public let bundledManifestJSON = """
    {
      "schema_version": 2,
      "updated_at": "2026-06-07",
      "models": [
        {
          "id": "TyKaoz/bge-m3-4bit",
          "name": "BGE-M3 (4-bit)",
          "publisher": "BAAI",
          "description": "Multilingue (100+ langues), 1024 dim. Bon défaut pour un wiki en français.",
          "category": "embedding",
          "runner": "mlx-embeddings",
          "quant": "4-bit",
          "min_ram_gb": 4,
          "recommended_ram_gb": 8,
          "recommended": true,
          "languages": ["en", "fr", "es", "de", "it", "pt", "zh", "ja", "ko", "ar", "ru", "hi"],
          "size_bytes": 337056865,
          "dimension": 1024,
          "max_seq_len": 8192
        },
        {
          "id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
          "name": "Llama 3.2 3B Instruct (4-bit)",
          "publisher": "Meta",
          "description": "Multilingue, instruction-tuned, ~2 Go. Bon défaut pour un Mac 16 Go.",
          "category": "chat",
          "runner": "mlx-lm",
          "quant": "4-bit",
          "min_ram_gb": 8,
          "recommended_ram_gb": 16,
          "recommended": true,
          "languages": ["en", "fr", "es", "de", "it", "pt", "hi", "th"],
          "size_bytes": 2147483648,
          "context_length": 131072,
          "modalities": ["text"],
          "params_total": 3.2,
          "params_active": 3.2
        },
        {
          "id": "mlx-community/Llama-3.2-1B-Instruct-4bit",
          "name": "Llama 3.2 1B Instruct (4-bit)",
          "publisher": "Meta",
          "description": "Très léger (~750 Mo). Pour tester le pipeline ou un Mac 8 Go.",
          "category": "chat",
          "runner": "mlx-lm",
          "quant": "4-bit",
          "min_ram_gb": 4,
          "recommended_ram_gb": 8,
          "recommended": false,
          "languages": ["en", "fr", "es", "de", "it", "pt", "hi", "th"],
          "size_bytes": 786432000,
          "context_length": 131072,
          "modalities": ["text"],
          "params_total": 1.2,
          "params_active": 1.2
        }
      ]
    }
    """
}
