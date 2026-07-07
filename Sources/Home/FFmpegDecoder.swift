import Foundation
import Darwin
import os.log

/// Runs the bundled decode-only FFmpeg helper (`Vendor/ffmpeg/BUILD.md`) as a
/// last-resort decoder for containers AVFoundation can't read — WebM, MKV,
/// WMA, AVI, FLV, AC-3/DTS-in-mp4, … (design
/// `docs/audio-file-transcription/design.md` §8).
///
/// **Modeled on `LMStudioSetup.runProcess`
/// (`Sources/LLM/LMStudio/LMStudioSetup.swift:633-716`), NOT on
/// `FileTranscriptionIngest.transcode()`'s `Task.detached`** — review §8.8
/// F1: `Task.detached` does not inherit cancellation, so a mic-preempted
/// import would leave a zombie ffmpeg process (and a leaked temp WAV)
/// running for the whole decode. Here, cancelling the calling `Task`
/// (`FileTranscriptionIngest.cancelInFlight()`) actually reaches into
/// `withTaskCancellationHandler`'s `onCancel` and SIGTERMs the process
/// group.
enum FFmpegDecoder {
    enum DecodeError: Error {
        /// The helper binary isn't present/executable in this build — should
        /// never happen in a properly bundled app (see the pbxproj "Bundle
        /// FFmpeg Helper" run-script phase), but a corrupt/incomplete install
        /// shouldn't crash; surfaces as "extended decoder unavailable"
        /// (§8.8 "Missing" callout).
        case helperUnavailable
        /// `Process.run()` itself threw (bad permissions, missing file at
        /// launch time even though `isAvailable` passed moments earlier).
        case launchFailed
        /// ffmpeg exited non-zero, or produced empty/no output. Per §8.1
        /// this doubles as BOTH the readability test and the no-audio test
        /// for ffmpeg-decoded formats; `stderrTail` (bounded, drained — see
        /// §8.8 F3) lets the caller distinguish "no audio stream" from a
        /// generic decode failure without re-reading the whole log.
        case decodeFailed(exitCode: Int32, stderrTail: String)
        /// The watchdog fired before ffmpeg finished.
        case timedOut
    }

    private static let log = Logger(subsystem: "com.jot.Jot", category: "FFmpegDecoder")

    /// Default watchdog: generous enough for a very long file (an hour+ of
    /// audio decodes in seconds; this mostly guards against a wedged/looping
    /// input, not normal runtime) while still bounding a leaked process.
    private static let defaultTimeout: TimeInterval = 900

    /// `Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")`
    /// — deliberately NOT `Bundle.main.url(forAuxiliaryExecutable:)`, which
    /// only searches `Contents/MacOS` and returns `nil` for a
    /// `Contents/Helpers` binary (design §8.4).
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    /// Decode `source` into a fresh 16 kHz mono WAV in
    /// `FileManager.default.temporaryDirectory` (§8.8 F2 — NOT
    /// `RecordingStore.audioDirectory`, which is reserved for library
    /// recordings). **The caller MUST
    /// `defer { try? FileManager.default.removeItem(at: tempWav) }` the
    /// instant this call returns**, so every downstream exit path (success,
    /// failure, cancellation) cleans up — the exact idiom
    /// `FileTranscriptionIngest.run()` already uses for its m4a destination.
    static func decodeToTempWAV(source: URL, timeout: TimeInterval = defaultTimeout) async throws -> URL {
        guard isAvailable else { throw DecodeError.helperUnavailable }

        let tempWav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("wav")

        // Argv, never a shell string (design §8.1).
        let arguments = [
            "-nostdin", "-y",
            "-i", source.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-f", "wav", tempWav.path,
        ]

        // The caller only receives `tempWav` (and its cleanup `defer`) when this
        // function RETURNS. When `run(...)` THROWS — timeout, non-zero exit, or
        // cancellation (mic-preempt → SIGTERM mid-write) — ffmpeg was launched
        // with `-y` and may have already written a partial `.wav` header/stream,
        // and the caller never gets the URL to clean up. So this function must
        // remove its own orphan on every throw path (review BUG 1 / §8.8 F2 —
        // the exact mic-preempt leak F1/F2 were written to prevent).
        do {
            try await run(arguments: arguments, timeout: timeout)
            let size = (try? FileManager.default.attributesOfItem(atPath: tempWav.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw DecodeError.decodeFailed(exitCode: 0, stderrTail: "")
            }
            return tempWav
        } catch {
            try? FileManager.default.removeItem(at: tempWav)
            throw error
        }
    }

    /// Subprocess run, modeled on `LMStudioSetup.runProcess`: own process
    /// group (so cancellation/watchdog can SIGTERM the whole tree), a
    /// watchdog timeout, stderr drained into a bounded tail buffer (§8.8 F3 —
    /// an undrained full pipe deadlocks a long decode; ffmpeg logs
    /// configuration/progress to stderr by default), and a resume-once guard
    /// shared by {termination handler, watchdog}.
    private static func run(arguments: [String], timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let stderrTail = TailAccumulator()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrTail.append(data)
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            log.error("ffmpeg launch failed: \(String(describing: error))")
            throw DecodeError.launchFailed
        }

        // Own process group so cancellation/the watchdog can SIGTERM the
        // whole tree (mirrors `LMStudioSetup.runProcess`).
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let didResume = ResumeGuard()

                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                watchdog.schedule(deadline: .now() + timeout)
                watchdog.setEventHandler {
                    guard !didResume.isResumed else { return }
                    if process.isRunning {
                        _ = kill(-pid, SIGTERM)
                    }
                    if didResume.markResumed() {
                        errorPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: DecodeError.timedOut)
                    }
                }
                watchdog.resume()

                process.terminationHandler = { proc in
                    watchdog.cancel()
                    guard didResume.markResumed() else { return }
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    let status = proc.terminationStatus
                    if status == 0 {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: DecodeError.decodeFailed(exitCode: status, stderrTail: stderrTail.snapshot()))
                    }
                }
            }
        } onCancel: {
            // Unlike `LMStudioSetup.runProcess`'s `onCancel` (which
            // deliberately lets an in-flight model download run rather than
            // orphan a half-pulled model), a file-import decode MUST die
            // here: this is exactly the mic-preempt path (§8.8 F1) —
            // `FileTranscriptionIngest.cancelInFlight()` cancelling the
            // enclosing `Task` must actually kill the subprocess, not just
            // stop waiting on it, or it becomes a zombie holding the temp
            // WAV open for the rest of its decode.
            if process.isRunning {
                _ = kill(-pid, SIGTERM)
            }
        }
    }
}

/// Bounded tail of ffmpeg's stderr — enough to distinguish "no audio stream"
/// from a generic decode failure (design §8.8 R6) without risking unbounded
/// growth on a long, chatty decode. The pipe's `readabilityHandler` fires on
/// an arbitrary queue, so guard with a lock (mirrors `LMStudioSetup`'s
/// `OutputAccumulator`).
private final class TailAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let cap = 8192

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}

/// Tiny guard making the termination handler + watchdog race-safe — same
/// primitive as `LMStudioSetup`'s private `ResumeGuard` (not shared across
/// files since that one is file-private).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _isResumed = false

    var isResumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isResumed
    }

    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _isResumed { return false }
        _isResumed = true
        return true
    }
}
