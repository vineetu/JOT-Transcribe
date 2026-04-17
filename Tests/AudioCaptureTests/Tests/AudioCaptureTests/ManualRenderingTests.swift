import Testing
@preconcurrency import AVFoundation
@testable import AudioPipelineHarness

@Suite("Manual-rendering integration — engine + tap + pipeline")
struct ManualRenderingTests {

    @Test("1 second of 440 Hz sine at 48 kHz yields ~16,000 samples at 16 kHz")
    func captureOneSecondOfSine() throws {
        let harness = try ManualRenderingHarness(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )!,
            signal: .sine(frequency: 440, amplitude: 0.5)
        )
        try harness.render(seconds: 1.0)

        let samples = harness.capturedSamples
        // Tap + render jitter can shift sample count a few %. The assertion
        // that matters is "not zero" and "within an order of magnitude of
        // expected" — the v1.2 regression would produce 0 samples here.
        #expect(samples.count > 14_000,
                "expected ~16k samples, got \(samples.count) — pipeline dropped audio")
        #expect(samples.count < 18_500,
                "expected ~16k samples, got \(samples.count) — pipeline over-produced")

        let rms = rmsOf(samples)
        #expect(rms > 0.2, "RMS \(rms) too low — captured near-silence")
    }

    @Test("Silent source produces silent output (not a crash)")
    func silentSourceProducesSilence() throws {
        let harness = try ManualRenderingHarness(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )!,
            signal: .silence
        )
        try harness.render(seconds: 0.5)

        // AVAudioMixer can elide zero buffers, so a silent source may produce
        // zero tap callbacks — that's fine. The assertion is "no crash, and
        // whatever we did receive is silent", not "we received samples".
        let rms = rmsOf(harness.capturedSamples)
        #expect(rms < 0.001, "silence source produced non-zero RMS \(rms)")
    }

    @Test("44.1 kHz source also reaches 16 kHz pipeline")
    func captureAt44k() throws {
        let harness = try ManualRenderingHarness(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            )!,
            signal: .sine(frequency: 440, amplitude: 0.5)
        )
        try harness.render(seconds: 1.0)

        let samples = harness.capturedSamples
        #expect(samples.count > 14_000,
                "44.1kHz → 16kHz yielded only \(samples.count) samples")
        #expect(rmsOf(samples) > 0.2)
    }

    private func rmsOf(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.map { $0 * $0 }.reduce(0, +)
        return sqrt(sumSq / Float(samples.count))
    }
}
