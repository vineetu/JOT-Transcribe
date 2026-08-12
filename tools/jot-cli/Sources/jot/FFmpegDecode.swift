@preconcurrency import AVFoundation
import Foundation

enum FFmpegDecodeError: Error, CustomStringConvertible {
    case ffmpegNotFound(String)
    case ffmpegFailed(status: Int32, stderr: String)
    case audioLoadFailed(Error)

    var description: String {
        switch self {
        case .ffmpegNotFound(let path):
            return "ffmpeg not found at \(path)"
        case .ffmpegFailed(let status, let stderr):
            return "ffmpeg exited with status \(status): \(stderr)"
        case .audioLoadFailed(let error):
            return "failed to read decoded WAV: \(error)"
        }
    }
}

/// Shells out to the repo-bundled ffmpeg to normalize any audio/video input
/// to 16 kHz mono WAV, then loads that into a `[Float]` sample array — the
/// same shape `AudioCapture` produces in the app.
///
enum FFmpegDecoder {
    /// Resolve ffmpeg, in the order that is right for whoever is running us:
    ///   1. the sibling next to THIS executable — the bundled layout, where
    ///      `jot` and `ffmpeg` both live in `Jot.app/Contents/Helpers/`
    ///   2. `$PATH` — a CLI installed on its own (Homebrew, a build box) has no
    ///      sibling, and a hardcoded developer path made it work on exactly one
    ///      machine in the world
    ///   3. the repo checkout, for `swift run` during development
    static let ffmpegPath: String = {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("ffmpeg").path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        if let onPath = searchPath(for: "ffmpeg") { return onPath }
        return "/Users/vsriram/code/jot/Vendor/ffmpeg/ffmpeg"
    }()

    /// `$PATH` lookup without shelling out to `which` (which would need a
    /// shell we may not have, and costs a process on every launch).
    private static func searchPath(for tool: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent(tool).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func decodeToMono16k(_ inputPath: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            throw FFmpegDecodeError.ffmpegNotFound(ffmpegPath)
        }

        let tmpDir = FileManager.default.temporaryDirectory
        let tmpWav = tmpDir.appendingPathComponent("jot-cli-\(UUID().uuidString).wav")
        // stderr → a FILE, not a Pipe: on a long/chatty input ffmpeg can write
        // more than the ~64 KB OS pipe buffer, and an undrained pipe would
        // deadlock the child on write(2) while we block in waitUntilExit
        // (review C1 — the app's FFmpegDecoder drains concurrently for the
        // same reason). A file has no fixed buffer, so it can't deadlock, and
        // we read it back only if ffmpeg fails. `-nostats -loglevel error`
        // keeps it tiny in the common case.
        let tmpErr = tmpDir.appendingPathComponent("jot-cli-\(UUID().uuidString).stderr")
        defer {
            try? FileManager.default.removeItem(at: tmpWav)
            try? FileManager.default.removeItem(at: tmpErr)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-nostdin", "-y", "-nostats", "-loglevel", "error",
            "-i", inputPath,
            "-vn", "-ac", "1", "-ar", "16000",
            "-f", "wav", tmpWav.path,
        ]
        FileManager.default.createFile(atPath: tmpErr.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: tmpErr)
        process.standardError = errHandle
        process.standardOutput = FileHandle.nullDevice  // ffmpeg writes the WAV to a file; stdout unused

        try process.run()
        process.waitUntilExit()
        try? errHandle.close()

        guard process.terminationStatus == 0 else {
            let stderrText = (try? String(contentsOf: tmpErr, encoding: .utf8)) ?? ""
            throw FFmpegDecodeError.ffmpegFailed(status: process.terminationStatus, stderr: stderrText)
        }

        do {
            return try loadMono16k(tmpWav.path)
        } catch {
            throw FFmpegDecodeError.audioLoadFailed(error)
        }
    }

    /// Reads a WAV (already 16 kHz mono in practice, since ffmpeg produced
    /// it) into `[Float]`, defensively resampling/downmixing if it isn't —
    /// mirrors `tools/nemotron-probe` and `tools/diarize-probe`'s identical
    /// helper.
    private static func loadMono16k(_ path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw FFmpegDecodeError.audioLoadFailed(
                NSError(domain: "jot-cli", code: -1, userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"]))
        }
        try file.read(into: inBuf)

        if inFormat.sampleRate == 16_000, inFormat.channelCount == 1,
            inFormat.commonFormat == .pcmFormatFloat32
        {
            let ptr = inBuf.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(inBuf.frameLength)))
        }

        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw FFmpegDecodeError.audioLoadFailed(
                NSError(domain: "jot-cli", code: -2, userInfo: [NSLocalizedDescriptionKey: "converter init failed"]))
        }
        let ratio = 16_000.0 / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw FFmpegDecodeError.audioLoadFailed(
                NSError(domain: "jot-cli", code: -3, userInfo: [NSLocalizedDescriptionKey: "output buffer alloc failed"]))
        }
        var consumed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let convErr { throw FFmpegDecodeError.audioLoadFailed(convErr) }
        let ptr = outBuf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
    }
}
