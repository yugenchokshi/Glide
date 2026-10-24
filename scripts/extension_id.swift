// Prints the Chrome extension id fixed by the "key" in Extensions/chrome/manifest.json and checks
// it against ExtensionBridge.extensionID (the id the app accepts connections from).
//
//   swift scripts/extension_id.swift [path/to/manifest.json]
//
// Chrome derives an unpacked extension's id from its public key: the first 32 hex characters of
// SHA-256 over the DER-encoded key, with 0-9a-f mapped to a-p.
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manifestURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Extensions/chrome/manifest.json")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    fail("Couldn't read \(manifestURL.path)")
}
guard let key = manifest["key"] as? String, let der = Data(base64Encoded: key) else {
    fail("The manifest has no valid base64 \"key\".")
}

let letters = Array("abcdefghijklmnop")
let id = String(SHA256.hash(data: der).prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 0x0F)]] })
print(id)

let bridgeSource = root.appendingPathComponent("Sources/AutomationKit/Browser/ExtensionBridge.swift")
if let source = try? String(contentsOf: bridgeSource, encoding: .utf8) {
    if source.contains("extensionID = \"\(id)\"") {
        FileHandle.standardError.write(Data("ExtensionBridge.extensionID matches.\n".utf8))
    } else {
        fail("ExtensionBridge.extensionID doesn't match; set it to \"\(id)\" in \(bridgeSource.path).")
    }
}
