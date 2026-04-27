import AppKit
import Foundation
import Sparkle
import SwiftData

/// OS-boundary inputs the composition root reads from. `JotComposition.build`
/// pulls every system-level handle from this struct — process info,
/// `FileManager`, `UserDefaults`, the URL session config used to mint the
/// network seam, and the notification center used by long-lived observers.
///
/// Production code passes `SystemServices.live`. Tests / harnesses substitute
/// fakes per-field. `@MainActor`-isolated because `FileManager` and
/// `UserDefaults` are not `Sendable` under Swift 6 strict concurrency, and
/// `JotComposition.build` is itself `@MainActor` — keeping the inputs in the
/// same isolation domain avoids forcing a synthetic `Sendable` conformance
/// on a Foundation reference type.
@MainActor
struct SystemServices {
    let processInfo: ProcessInfo
    let fileManager: FileManager
    let userDefaults: UserDefaults
    let urlSessionConfiguration: URLSessionConfiguration
    let notificationCenter: NotificationCenter
    /// Pre-resolved seam conformers for `JotComposition.build` to wire in
    /// instead of constructing the live `AudioCapture` / `Transcriber` /
    /// etc. Production passes `nil` (the default); the harness builds a
    /// `SeamOverrides` from its stub conformers and sets this field. Phase
    /// 1.4 acceptance: same controller graph (RecorderController,
    /// VoiceInputPipeline, DeliveryService, ArticulateController) wires
    /// against either live or stub seams depending on whether overrides
    /// were supplied.
    let seamOverrides: SeamOverrides?

    init(
        processInfo: ProcessInfo,
        fileManager: FileManager,
        userDefaults: UserDefaults,
        urlSessionConfiguration: URLSessionConfiguration,
        notificationCenter: NotificationCenter,
        seamOverrides: SeamOverrides? = nil
    ) {
        self.processInfo = processInfo
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.urlSessionConfiguration = urlSessionConfiguration
        self.notificationCenter = notificationCenter
        self.seamOverrides = seamOverrides
    }

    static let live = SystemServices(
        processInfo: .processInfo,
        fileManager: .default,
        userDefaults: .standard,
        urlSessionConfiguration: .default,
        notificationCenter: .default
    )
}

/// Pre-resolved seam conformers handed to `JotComposition.build` via
/// `SystemServices.seamOverrides` so the graph can be constructed against
/// test-flavored stubs instead of the live `AudioCapture` / `Transcriber`
/// / etc. Production never constructs this struct.
@MainActor
struct SeamOverrides {
    var audioCapture: (any AudioCapturing)?
    var transcriber: (any Transcribing)?
    var urlSession: URLSession?
    var appleIntelligence: (any AppleIntelligenceClienting)?
    var pasteboard: (any Pasteboarding)?
    var keychain: (any KeychainStoring)?
    var permissions: (any PermissionsObserving)?
    var logSink: (any LogSink)?
    /// Phase 4 hermetic-harness fix: lets the harness seed the
    /// `TranscriberHolder.installedModelIDs` set so `WizardFlowTests`
    /// don't depend on whether the dev/CI machine has a Parakeet model
    /// cached on disk. Production omits this and gets a real disk scan.
    var installedModelIDs: Set<ParakeetModelID>?

    init(
        audioCapture: (any AudioCapturing)? = nil,
        transcriber: (any Transcribing)? = nil,
        urlSession: URLSession? = nil,
        appleIntelligence: (any AppleIntelligenceClienting)? = nil,
        pasteboard: (any Pasteboarding)? = nil,
        keychain: (any KeychainStoring)? = nil,
        permissions: (any PermissionsObserving)? = nil,
        logSink: (any LogSink)? = nil,
        installedModelIDs: Set<ParakeetModelID>? = nil
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
        self.pasteboard = pasteboard
        self.keychain = keychain
        self.permissions = permissions
        self.logSink = logSink
        self.installedModelIDs = installedModelIDs
    }
}

