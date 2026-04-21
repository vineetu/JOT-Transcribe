import Foundation
import os.log

/// Cross-cutting error log. Writes to ~/Library/Logs/Jot/jot.log.
/// Rolling 2MB cap — on rotate, renames current to jot.log.1 (overwriting any existing).
/// Nothing is ever sent off the device.
public actor ErrorLog {
    public static let shared = ErrorLog()

    public enum Level: String { case error = "ERROR", warn = "WARN", info = "INFO" }

    public static var logFileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Jot", isDirectory: true)
        return dir.appendingPathComponent("jot.log")
    }

    public static var rotatedLogFileURL: URL {
        logFileURL.deletingLastPathComponent().appendingPathComponent("jot.log.1")
    }

    private static let maxSize: UInt64 = 2 * 1024 * 1024  // 2 MB
    private let fallbackLog = Logger(subsystem: "com.jot.Jot", category: "ErrorLog")

    private init() {}

    public func error(component: String, message: String, context: [String: String] = [:]) async {
        await write(level: .error, component: component, message: message, context: context)
    }

    public func warn(component: String, message: String, context: [String: String] = [:]) async {
        await write(level: .warn, component: component, message: message, context: context)
    }

    public func info(component: String, message: String, context: [String: String] = [:]) async {
        await write(level: .info, component: component, message: message, context: context)
    }

    private func write(level: Level, component: String, message: String, context: [String: String]) async {
        let ts = ISO8601DateFormatter().string(from: Date())
        let ctxStr = context.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "[\(ts)] [\(level.rawValue)] [\(component)] \(message)" + (ctxStr.isEmpty ? "" : " \(ctxStr)") + "\n"

        let url = Self.logFileURL
        let dir = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try rotateIfNeeded(url: url)

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            fallbackLog.error("Failed to write to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded(url: URL) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxSize else { return }

        let rotated = Self.rotatedLogFileURL
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: url, to: rotated)
    }

    // MARK: - Redaction helpers (static, usable at log-call sites)

    public static func redactedURL(_ url: URL) -> String {
        let scheme = url.scheme ?? ""
        let host = url.host ?? ""
        return "\(scheme)://\(host)"
    }

    public static func redactedHTTPError(statusCode: Int, provider: String, bodyLength: Int) -> String {
        return "HTTP \(statusCode) from \(provider) (body \(bodyLength) chars — not logged)"
    }

    public static func redactedAppleError(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code)"
    }
}
