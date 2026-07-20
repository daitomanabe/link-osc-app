import Foundation

/// Rare lifecycle and failure-transition events only. Never call from an audio callback.
/// JSON Lines keeps the file useful to both humans and diagnostic tools.
final class RuntimeLog {
    static let shared = RuntimeLog()

    private let queue = DispatchQueue(label: "linkosc.runtime-log", qos: .utility)
    private let fileURL: URL
    private let maxBytes: UInt64 = 512 * 1024

    var path: String { fileURL.path }

    private init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LinkOSC", isDirectory: true)
        fileURL = logs.appendingPathComponent("runtime.log")
        do {
            try FileManager.default.createDirectory(
                at: logs, withIntermediateDirectories: true)
            rotateIfNeeded()
        } catch {
            // Logging must never prevent the app from starting.
        }
    }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        queue.async { [fileURL, maxBytes] in
            var record = fields
            record["event"] = name
            record["time"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys]),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let bytes = line.data(using: .utf8) else { return }
            do {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   UInt64(size) + UInt64(bytes.count) > maxBytes {
                    let old = fileURL.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: fileURL, to: old)
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
                try handle.close()
            } catch {
                // A diagnostic side channel must not affect realtime operation.
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) > maxBytes else { return }
        let old = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