/// Errors `JotComposition.build` can throw. Replaces the `try!` in
/// `AppDelegate`'s `modelContainer` initializer (was lines 56-65) with a
/// typed throw — boot is allowed to fail loudly when the persistence layer
/// is genuinely unrecoverable.
enum JotCompositionError: Error {
    case modelContainerUnavailable(underlying: Error)
}

/// Resolved object graph for the running app. After Phase 0 the eight
/// OS-boundary seams are still concrete live types — the protocol shapes
/// land in Phases 0.3–0.10 and the field names here are the rename targets.
///
/// The remaining fields are app-level controllers that `AppDelegate`
/// previously constructed eagerly (see `Sources/App/AppDelegate.swift`
/// lines 12-98 and 104-253 in the pre-Phase-0 source).
@MainActor
struct AppServices {
    // MARK: - Eight OS-boundary seams (Phase 0 acceptance criterion)
    // Field names match the protocol shapes in cleanup-roadmap.md so the
    // type rename in 0.3-0.10 is mechanical.

    let audioCapture: any AudioCapturing            // 0.3 protocol seam landed
    /// Phase 3 F4: per-graph `TranscriberHolder` replaces a free-floating
    /// `any Transcribing` field on `AppServices`. Consumers read
    /// `transcriberHolder.transcriber` for the live instance and bind
    /// `transcriberHolder.primaryModelID` for the active model id.
    let transcriberHolder: TranscriberHolder
    let urlSession: URLSession                      // 0.5 → URLProtocol-based stub
    let appleIntelligence: any AppleIntelligenceClienting  // 0.6 protocol seam landed
    let pasteboard: any Pasteboarding               // 0.7 protocol seam landed
    let keychain: any KeychainStoring               // 0.8 protocol seam landed
    let permissions: any PermissionsObserving       // 0.9 protocol seam landed
    let logSink: any LogSink                        // 0.10 protocol seam landed (hot-path migration only)

    // MARK: - App-level controllers (constructed, not yet started)

    /// Phase 3 #29: `LLMConfiguration` is per-graph now (no `.shared`
    /// singleton). Constructed in `build(systemServices:)` with the
    /// `keychain` seam threaded in so cloud-provider auth reads
    /// route through the seam (production: `LiveKeychain`; harness:
    /// `StubKeychain`).
    let llmConfiguration: LLMConfiguration

    let pipeline: VoiceInputPipeline
    let recorder: RecorderController
    let delivery: DeliveryService
    let articulateController: ArticulateController
    let hotkeyRouter: HotkeyRouter
    let menuBar: JotMenuBarController
    let overlay: OverlayWindowController
    let recordingPersister: RecordingPersister
    let retention: RetentionService
    let soundTriggers: SoundTriggers
    let updaterController: SPUStandardUpdaterController
    let modelContainer: ModelContainer
}

extension AppServices {
    /// Live AppServices resolved via `NSApp.delegate`. SwiftUI views and
    /// other call sites that can't take constructor injection (e.g. the
    /// "Test Connection" button in `Sources/Settings/ArticulatePane.swift`
    /// and stored-property `LLMClient` instances on wizard step views)
    /// use this to read `services.urlSession` without plumbing the seam
    /// through five SwiftUI parent layers.
    ///
    /// Returns `nil` only if `NSApp.delegate` is not yet an `AppDelegate`,
    /// which in production happens only during process bootstrap before
    /// `applicationDidFinishLaunching` has assigned `services`. SwiftUI
    /// scene bodies do not evaluate that early, so production reads are
    /// safe to force-unwrap if the call site is on a SwiftUI surface.
    @MainActor
    static var live: AppServices? {
        (NSApp.delegate as? AppDelegate)?.services
    }

}

/// Composition root. Owns the construction order of the live graph;
/// nothing is started, observed, activated, or bound here. Post-construction
/// wire-up (binding delivery, activating the hotkey router, installing the
/// menu bar / overlay panels, starting persister / sound-triggers /
/// retention timers, observing windows, presenting the setup wizard,
/// pre-warming Parakeet) lives in `AppDelegate.wireUp(_:)` so AppDelegate
/// owns the cancellables and observers that those side effects produce.
@MainActor
enum JotComposition {

