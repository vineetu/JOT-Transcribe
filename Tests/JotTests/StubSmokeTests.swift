import Foundation
import Testing
import AppKit
@testable import Jot

/// Trivial per-stub smoke tests — proves each Phase 1.3 stub conformer
/// builds against its protocol and that round-trip behavior works
/// (enqueue → consume, set → read).
///
/// These are deliberately thin: Phase 1.4-1.7 flow tests will exercise
/// the stubs end-to-end. The point here is to fail fast if a future
/// edit breaks a protocol conformance or a constructor shape.
@MainActor
struct StubSmokeTests {

    // MARK: - Conformance gate

    /// `agentic-testing.md` §0.4 acceptance: each Phase 1.3 stub
    /// satisfies its Phase 0 protocol. Compile-time existential checks
    /// only — no runtime behavior. Catches the "renamed a method,
    /// forgot to update the stub" regression class instantly.
    @Test func stubsConform() {
        let _: any AudioCapturing = StubAudioCapture()
        let _: any Transcribing = StubTranscriber()
        let _: any AppleIntelligenceClienting = StubAppleIntelligence()
        let _: any Pasteboarding = StubPasteboard()
        let _: any KeychainStoring = StubKeychain()
        let _: any PermissionsObserving = StubPermissions()
        let _: any LogSink = CapturingLogSink()
        // `StubURLProtocol` is registered via `URLSessionConfiguration.protocolClasses`,
        // not threaded through `AppServices`, so it has no `any URLSession*`
        // existential to assert here. `stubURLProtocol_servesCannedResponse`
        // exercises the registration path end-to-end.
    }

    // MARK: - StubAudioCapture

    @Test func stubAudioCapture_replaysSamples() async throws {
        let stub = StubAudioCapture(seed: .liveStub)
        await stub.enqueue(audio: .samples([0.1, 0.2, 0.3]))
        try await stub.start()
        let recording = try await stub.stop()
        #expect(recording.samples == [0.1, 0.2, 0.3])
        await stub.awaitDrained()
    }

    @Test func stubAudioCapture_alwaysFailsToStart() async {
        let stub = StubAudioCapture(seed: .alwaysFailsToStart)
        await #expect(throws: AudioCaptureError.self) {
            try await stub.start()
        }
    }

    @Test func stubAudioCapture_timesOutOnStart() async {
        let stub = StubAudioCapture(seed: .timesOutOnStart)
        await #expect(throws: AudioCaptureError.self) {
            try await stub.start()
        }
    }

    @Test func stubAudioCapture_silenceMaterializesZeros() async throws {
        let stub = StubAudioCapture(seed: .silence(duration: .milliseconds(100)))
        try await stub.start()
        let recording = try await stub.stop()
        // 16 kHz × 0.1 s = 1600 zero samples.
        #expect(recording.samples.count == 1600)
        #expect(recording.samples.allSatisfy { $0 == 0 })
    }

    // MARK: - StubTranscriber

    @Test func stubTranscriber_returnsCannedResult() async throws {
        let stub = StubTranscriber()
        await stub.enqueue(asrSeed: StubTranscriber.canned(text: "hello world"))
        try await stub.ensureLoaded()
        let result = try await stub.transcribe([0.1, 0.2])
        #expect(result.text == "hello world")
    }

    @Test func stubTranscriber_busyWhenQueueEmpty() async throws {
        let stub = StubTranscriber()
        try await stub.ensureLoaded()
        await #expect(throws: TranscriberError.self) {
            _ = try await stub.transcribe([0.1])
        }
    }

    // MARK: - StubURLProtocol

    @Test func stubURLProtocol_servesCannedResponse() async throws {
        // Phase 3 #32: scoped reset, not `StubURLProtocol.reset()`. The
        // unscoped version wipes the class-level queue including
        // entries other suites (e.g. `ArticulateFlowTests`) had
        // enqueued for `chat/completions`, leaking a -1008 race when
        // suites run in parallel.
        StubURLProtocol.removeMatching("example.com")
        StubURLProtocol.enqueue(
            matcher: "example.com",
            response: .init(statusCode: 200, body: Data("ok".utf8))
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(
            from: URL(string: "https://example.com/v1/test")!
        )
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    // MARK: - StubAppleIntelligence

    @Test func stubAppleIntelligence_transformReturnsCanned() async throws {
        let stub = StubAppleIntelligence(seed: .stub)
        await stub.enqueueTransform("cleaned!")
        let out = try await stub.transform(transcript: "raw", instruction: "x")
        #expect(out == "cleaned!")
    }

    @Test func stubAppleIntelligence_unavailableThrows() async throws {
        let stub = StubAppleIntelligence(seed: .unavailable)
        #expect(stub.isAvailable == false)
        await #expect(throws: LLMError.self) {
            _ = try await stub.transform(transcript: "x", instruction: "y")
        }
    }

    // MARK: - StubPasteboard

    @Test func stubPasteboard_writeRecordsHistory() async throws {
        let stub = StubPasteboard()
        let ok = stub.write("hello")
        #expect(ok == true)
        #expect(stub.history.count == 1)
        #expect(stub.history.first?.text == "hello")
        #expect(stub.readString() == "hello")
    }

    // MARK: - StubKeychain

    @Test func stubKeychain_roundTripsValue() throws {
        let stub = StubKeychain(seed: .empty)
        try stub.save("sk-test", account: "openai")
        let v = try stub.load(account: "openai")
        #expect(v == "sk-test")
    }

    @Test func stubKeychain_throwsOnLoadModeThrows() {
        let stub = StubKeychain(seed: .throwsOnLoad)
        #expect(throws: KeychainError.self) {
            _ = try stub.load(account: "openai")
        }
    }

    @Test func stubKeychain_populatedSeedExposesEntries() throws {
        let stub = StubKeychain(seed: .populated([(account: "openai", value: "sk-1")]))
        let v = try stub.load(account: "openai")
        #expect(v == "sk-1")
    }

    // MARK: - StubPermissions

    @Test func stubPermissions_allGrantedDefault() async throws {
        let stub = StubPermissions(seed: .allGranted)
        for cap in Capability.allCases {
            #expect(stub.status(for: cap) == .granted)
        }
    }

    @Test func stubPermissions_micDeniedSeedFlipsMic() async throws {
        let stub = StubPermissions(seed: .micDenied)
        #expect(stub.status(for: .microphone) == .denied)
        #expect(stub.status(for: .inputMonitoring) == .granted)
    }

    @Test func stubPermissions_setUpdatesPublisher() async throws {
        let stub = StubPermissions(seed: .allGranted)
        stub.set(.microphone, .denied)
        #expect(stub.status(for: .microphone) == .denied)
    }

    // MARK: - CapturingLogSink

    @Test func capturingLogSink_recordsLevels() async throws {
        let sink = CapturingLogSink()
        let start = Date()
        await sink.info(component: "X", message: "i", context: [:])
        await sink.warn(component: "X", message: "w", context: [:])
        await sink.error(component: "X", message: "e", context: [:])
        let entries = await sink.entries(since: start)
        #expect(entries.map(\.level) == [.info, .warn, .error])
        #expect(entries.map(\.message) == ["i", "w", "e"])
    }
}
