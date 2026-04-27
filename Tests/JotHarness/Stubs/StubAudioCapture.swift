import Foundation
@testable import Jot

/// Harness conformer for `AudioCapturing`. Replays canned `[Float]`
/// samples through the same actor-call shape `AudioCapture` exposes —
/// no AVAudioEngine, no CoreAudio, no on-disk WAV.
///
/// **Lifecycle:** the flow method enqueues an `AudioSource` via
/// `enqueue(audio:)` (or via `HarnessSeed.audio` at init), drives the
/// stub's `start()` → `stop()` cycle, and awaits `awaitDrained()` to
/// know the buffer was consumed. `awaitDrained()` resolves immediately
/// after `stop()` because the stub holds the canned samples in memory
/// — no async tap to wait on.
///
/// **Failure modes** (driven by `AudioSeed`):
/// - `.liveStub` / `.file` / `.silence` / `.samples` → happy path.
/// (Note: `agentic-testing.md` §0.2 mentions `.alwaysFailsToStart` /
/// `.timesOutOnStart` shapes for engine failure paths; the brief's
/// `AudioSeed` doesn't include those, so failure injection lives in
/// the per-call `enqueue(failure:)` API instead.)
actor StubAudioCapture: AudioCapturing {
    private var pendingAudio: AudioSource?
    private var pendingFailure: AudioCaptureError?
    private var isRunning = false
    private var drainContinuation: CheckedContinuation<Void, Never>?

    /// In-memory samples decoded from the most recent `AudioSource`.
    /// Flow methods read this after `stop()` to feed the transcriber stub.
    private var capturedSamples: [Float] = []

    init(seed: AudioSeed = .liveStub) {
        // Apply the seed-level default so flow methods that don't
        // override per-call still get plausible audio. Failure-mode
        // seeds preload `pendingFailure`; the per-call
        // `enqueue(failure:)` API still exists alongside for tests
        // that want to flip behavior between calls without rebuilding
        // the harness.
        switch seed {
        case .liveStub:
            self.pendingAudio = nil  // requires per-call enqueue
        case .file(let url):
            self.pendingAudio = .file(url)
        case .silence(let duration):
            self.pendingAudio = .silence(duration: duration)
        case .samples(let samples):
            self.pendingAudio = .samples(samples)
        case .alwaysFailsToStart:
            self.pendingAudio = nil
            // `engineStart(_:)` wraps the underlying NSError. The stub
            // synthesizes a generic NSError that maps to the
            // production "Recording engine failed to start" pill
            // surface.
            self.pendingFailure = .engineStart(
                NSError(
                    domain: "JotHarness.StubAudioCapture",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Stub: engine refused to start"]
                )
            )
        case .timesOutOnStart:
            self.pendingAudio = nil
            self.pendingFailure = .engineStartTimeout
        }
    }

    /// Enqueue the audio the next `start()` → `stop()` cycle should
    /// replay. Overwrites any seed-level default.
    func enqueue(audio: AudioSource) {
        self.pendingAudio = audio
    }

    /// Enqueue a failure that the next `start()` should throw. Lets
    /// flow tests exercise the engine-start-timeout / mic-busy paths
    /// without needing AudioSeed cases for them.
    func enqueue(failure: AudioCaptureError) {
        self.pendingFailure = failure
    }

    /// Resolves once the stub's buffer has been drained (i.e. `stop()`
    /// returned). On the synthetic stub this is just "after stop", so
    /// it returns immediately if we're already stopped, or suspends
    /// until the next `stop()` if we're still running.
    func awaitDrained() async {
        if !isRunning { return }
        await withCheckedContinuation { cont in
            self.drainContinuation = cont
        }
    }

    /// Most recent decoded samples — read by flow methods to drive the
    /// transcriber stub.
    var lastCapturedSamples: [Float] { capturedSamples }

    // MARK: - AudioCapturing

    func start() async throws {
        if let failure = pendingFailure {
            pendingFailure = nil
            throw failure
        }
        guard !isRunning else { throw AudioCaptureError.alreadyRunning }
        isRunning = true
    }

    func stop() async throws -> AudioRecording {
        guard isRunning else { throw AudioCaptureError.notRunning }
        isRunning = false

        let samples = decodedSamples(from: pendingAudio)
        capturedSamples = samples

        let recording = AudioRecording(
            samples: samples,
            fileURL: URL(fileURLWithPath: "/dev/null"),
            duration: TimeInterval(samples.count) / 16_000.0,
            createdAt: Date()
        )

        if let cont = drainContinuation {
            drainContinuation = nil
            cont.resume()
        }

        return recording
    }

    func cancel() async {
        isRunning = false
        capturedSamples = []
        if let cont = drainContinuation {
            drainContinuation = nil
            cont.resume()
        }
    }

    func setAmplitudePublisher(_ publisher: AmplitudePublisher?) async {
        // No-op: tests don't drive the pill amplitude meter.
        _ = publisher
    }

    // MARK: - Decoding

    private func decodedSamples(from source: AudioSource?) -> [Float] {
        switch source {
        case .none:
            return []
        case .file:
            // File decode lives in Phase 1.4's flow method (it owns the
            // AVFoundation hop). Stubs return the seed's raw samples.
            return []
        case .silence(let duration):
            let count = Int((Double(duration.components.seconds) +
                             Double(duration.components.attoseconds) / 1e18) * 16_000)
            return Array(repeating: 0, count: max(count, 0))
        case .samples(let pcm):
            return pcm
        }
    }
}
