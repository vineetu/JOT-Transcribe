import Foundation

/// Temporary file-write diagnostic for Speaker Labels investigation.
/// Bypasses os_log (privacy redaction) and the ErrorLog actor (currently
/// not writing to disk on macOS 26 builds for unknown reasons).
/// Appends a single line per call to ~/Library/Logs/Jot/sortformer-diag.log.
enum SortformerDiag {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Jot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sortformer-diag.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: Data(line.utf8))
    }
}
