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
    // argv[1] = fichier JS, exécuté comme module ES (chargé par fxFindModule/
    // fxLoadModule côté C — imports relatifs contre l'importeur, extensions
    // explicites, top-level await). Throw si le module rejette.
    try engine.runModule(CommandLine.arguments[1])
    if CommandLine.arguments.count > 2 {
      try engine.runModule(CommandLine.arguments[2])
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