    static func build(systemServices: SystemServices) throws -> AppServices {
        let overrides = systemServices.seamOverrides
        // ORDERING INVARIANT: `VoiceInputPipeline`, `RecorderController`,
        // and `DeliveryService` must exist before the first `WindowGroup`
        // body runs (see AppDelegate's pre-Phase-0 stored-property comment
        // on line 14). Constructing them first inside `build` preserves
        // that contract — `AppServices` is handed to AppDelegate before
        // SwiftUI scenes resolve.

        // Eight seams. Production's `SystemServices.live` carries
        // `seamOverrides == nil`, so each seam falls through to its
        // live conformer (behavior identical to pre-Phase-1.4). The
        // harness's `SystemServices` populates `seamOverrides` with
        // pre-built stub conformers, which the graph wires in instead
        // — same controller-construction code, different OS seam
        // instances.
        let audioCapture: any AudioCapturing = overrides?.audioCapture ?? AudioCapture()
        // Phase 3 F4: TranscriberHolder is the single source of truth for
        // the active model. Production: factory builds a fresh
        // `Transcriber(modelID:)` per swap. Harness: `overrides?.transcriber`
        // is captured into the factory so all factory calls return the same
        // stub instance (model swaps don't matter for the stub, but the
        // closure shape lets a future swap-aware harness rebuild as needed).
        let transcriberHolder = TranscriberHolder(
            cache: .shared,
            defaults: systemServices.userDefaults,
            transcriberFactory: { modelID in
                if let override = overrides?.transcriber {
                    return override
                }
                return Transcriber(modelID: modelID)
            },
            installedModelIDs: overrides?.installedModelIDs
        )
        let urlSession = overrides?.urlSession ?? URLSession(configuration: systemServices.urlSessionConfiguration)
        let appleIntelligence: any AppleIntelligenceClienting = overrides?.appleIntelligence ?? AppleIntelligenceClient()
        let pasteboard: any Pasteboarding = overrides?.pasteboard ?? LivePasteboard()
        let keychain: any KeychainStoring = overrides?.keychain ?? LiveKeychain()
        let permissions: any PermissionsObserving = overrides?.permissions ?? PermissionsService.shared
        let logSink: any LogSink = overrides?.logSink ?? ErrorLog.shared

        // SwiftData stack. Mirrors AppDelegate's pre-Phase-0
        // `modelContainer` stored property (lines 35-66) verbatim:
        //   - Pin the store to ~/Library/Application Support/Jot/default.store
        //     so Jot's sqlite stays in its own namespace.
        //   - Migrate from the pre-fix root location once if needed
        //     (existing users keep their recording history).
        //   - On unrecoverable load failure, fall back to an in-memory
        //     store so the app can still boot. The previous
        //     `try!` (line 64) becomes a typed throw — a fallback that
        //     itself fails is genuinely unrecoverable.
        let fm = systemServices.fileManager
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jotDir = appSupportRoot.appendingPathComponent("Jot", isDirectory: true)
        try? fm.createDirectory(at: jotDir, withIntermediateDirectories: true)

        let newURL = jotDir.appendingPathComponent("default.store")
        let oldURL = appSupportRoot.appendingPathComponent("default.store")

        if fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) {
            for suffix in ["", "-wal", "-shm"] {
                let src = appSupportRoot.appendingPathComponent("default.store\(suffix)")
                let dst = jotDir.appendingPathComponent("default.store\(suffix)")
                try? fm.moveItem(at: src, to: dst)
            }
        }

        let modelContainer: ModelContainer
        do {
            let config = ModelConfiguration(url: newURL)
            modelContainer = try ModelContainer(for: Recording.self, configurations: config)
        } catch {
            do {
                let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(for: Recording.self, configurations: memoryConfig)
            } catch {
                throw JotCompositionError.modelContainerUnavailable(underlying: error)
            }
        }

