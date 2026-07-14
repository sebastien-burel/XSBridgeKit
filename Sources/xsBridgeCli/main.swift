import Foundation
import XSBridgeKit
import XSBridgeCliC


@_cdecl("xsbGetCurrentTime")
func xsbGetCurrentTime(_ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
  return strdup(formatter.string(from: Date()))
}


var c = XSCreation()
c.initialChunkSize = 1 * 1024 * 1024
c.incrementalChunkSize = 1 * 1024 * 1024
c.initialHeapCount = (1 * 1024 * 1024) >> 1
c.incrementalHeapCount = (1 * 1024 * 1024) >> 1
c.stackCount = 256 * 1024
c.initialKeyCount = 1024
c.incrementalKeyCount = 1024
c.nameModulo = 1993
c.symbolModulo = 127
c.parserBufferSize = 64 * 1024
c.parserTableModulo = 1993

guard let engine = XSEngine(creation:c) else { exit(1) }
engine.withMachine {
  xsBridgeCliInstall($0)
}

do {
  if CommandLine.arguments.count > 1 {
    // argv[1...] = fichiers JS, exécutés en séquence comme modules ES sur la
    // même machine (chargés par fxFindModule/fxLoadModule côté C — imports
    // relatifs contre l'importeur, extensions explicites, top-level await ;
    // cache de modules partagé entre les runs). Un argument qui n'est pas un
    // fichier existant est le JSON de paramètres du module qui le précède
    // (passé à son export default via JSON.parse). Throw si un module rejette.
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
      let path = args[i]
      var params: String? = nil
      if i + 1 < args.count, !FileManager.default.fileExists(atPath: args[i + 1]) {
        params = args[i + 1]
        i += 1
      }
      try engine.runModule(path, params: params)
      i += 1
    }
  }
  else {
    let src = "print('now=' + getCurrentTime());\n"
    print(try engine.eval(src))
    engine.runUntilIdle()
  }
}
catch {
  FileHandle.standardError.write(Data("JS error: \(error)\n".utf8))
  exit(1)

}
