import Testing
@preconcurrency import AVFoundation
@testable import AudioPipelineHarness

@Suite("AudioPipeline — pure-Swift format conversion")
struct AudioPipelineTests {

    private let fmt48k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private let fmt44k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    )!

    @Test("48 kHz → 16 kHz produces roughly 1/3 the sample count")
    func downsample48k() throws {
        var pipeline = AudioPipeline()
        // 4800 input frames @ 48 kHz = 100 ms. At 16 kHz that's ~1600 frames
        // target; AVAudioConverter holds some latency per single-buffer call
        // (sinc-interpolator state), so one-shot output is typically in the
        // 1200–1700 range. The assertion that matters is "non-trivial output".
        let input = ManualRenderingHarness.sineBuffer(frames: 4800, format: fmt48k)
        let output = try pipeline.process(input)
        #expect((1200...1700).contains(output.count),
                "expected ~1300–1700 samples, got \(output.count)")
    }

    @Test("44.1 kHz → 16 kHz produces a proportional sample count")
    func downsample44k() throws {
        var pipeline = AudioPipeline()
        // 4410 frames @ 44.1 kHz = 100 ms → target ~1600 frames @ 16 kHz.
        // Same converter-latency caveat as the 48 kHz case.
        let input = ManualRenderingHarness.sineBuffer(frames: 4410, format: fmt44k)
        let output = try pipeline.process(input)
        #expect((1200...1700).contains(output.count),
                "expected ~1300–1700 samples, got \(output.count)")
    }

    @Test("Sine wave passes through — RMS is well above silence floor")
    func sineRoundTripHasEnergy() throws {
        var pipeline = AudioPipeline()
        let input = ManualRenderingHarness.sineBuffer(
            frames: 48_000, format: fmt48k,
            frequency: 440, amplitude: 0.5
        )
        let output = try pipeline.process(input)
        #expect(output.count > 15_000)

        let sumSq = output.map { $0 * $0 }.reduce(0, +)
        let rms = (output.isEmpty ? 0 : sqrt(sumSq / Float(output.count)))
        // A 0.5-amplitude sine has RMS ≈ 0.353. Downsampling loses a bit but
        // not much. 0.1 is a generous silence floor — the v1.2 regression
        // would show RMS ≈ 0 here.
        #expect(rms > 0.25, "RMS \(rms) too low — pipeline is producing near-silence")
    }

    @Test("Zero-length buffer is a no-op, not a crash")
    func zeroFrameBufferProducesNoSamples() throws {
        var pipeline = AudioPipeline()
        let empty = AVAudioPCMBuffer(pcmFormat: fmt48k, frameCapacity: 16)!
        empty.frameLength = 0
        let out = try pipeline.process(empty)
        #expect(out.isEmpty)
    }

    @Test("Mid-stream format switch rebuilds converter, both buffers convert")
    func formatSwitchRebuildsConverter() throws {
        var pipeline = AudioPipeline()

        let first = ManualRenderingHarness.sineBuffer(frames: 4800, format: fmt48k)
        let firstOut = try pipeline.process(first)
        #expect((1200...1700).contains(firstOut.count))

        // Switching format mid-session triggers converter rebuild. If the
        // rebuild is broken, the second call either throws or yields zero
        // samples — both are test failures.
        let second = ManualRenderingHarness.sineBuffer(frames: 4410, format: fmt44k)
        let secondOut = try pipeline.process(second)
        #expect((1200...1700).contains(secondOut.count),
                "converter rebuild on format flip dropped audio")
    }

    @Test("Target format is 16 kHz mono Float32 non-interleaved")
    func targetFormatMatchesParakeet() {
        let t = AudioFormat.target
        #expect(t.sampleRate == 16_000)
        #expect(t.channelCount == 1)
        #expect(t.commonFormat == .pcmFormatFloat32)
        #expect(t.isInterleaved == false)
    }
}
