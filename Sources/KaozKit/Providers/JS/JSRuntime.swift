import Foundation
import KaozJS
import KaozHostC

/// A tiny harness to exercise the native `__http` primitive + the
/// `XMLHttpRequest` shim in isolation, without a provider or an LLM. Creates a
/// bare engine, installs `__http`, imports the XHR shim module then evals
/// `script`, waits until idle, and returns the JSON value the script left on
/// `globalThis.__result`.
public enum JSHttpProbe {
    public static func run(script: String, timeout: TimeInterval = 15) -> String? {
        guard let engine = XSEngine() else { return nil }
        engine.withMachine { xsBridgeHttpInstall($0) }
        if let shimImport = JSResource.importStatement("xmlhttprequest") {
            _ = try? engine.eval(shimImport)   // resolves within eval's drain
        }
        _ = try? engine.eval(script)
        engine.runUntilIdle(timeout: timeout)
        return try? engine.eval("JSON.stringify(globalThis.__result ?? null)")
    }
}
