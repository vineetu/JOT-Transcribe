@preconcurrency import AVFoundation
import Foundation

/// Shared "decode a recording's audio file to 16 kHz mono Float32" helper.
/// Recordings on disk are `.m4a` (AAC) with some legacy `.wav` rows
/// (`RecordingStore.audioURL(for:)`); `AVAudioFile` reads either natively.
///
/// Mirrors the private duplicates already living in `Transcriber` and
/// `RecordingDetailView` (each pre-dates this feature and has its own
/// narrow copy) — factored out here so `RecordingDetailView`'s "Detect
/// speakers" action doesn't need a third copy.
enum DiarizationAudio {
    /// `nonisolated` — safe to call from a detached task off the main
    /// actor; touches no shared mutable state.
    nonisolated static func readMono16kFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        let processingFormat = file.processingFormat

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        if processingFormat.sampleRate == targetFormat.sampleRate,
           processingFormat.channelCount == 1,
           processingFormat.commonFormat == .pcmFormatFloat32,
           !processingFormat.isInterleaved {
            guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else { return [] }
            try file.read(into: buf)
            return floats(from: buf)
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else { return [] }
        try file.read(into: inBuf)
        guard let converter = AVAudioConverter(from: processingFormat, to: targetFormat) else { return [] }
        let outCap = AVAudioFrameCount(Double(frameCount) * targetFormat.sampleRate / processingFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return [] }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if err != nil { return [] }
        return floats(from: outBuf)
    }

    nonisolated private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let ptr = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
    }
}
