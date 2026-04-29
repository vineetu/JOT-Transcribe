import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#endif

/// Cross-cutting error log. Writes to ~/Library/Logs/Jot/jot.log.
/// Rolling 2MB cap — on rotate, renames current to jot.log.1 (overwriting any existing).
/// Nothing is ever sent off the device.
public actor ErrorLog: LogSink {
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
        var line = "[\(ts)] [\(level.rawValue)] [\(component)] \(message)" + (ctxStr.isEmpty ? "" : " \(ctxStr)") + "\n"

        // Stack traces are only useful for unexpected errors. WARN/INFO are
        // routine operational events (fallback paths, status changes) where
        // a trace would just add noise — and capture cost is non-trivial
        // (callStackSymbols walks the whole stack). So we gate strictly on
        // ERROR level here so the WARN/INFO path pays nothing.
        if level == .error {
            let trace = StackTraceCapture.capture()
            if !trace.isEmpty {
                line += trace
            }
        }

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

// MARK: - Stack-trace capture

/// Wraps `Thread.callStackSymbols` plus Swift symbol demangling for the
/// ERROR-level path of `ErrorLog`. Lives outside the actor so the
/// raw-stack walk runs on the calling thread (where the actual error
/// frames are) instead of being deferred onto the actor's executor.
///
/// The output is a block of pre-indented continuation lines suitable
/// for direct concatenation onto the single-line log entry. Each frame
/// renders as `    at <demangledSymbol>` so single-line greps over the
/// log still succeed and a human eye can follow the trace down.
///
/// `swift_demangle` is dynamically resolved from `libswiftCore.dylib`
/// via `dlsym` — the symbol is part of the public Swift runtime ABI
/// on macOS, but isn't exposed in any module map, so dlsym is the
/// standard route. If the lookup fails (extraordinarily unlikely on a
/// shipped Swift macOS app) we fall through to the raw mangled name
/// rather than skip the frame.
enum StackTraceCapture {
    /// Maximum number of demangled frames emitted. The Articulate path
    /// is the deepest in the app and runs ~6-8 user frames before
    /// hitting the system tail, so 12 leaves comfortable headroom.
    static let maxFrames = 12

    /// Skip the topmost N raw frames before we even start filtering.
    /// These are guaranteed to be inside ErrorLog itself (this function
    /// + `write(level:...)` + the level entry point + the `LogSink`
    /// default-context shim). Trimming them up front keeps the visible
    /// trace anchored at the real caller.
    private static let logInfraFrameSkip = 4

    /// Produce the indented-continuation block, or empty string on any
    /// failure / empty stack. Always returns; never throws.
    static func capture() -> String {
        let raw = Thread.callStackSymbols
        guard raw.count > logInfraFrameSkip else { return "" }

        // Drop the ErrorLog-internal frames at the top.
        let userFrames = Array(raw.dropFirst(logInfraFrameSkip))

        var rendered: [String] = []
        var sawJot = false
        var trailingNonJot = 0

        for frame in userFrames {
            if rendered.count >= maxFrames { break }

            let symbol = extractSymbol(from: frame)
            let demangled = demangle(symbol) ?? symbol
            let isJot = demangled.hasPrefix("Jot.") || symbol.hasPrefix("$s3Jot")

            if isJot {
                sawJot = true
                trailingNonJot = 0
            } else if sawJot {
                trailingNonJot += 1
                // Once we've cleared the Jot frames, keep at most two
                // system frames (e.g. swift_task_run, _dispatch_call_block)
                // so the trace shows where Jot handed off, then stop.
                // This filters out the long `start_wqthread` /
                // `_pthread_start` tail without losing useful context.
                if trailingNonJot > 2 { break }
            }

            rendered.append("    at \(demangled)")
        }

        guard !rendered.isEmpty else { return "" }
        return rendered.joined(separator: "\n") + "\n"
    }

    /// Pull the symbol token out of a `callStackSymbols` line. Format is
    /// roughly: `<idx> <binary> <addr> <symbol> + <offset>`. Whitespace
    /// columns aren't reliable across architectures, so we split on
    /// runs of whitespace and pick the column at index 3 when present.
    /// Falls back to the whole frame string on any shape mismatch.
    private static func extractSymbol(from frame: String) -> String {
        // Strip the trailing " + <offset>" if present.
        var working = frame
        if let plusRange = working.range(of: " + ", options: .backwards) {
            working = String(working[..<plusRange.lowerBound])
        }
        // Columns: index, binary, address, symbol-and-rest.
        let parts = working.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return working }
        return String(parts[3])
    }

    // MARK: swift_demangle dlsym binding

    /// Cached demangle function pointer. `nil` means the lookup either
    /// hasn't run yet (sentinel handled by `demangleFn`) or failed and
    /// we should keep using mangled names.
    private static let demangleFn: DemangleFn? = {
        // libswiftCore is loaded into every Swift process — `RTLD_DEFAULT`
        // is sufficient and avoids hard-coding the dylib path (which has
        // shifted between macOS versions and toolchains).
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else {
            return nil
        }
        return unsafeBitCast(sym, to: DemangleFn.self)
    }()

    /// `swift_demangle(mangledName, mangledNameLength, outputBuffer,
    /// outputBufferSize, flags) -> char *`. We pass `outputBuffer = nil`
    /// so the runtime mallocs a fresh buffer — we own it and must free.
    private typealias DemangleFn = @convention(c) (
        UnsafePointer<CChar>?,   // mangledName
        Int,                      // mangledNameLength
        UnsafeMutablePointer<CChar>?,  // outputBuffer (nil → malloc'd)
        UnsafeMutablePointer<Int>?,    // outputBufferSize (in/out, nil ok)
        UInt32                    // flags
    ) -> UnsafeMutablePointer<CChar>?

    /// Demangle a Swift symbol. Returns `nil` if the input doesn't look
    /// mangled (bare C symbols, ObjC selectors) or if dlsym failed.
    private static func demangle(_ symbol: String) -> String? {
        guard let fn = demangleFn else { return nil }
        // Swift mangled symbols start with `$s` (Swift 5+) or `_T0` (old).
        // Skip the dlcall entirely on anything else — it would just
        // return the input unchanged but we'd still pay the malloc.
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_T") else { return nil }

        return symbol.withCString { cstr in
            guard let out = fn(cstr, strlen(cstr), nil, nil, 0) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
    }
}
