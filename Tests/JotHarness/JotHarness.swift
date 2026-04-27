import Combine
import Foundation
@testable import Jot

/// Test-only harness around the live composition graph.
///
/// `JotHarness.init(seed:)` constructs the eight stub seam conformers from
/// `HarnessSeed`, hands them to `JotComposition.build` via the new
/// `seams: AppServices.Seams` parameter, and wires the **subset of
/// AppDelegate.wireUp** that the dictation flow needs (the
/// `deliveryBridge` Combine sink, plus `delivery.bind(recorder:)` /
/// `delivery.bind(pasteboard:)` / `delivery.bind(logSink:)`).
///
/// Deliberately does **not** install the menu bar, overlay panel, hotkey
/// router, persister, retention, sound triggers, window observer, or
/// setup wizard. Those surfaces are out of scope for the dictation flow
/// test and would either spawn AppKit windows / NSStatusItems
/// (visible-side-effect-during-test) or assert on production permission
/// flow that doesn't apply to a stubbed graph.
@MainActor
final class JotHarness {

    /// Process-wide test-side serialization gate. Phase 3 #30 dropped
    /// `DeliveryService.shared`, #29 dropped `LLMConfiguration.shared`,
    /// and #18 routed the active model id through a per-graph
    /// `TranscriberHolder` reading from suite-scoped `UserDefaults`.
    /// Phase 3 #32 closed the two remaining flake sources:
    ///   1. `StubSmokeTests.stubURLProtocol_servesCannedResponse`
    ///      called `StubURLProtocol.reset()` (unscoped), wiping
    ///      sibling suites' queued `chat/completions` responses
    ///      and producing `URLError(.resourceUnavailable)` (-1008).
    ///      Switched to scoped `removeMatching("example.com")`.
    ///   2. The gate itself was `actor`-backed with
    ///      `deinit { Task { await release() } }` — release was
    ///      async and could be reordered with the next harness's
    ///      `await acquire()`, opening a window where N+1
    ///      constructed before N's services tore down. Replaced with
    ///      a `DispatchSemaphore`-backed class so `deinit` releases
    ///      synchronously, no Task hop.
    ///
    /// 60-run flake measurement post-#32: 60/60 (0% flake). Brief's
    /// 50-consecutive-passes acceptance met.
    ///
    /// **Future:** the gate is still doing work — the residual
    /// process-globals (`FirstRunState.shared`,
    /// `StubURLProtocol.pending` queue, raw `KeychainHelper`)
    /// would re-introduce flake without serialization. Dropping
    /// the gate is appropriate when those three are removed.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 1)

        /// Block (off the main actor) until the gate is free, then
        /// claim it. Called from a `Task.detached` inside `init` so
        /// the main actor isn't parked waiting for a sibling harness.
        func acquire() async {
            await Task.detached(priority: .userInitiated) { [semaphore] in
                semaphore.wait()
            }.value
        }

