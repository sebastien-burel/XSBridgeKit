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

// Leading flags, in any order:
//   --restore <snap>  : rebuild the machine from a snapshot before running.
//   --snapshot <snap> : write the machine to a snapshot after running.
// Combine them to persist a session: --restore in.xsbk --snapshot out.xsbk file.js
var args = Array(CommandLine.arguments.dropFirst())
var restorePath: String? = nil
var snapshotOut: String? = nil
while args.count >= 2, args[0] == "--restore" || args[0] == "--snapshot" {
  if args[0] == "--restore" { restorePath = args[1] } else { snapshotOut = args[1] }
  args.removeFirst(2)
}

let engine: XSEngine
if let restorePath {
  xsBridgeCliRegister()   // host table must be known before restoring
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: restorePath)),
        let restored = XSEngine(snapshot: data) else {
    FileHandle.standardError.write(Data("restore failed: \(restorePath)\n".utf8))
    exit(1)
  }
  engine = restored
} else {
  guard let fresh = XSEngine(creation: c) else { exit(1) }
  fresh.withMachine { xsBridgeCliInstall($0) }
  engine = fresh
}

do {
  if !args.isEmpty {
    // Les fichiers JS restants sont exécutés en séquence comme modules ES sur
    // la même machine (imports relatifs contre l'importeur, extensions
    // explicites, top-level await ; cache de modules partagé). Un argument qui
    // n'est pas un fichier existant est le JSON de paramètres du module qui le
    // précède (passé à son export default via JSON.parse).
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
  } else if restorePath == nil {
    let src = "print('now=' + getCurrentTime());\n"
    print(try engine.eval(src))
    engine.runUntilIdle()
  }

  // Après exécution, persiste la machine si demandé.
  if let snapshotOut {
    let data = try engine.writeSnapshot()
    try data.write(to: URL(fileURLWithPath: snapshotOut))
    FileHandle.standardError.write(Data("snapshot written: \(snapshotOut) (\(data.count) bytes)\n".utf8))
  }
}
catch {
  FileHandle.standardError.write(Data("JS error: \(error)\n".utf8))
  exit(1)
}
