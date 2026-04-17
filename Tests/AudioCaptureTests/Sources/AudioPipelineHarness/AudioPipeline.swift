@preconcurrency import AVFoundation
import Foundation

/// Pure-Swift port of the format-conversion pipeline inside
/// `Sources/Recording/AudioCapture.swift`. Takes incoming `AVAudioPCMBuffer`s
/// at whatever hardware format the engine hands us and produces Float32 mono
/// 16 kHz samples, the same format Parakeet consumes.
///
/// The production actor `AudioCapture` owns:
///   (1) the `AVAudioEngine` and its tap install/removal, and
///   (2) the on-disk `AVAudioFile` write.
///
/// The production actor does NOT uniquely own:
///   (3) converter construction, (4) mid-session converter rebuild on format
///   flip, (5) output buffer allocation, and (6) the convert-to-`[Float]` math.
///
/// (3)–(6) are what regress most often, and they're what this struct owns.
/// Testing this struct covers the class of bugs we've actually shipped
/// (v1.2: zero samples out) without needing HAL or an engine.
public struct AudioPipeline {
    public enum Error: Swift.Error {
        case converterUnavailable
        case outputAllocationFailed
        case convert(Swift.Error)
    }

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let target: AVAudioFormat

    public init(target: AVAudioFormat = AudioFormat.target) {
        self.target = target
    }

    /// Drives one buffer through the converter and returns the Float32 samples
    /// it produced. Mutating because the converter is rebuilt on the fly when
    /// the input format changes mid-session (mic switch, sample-rate change).
    /// Returns an empty array on no-op (zero-frame input) or a caught converter
    /// error that was logged upstream in production.
    public mutating func process(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }

        let incomingFormat = buffer.format
        if converterInputFormat != incomingFormat {
            guard let rebuilt = AVAudioConverter(from: incomingFormat, to: target) else {
                throw Error.converterUnavailable
            }
            converter = rebuilt
            converterInputFormat = incomingFormat
        }

        guard let converter else { throw Error.converterUnavailable }

        // Identical math to Sources/Recording/AudioCapture.swift:187–197.
        // Overshooting capacity is cheap; undershooting causes `.endOfStream`
        // from the converter mid-chunk and silently drops audio.
        let ratio = target.sampleRate / incomingFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: estimatedFrames
            )
        else {
            throw Error.outputAllocationFailed
        }

        var suppliedOnce = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
            if suppliedOnce {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedOnce = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .error:
            if let convertError { throw Error.convert(convertError) }
            return []
        case .inputRanDry, .haveData, .endOfStream:
            break
        @unknown default:
            break
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let channelData = outBuffer.floatChannelData else {
            return []
        }

        let channelPtr = channelData[0]
        return Array(UnsafeBufferPointer(start: channelPtr, count: frameCount))
    }
}