        // App-level controllers. Construction order matches AppDelegate's
        // pre-Phase-0 `applicationDidFinishLaunching` body (lines 104-253):
        // pipeline → recorder → delivery → articulate → hotkey router →
        // menu bar → overlay → persister → retention → sound triggers.
        // Phase 3 F4: `TranscriberHolder` (constructed above) replaces
        // a free-floating `any Transcribing` field on `AppServices`.
        // Pipeline + persister read `transcriberHolder.transcriber`
        // for the live instance, so a `setPrimary(_:)` swap propagates
        // without re-binding consumers. Harness flow tests substitute
        // `any Transcribing` via `SeamOverrides.transcriber`, which
        // the holder's factory closure captures.
        //
        // Phase 3 #29: `LLMConfiguration` is per-graph (no `.shared`
        // singleton). Construction takes the `keychain` seam directly
        // so cloud-provider apiKey reads route through it; harness's
        // `StubKeychain` is what the harness's `LLMConfiguration`
        // talks to.
        let llmConfiguration = LLMConfiguration(
            keychain: keychain,
            defaults: systemServices.userDefaults
        )
        let pipeline = VoiceInputPipeline(
            capture: audioCapture,
            transcriberHolder: transcriberHolder,
            permissions: permissions
        )
        let recorder = RecorderController(
            pipeline: pipeline,
            urlSession: urlSession,
            appleIntelligence: appleIntelligence,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )
        // Phase 3 #30: `DeliveryService` is per-graph now (no
        // `.shared` singleton), so seams come in at init instead of
        // via `bind(pasteboard:)` / `bind(logSink:)` setters. Two
        // parallel test harnesses can no longer race on the singleton.
        let delivery = DeliveryService(
            pasteboard: pasteboard,
            logSink: logSink,
            permissions: permissions
        )
        // Note: `delivery.bind(recorder:)` is wire-up, not construction; it
        // runs in `AppDelegate.wireUp(_:)` after this method returns.
        // Without that call, `DeliveryService` never receives its recorder
        // reference and dictation silently fails to deliver. (Recorder is
        // built before delivery, but the recorder→delivery edge is wired
        // post-construction so the deliveryBridge Combine sink can be
        // installed at the same time as the other AppDelegate observers.)

        let articulateController = ArticulateController(
            pipeline: pipeline,
            urlSession: urlSession,
            appleIntelligence: appleIntelligence,
            pasteboard: pasteboard,
            llmConfiguration: llmConfiguration,
            logSink: logSink
        )

        let hotkeyRouter = HotkeyRouter(
            recorder: recorder,
            delivery: delivery,
            articulateController: articulateController
        )

        // Sparkle updater is constructed before `menuBar` so the menu's
        // "Check for Updates…" closure can capture it directly. AppDelegate
        // pre-Phase-0 had `updaterController` as a stored property and
        // routed through `self.checkForUpdates()`; here the closure captures
        // the local `updaterController` value, which keeps `services.menuBar`
        // self-contained (no AppDelegate hop required).
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let menuBar = JotMenuBarController(
            recorder: recorder,
            delivery: delivery,
            modelContext: modelContainer.mainContext,
            transcriberHolder: transcriberHolder,
            pasteboard: pasteboard,
            checkForUpdatesAction: { updaterController.checkForUpdates(nil) }
        )

        let overlay = OverlayWindowController(
            recorder: recorder,
            delivery: delivery,
            articulateController: articulateController,
            pipeline: pipeline
        )

        let recordingPersister = RecordingPersister(
            recorder: recorder,
            context: modelContainer.mainContext,
            transcriberHolder: transcriberHolder
        )

        let retention = RetentionService(context: modelContainer.mainContext)

        let soundTriggers = SoundTriggers()

        return AppServices(
            audioCapture: audioCapture,
            transcriberHolder: transcriberHolder,
            urlSession: urlSession,
            appleIntelligence: appleIntelligence,
            pasteboard: pasteboard,
            keychain: keychain,
            permissions: permissions,
            logSink: logSink,
            llmConfiguration: llmConfiguration,
            pipeline: pipeline,
            recorder: recorder,
            delivery: delivery,
            articulateController: articulateController,
            hotkeyRouter: hotkeyRouter,
            menuBar: menuBar,
            overlay: overlay,
            recordingPersister: recordingPersister,
            retention: retention,
            soundTriggers: soundTriggers,
            updaterController: updaterController,
            modelContainer: modelContainer
        )
    }
}
