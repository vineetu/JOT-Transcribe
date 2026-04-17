@preconcurrency import AVFoundation
import Foundation

/// Drives `AVAudioEngine` in manual-rendering mode with a synthesized signal
/// as the input. Installs a tap at the source format — the same pattern the
/// production code uses on `engine.inputNode` — and runs each tapped buffer
/// through `AudioPipeline`.
///
/// Manual rendering bypasses the HAL, so this does not test the
/// `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` device-pin
/// path. It DOES test the converter + tap + pipeline — which is the
/// regression class that broke v1.2. See docs/plans/audio-test-harness.md
/// for the full list of what this does and does not catch.
public final class ManualRenderingHarness {
    public enum Signal {
        case sine(frequency: Double, amplitude: Float)
        case silence
    }

    public let inputFormat: AVAudioFormat
    public let targetFormat: AVAudioFormat
    public private(set) var capturedSamples: [Float] = []

    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private var pipeline: AudioPipeline
    private let signal: Signal
    private var framesRendered: AVAudioFramePosition = 0

    public init(
        inputFormat: AVAudioFormat,
        signal: Signal,
        target: AVAudioFormat = AudioFormat.target
    ) throws {
        self.inputFormat = inputFormat
        self.targetFormat = target
        self.signal = signal
        self.pipeline = AudioPipeline(target: target)

        let sampleRate = inputFormat.sampleRate
        var phase: Double = 0
        source = AVAudioSourceNode(format: inputFormat) { _, timestamp, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)
                guard let ptr else { continue }
                switch signal {
                case .silence:
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                case .sine(let frequency, let amplitude):
                    let phaseStep = 2.0 * .pi * frequency / sampleRate
                    var p = phase
                    for i in 0..<Int(frameCount) {
                        ptr[i] = Float(sin(p)) * amplitude
                        p += phaseStep
                        if p > 2.0 * .pi { p -= 2.0 * .pi }
                    }
                    phase = p
                }
            }
            _ = timestamp
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: inputFormat)

        // In manual-rendering mode the output pulls from the graph on demand.
        // We still want to observe each rendered buffer as it would look at
        // the input-tap site in production, so we tap the source directly.
        source.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let snapshot = buffer.copy() as? AVAudioPCMBuffer else { return }
            do {
                let samples = try self.pipeline.process(snapshot)
                self.capturedSamples.append(contentsOf: samples)
            } catch {
                // Surface-on-render errors abort rendering. The test asserts
                // on capturedSamples; a crash here would be opaque.
                self.pipelineError = error
            }
        }

        // Output at the input format. This keeps the engine's output pull at
        // a 1:1 ratio with the source node and the tap — so we can reason
        // directly about sample counts. The resample to target happens
        // inside the pipeline (same as production), not inside the engine.
        try engine.enableManualRenderingMode(
            .offline,
            format: inputFormat,
            maximumFrameCount: 4096
        )
        try engine.start()
    }

    public var pipelineError: Swift.Error?

    /// Render `seconds` of audio. Pulls through the engine in chunks sized to
    /// the manual-rendering maximum. Drives the whole pipeline synchronously.
    public func render(seconds: Double) throws {
        // The engine's output format matches the input format (see init), so
        // output frames and tap frames are measured in the same units.
        let totalFrames = AVAudioFrameCount(seconds * inputFormat.sampleRate)
        let chunk = AVAudioFrameCount(4096)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunk) else {
            throw AudioPipeline.Error.outputAllocationFailed
        }
        var rendered: AVAudioFrameCount = 0
        while rendered < totalFrames {
            let toRender = min(chunk, totalFrames - rendered)
            scratch.frameLength = 0
            let status = try engine.renderOffline(toRender, to: scratch)
            switch status {
            case .success:
                rendered += toRender
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                // The source node is always ready — either of these indicates
                // an engine misconfiguration. Bail so the test fails loudly.
                throw AudioPipeline.Error.convert(NSError(
                    domain: "ManualRenderingHarness",
                    code: Int(status.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "renderOffline status=\(status.rawValue)"]
                ))
            case .error:
                throw AudioPipeline.Error.convert(NSError(
                    domain: "ManualRenderingHarness",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "renderOffline error"]
                ))
            @unknown default:
                throw AudioPipeline.Error.convert(NSError(
                    domain: "ManualRenderingHarness",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "renderOffline unknown status"]
                ))
            }
        }
        framesRendered += AVAudioFramePosition(totalFrames)

        // Tap callbacks can lag by one maximumFrameCount. Drain by pumping a
        // silent block; the tap fires on the preceding render.
        scratch.frameLength = 0
        _ = try engine.renderOffline(chunk, to: scratch)

        if let pipelineError {
            throw pipelineError
        }
    }

    deinit {
        source.removeTap(onBus: 0)
        engine.stop()
    }
}

public extension ManualRenderingHarness {
    /// Helper: produce a filled input buffer at `format` with a sine wave.
    /// Used by tests that want to drive `AudioPipeline.process` directly
    /// without standing up the whole engine.
    static func sineBuffer(
        frames: AVAudioFrameCount,
        format: AVAudioFormat,
        frequency: Double = 440,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        let phaseStep = 2.0 * .pi * frequency / format.sampleRate
        var phase: Double = 0
        for i in 0..<Int(frames) {
            ptr[i] = Float(sin(phase)) * amplitude
            phase += phaseStep
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        return buffer
    }
}
