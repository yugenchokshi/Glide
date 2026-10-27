import Foundation

/// Appends real-time voice problems to ~/Library/Application Support/Glide/realtime.log, so a
/// failure whose notch caption is cut short can still be read in full.
enum RealtimeDiagnostics {
    private static let lock = NSLock()

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glide/realtime.log")
    }

    static func note(_ line: String) {
        lock.withLock {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Logs a server event's type (and, for the few that matter, its text), skipping the
    /// stream of audio and transcript deltas.
    static func event(_ frame: String) {
        guard let data = frame.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String, !type.hasSuffix(".delta") else { return }
        var line = "event \(type)"
        if let transcript = json["transcript"] as? String { line += ": \(transcript)" }
        if let name = json["name"] as? String { line += " \(name) \(json["arguments"] as? String ?? "")" }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { line += ": \(message)" }
        if type == "response.done", let response = json["response"] as? [String: Any] {
            line += " status=\(response["status"] ?? "?") \(response["status_details"].map { "\($0)" } ?? "")"
        }
        note(line)
    }
}