        /// Synchronously release the gate. Called from `deinit` on
        /// whatever thread ARC dropped the harness on. No async hop,
        /// so the next harness's `acquire()` resumes immediately.
        func release() {
            semaphore.signal()
        }
    }

    private static let gate = Gate()

    // MARK: - Stubs (held strongly so they outlive the graph)

    let stubAudioCapture: StubAudioCapture
    let stubTranscriber: StubTranscriber
    let stubAppleIntelligence: StubAppleIntelligence
    let stubPasteboard: StubPasteboard
    let stubKeychain: StubKeychain
    let stubPermissions: StubPermissions
    let capturingLogSink: CapturingLogSink

    // MARK: - Live graph

    let services: AppServices

    // MARK: - Internal wire-up retained for the lifetime of the harness

    /// Replicates `AppDelegate.deliveryBridge` so the recorder's
    /// `lastResult` triggers `DeliveryService.deliver(...)` against the
    /// stub pasteboard. Held strongly — same "must never be nilled" rule
    /// as the production sink.
    private var deliveryBridge: AnyCancellable?

    // MARK: - Init

    init(seed: HarnessSeed = .default) async throws {
        // 0. Acquire the process-wide harness gate. Released in
        //    `deinit`. Originally added for the `DeliveryService.shared`
        //    race (now fixed by Phase 3 #30); kept as defense for the
        //    other process-globals listed in `Gate`'s doc.
        await Self.gate.acquire()

        // Note: do NOT call `StubURLProtocol.reset()` here. The
        // standalone `stubURLProtocol_servesCannedResponse` smoke
        // test enqueues a response on the same class-level registry
        // without going through `JotHarness`. A reset here would
        // race-wipe its enqueue when the smoke test runs in parallel
        // with a harness test from a different suite. Each flow
        // method enqueues a specific matcher (e.g.
        // `"chat/completions"`); the smoke test enqueues
        // `"example.com"`; matchers are scoped enough not to collide.

        // 1. Construct the 8 stub conformers from the seed. Each maps
        //    its sub-seed to a stub instance one-to-one.
        let stubAudioCapture = StubAudioCapture(seed: seed.audio)
        let stubTranscriber = StubTranscriber()
        let stubAppleIntelligence = StubAppleIntelligence(seed: seed.appleIntelligence)
        let stubPasteboard = StubPasteboard()
        let stubKeychain = StubKeychain(seed: seed.keychain)
        let stubPermissions = StubPermissions(seed: seed.permissions)
        let capturingLogSink = CapturingLogSink()

        self.stubAudioCapture = stubAudioCapture
        self.stubTranscriber = stubTranscriber
        self.stubAppleIntelligence = stubAppleIntelligence
        self.stubPasteboard = stubPasteboard
        self.stubKeychain = stubKeychain
        self.stubPermissions = stubPermissions
        self.capturingLogSink = capturingLogSink

        // 2. Mint a URLSession whose configuration installs the stub
        //    URLProtocol class on every request. `protocolClasses` has
        //    to be set on the configuration *before* the URLSession is
        //    minted; we own the config here so the StubURLProtocol is
        //    the first protocol in the chain.
        //    NOTE: do **not** call `StubURLProtocol.reset()` here —
        //    Swift Testing runs tests in parallel by default and the
        //    StubURLProtocol class-level registry is process-global, so
        //    a reset in one harness instance would race-wipe a queued
        //    response in a sibling test. Tests that need fresh URLProtocol
        //    state call `StubURLProtocol.reset()` themselves at the top
        //    of the test body.
        let urlSessionConfig = URLSessionConfiguration.ephemeral
        urlSessionConfig.protocolClasses = [StubURLProtocol.self]
        let urlSession = URLSession(configuration: urlSessionConfig)

        // 3. Pack the 8 stubs into a `SeamOverrides`. The composition
        //    root reads this off `SystemServices.seamOverrides` and
        //    threads each stub in instead of constructing the live
        //    conformer.
        let overrides = SeamOverrides(
            audioCapture: stubAudioCapture,
            transcriber: stubTranscriber,
            urlSession: urlSession,
            appleIntelligence: stubAppleIntelligence,
            pasteboard: stubPasteboard,
            keychain: stubKeychain,
            permissions: stubPermissions,
            logSink: capturingLogSink,
            // Phase 4 hermetic-harness fix: seed the holder's installed
            // set explicitly so flow tests don't depend on the dev/CI
            // machine's `~/Library/Application Support/Jot/Models/...`
            // cache state. WizardFlowTests.runWizardAllGrantedReachesCompletion
            // assumes v3 is "installed" — without the seed it parked at
            // the model step on a clean machine.
            installedModelIDs: [.tdt_0_6b_v3]
        )

        // 4. Mint a SystemServices that carries the overrides plus an
        //    in-process NotificationCenter (so test runs don't
        //    cross-contaminate each other or the live process's
        //    default center) and a suite-scoped UserDefaults (so no
        //    preferences land in `~/Library/Preferences`).
        let systemServices = SystemServices(
            processInfo: .processInfo,
            fileManager: .default,
            userDefaults: Self.ephemeralUserDefaults(),
            urlSessionConfiguration: urlSessionConfig,
            notificationCenter: NotificationCenter(),
            seamOverrides: overrides
        )

        let services = try JotComposition.build(systemServices: systemServices)
        self.services = services

        // 5. Wire-up subset that dictation needs.
        //    Mirror `AppDelegate.wireUp` line 120 (`delivery.bind(recorder:)`)
        //    and lines 131-138 (the `$lastResult` → `delivery.deliver` sink).
        //    Pasteboard + logSink seam binds are handled inside
        //    `JotComposition.build` for the live graph; the harness graph
        //    inherits those because `Seams.pasteboard` / `.logSink` were
        //    already routed through `delivery.bind(pasteboard:)` /
        //    `bind(logSink:)` in the composition root.
        services.delivery.bind(recorder: services.recorder)

        deliveryBridge = services.recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak recorder = services.recorder, weak delivery = services.delivery] _ in
                Task { @MainActor [weak recorder, weak delivery] in
                    guard let text = recorder?.lastTranscript, !text.isEmpty else { return }
                    await delivery?.deliver(text)
                }
            }
    }

    deinit {
        // Phase 3 #32: synchronous release. `Gate` is a
        // `DispatchSemaphore`-backed class, so `signal()` is non-
        // blocking and thread-safe. No `Task { await ... }` hop,
        // so the next harness's `acquire()` sees the released slot
        // immediately when this harness's last strong ref drops.
        Self.gate.release()
    }

    // MARK: - Ephemeral defaults

    /// Mints a `UserDefaults` instance backed by a unique suite name so
    /// `@AppStorage` reads/writes during a test don't pollute the
    /// developer's `~/Library/Preferences/com.jot.Jot.plist` and don't
    /// leak across test cases.
    ///
    /// Phase 3 F4: `TranscriberHolder` reads from this suite (threaded
    /// in via `SystemServices.userDefaults`), so the active model id is
    /// per-graph instead of cross-suite-shared. SwiftUI views still
    /// observe `@AppStorage` on `.standard` — but those views are not
    /// constructed in test runs, so the cross-suite flake source for
    /// model id is closed.
    private static func ephemeralUserDefaults() -> UserDefaults {
        let suite = "com.jot.Jot.harness.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}
