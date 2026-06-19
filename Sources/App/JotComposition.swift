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
    /// VoiceInputPipeline, DeliveryService, RewriteController) wires
    /// against either live or stub seams depending on whether overrides
    /// were supplied.
    let seamOverrides: SeamOverrides?
    /// When `true`, `JotComposition.build` constructs a SwiftData
    /// `ModelContainer` backed by an in-memory store instead of the live
    /// `~/Library/Application Support/Jot/default.store`. Harness flow
    /// tests set this so persistence work (e.g. `RewriteSession` writes
    /// from `RewriteController.persistSession(...)`) doesn't pollute the
    /// real on-disk store. Production omits this and gets the persistent
    /// store.
    let useInMemoryModelStore: Bool

    init(
        processInfo: ProcessInfo,
        fileManager: FileManager,
        userDefaults: UserDefaults,
        urlSessionConfiguration: URLSessionConfiguration,
        notificationCenter: NotificationCenter,
        seamOverrides: SeamOverrides? = nil,
        useInMemoryModelStore: Bool = false
    ) {
        self.processInfo = processInfo
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.urlSessionConfiguration = urlSessionConfiguration
        self.notificationCenter = notificationCenter
        self.seamOverrides = seamOverrides
        self.useInMemoryModelStore = useInMemoryModelStore
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
    /// Streaming-option migration seam: lets harness tests stub the
    /// "is the user's recordings directory empty?" signal that
    /// `ModelChoiceMigration` reads as part of the §3.4.4 freshness
    /// heuristic. Production omits this and gets a real
    /// `~/Library/Application Support/Jot/Recordings/` scan.
    var recordingsDirectoryEmpty: Bool?

    init(
        audioCapture: (any AudioCapturing)? = nil,
        transcriber: (any Transcribing)? = nil,
        urlSession: URLSession? = nil,
        appleIntelligence: (any AppleIntelligenceClienting)? = nil,
        pasteboard: (any Pasteboarding)? = nil,
        keychain: (any KeychainStoring)? = nil,
        permissions: (any PermissionsObserving)? = nil,
        logSink: (any LogSink)? = nil,
        installedModelIDs: Set<ParakeetModelID>? = nil,
        recordingsDirectoryEmpty: Bool? = nil
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
        self.recordingsDirectoryEmpty = recordingsDirectoryEmpty
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
    let rewriteController: RewriteController
    let hotkeyRouter: HotkeyRouter
    let menuBar: JotMenuBarController
    let overlay: OverlayWindowController
    let recordingPersister: RecordingPersister
    let retention: RetentionService
    let soundTriggers: SoundTriggers
    let updaterController: SPUStandardUpdaterController
    let modelContainer: ModelContainer
    /// Bundled-prompt store + per-prompt usage. Strong-retain so the
    /// router's weak opener closure has something to call into; also
    /// future call sites (Settings → Prompts pane in Phase 2) can read
    /// the same store rather than building a second one.
    let promptStore: PromptStore
    /// Prompt Picker palette controller. Strong-retain for the app's
    /// lifetime — the router's `promptPickerOpener` captures it weakly,
    /// so without this field the controller would be deallocated as
    /// soon as `build()` returns and holding Rewrite would silently
    /// no-op (Codex review, 2026-05-17).
    let promptPicker: PromptPickerController
    /// Speaker Labels piece A: lifecycle owner for the Sortformer model.
    /// `.notSetUp` for existing users on update; transitions are driven
    /// by Settings → Speaker Labels.
    let sortformerHolder: SortformerHolder
    /// Speaker Labels piece A: SwiftData-backed identity list + writer.
    /// Held strongly so SwiftUI surfaces (`SpeakerLabelsPane`) can observe
    /// via `@EnvironmentObject` without holding their own context handle.
    let enrolledIdentitiesStore: EnrolledIdentitiesStore
}

extension AppServices {
    /// Live AppServices resolved via `NSApp.delegate`. SwiftUI views and
    /// other call sites that can't take constructor injection (e.g. the
    /// "Test Connection" button in `Sources/Settings/RewritePane.swift`
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

        // Streaming-option v1.7 pin migration. Runs BEFORE
        // `TranscriberHolder` is constructed so the holder's `init` reads
        // whatever the migration writes to `jot.defaultModelID`. Idempotent
        // — re-runs are no-ops once `pinChecked` is set. Inputs are
        // computed once and reused for the holder's `installedModelIDs`
        // seed so a single cache scan covers both.
        //
        // §3.4.4 freshness signals: explicit key set, any Parakeet bundle
        // cached, or recordings on disk. The recordings check uses
        // FileManager directly rather than touching SwiftData; tests
        // override it via `seamOverrides.recordingsDirectoryEmpty`.
        let installedModelIDs: Set<ParakeetModelID> = overrides?.installedModelIDs
            ?? Set(ParakeetModelID.allCases.filter { ModelCache.shared.isCached($0) })
        let recordingsDirectoryEmpty: Bool = overrides?.recordingsDirectoryEmpty ?? {
            let appSupport = systemServices.fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let recordingsDir = appSupport.appendingPathComponent("Jot/Recordings", isDirectory: true)
            guard systemServices.fileManager.fileExists(atPath: recordingsDir.path) else { return true }
            let contents = (try? systemServices.fileManager.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
            return contents.isEmpty
        }()
        ModelChoiceMigration.runV17PinIfNeeded(
            defaults: systemServices.userDefaults,
            installedModelIDs: installedModelIDs,
            recordingsDirectoryEmpty: recordingsDirectoryEmpty
        )
        ModelChoiceMigration.runFourOptionMigrationIfNeeded(
            defaults: systemServices.userDefaults
        )
        // v1.12: rewrites stored `tdt_0_6b_v3_nemotron_streaming` →
        // `tdt_0_6b_v3_eou_streaming`. Runs after the four-option migration
        // so any user whose primary was just rewritten to the legacy
        // pairing by that migration also gets moved to the new EOU primary
        // in a single launch. Idempotent (one-shot key).
        ModelChoiceMigration.runV12EouRenameIfNeeded(
            defaults: systemServices.userDefaults
        )
        // `runV20DefaultStampIfNeeded` is retained for old tests/rollback
        // history, but the active release boundary is the four-option
        // Nemotron migration above plus v1.12's EOU rename.

        // Phase 3 F4: TranscriberHolder is the single source of truth for
        // the active model. Production: factory builds a fresh
        // `Transcriber(modelID:)` per swap. Harness: `overrides?.transcriber`
        // is captured into the factory so all factory calls return the same
        // stub instance (model swaps don't matter for the stub, but the
        // closure shape lets a future swap-aware harness rebuild as needed).
        // Language migration (design §6.4): additively seed
        // `jot.transcriptionLanguage` from the stored model. One-shot,
        // never clobbers `jot.defaultModelID`. Runs after the model
        // migrations above so it reads the post-migration stored model.
        LanguageMigration.runIfNeeded(defaults: systemServices.userDefaults)
        // Nemotron auto-upgrade gate (one-shot). Runs AFTER LanguageMigration
        // so it reads the seeded `jot.transcriptionLanguage` key. Only sets a
        // pending marker — never touches `jot.defaultModelID`. The actual
        // download-first-then-flip happens later in
        // `TranscriberHolder.startPendingNemotronUpgradeIfNeeded()`, so
        // dictation keeps working on the current model while Nemotron fetches.
        NemotronAutoUpgradeMigration.runIfNeeded(defaults: systemServices.userDefaults)
        // One-shot cleanup of the orphaned EOU streaming bundle. EOU was
        // removed in favour of batch-pseudo-streaming preview, so any
        // `parakeet-eou-streaming/` directory left from a prior version is dead
        // weight on disk. Gated behind a marker so it runs at most once.
        let eouCleanupKey = "jot.modelChoice.eouBundleCleaned"
        if !systemServices.userDefaults.bool(forKey: eouCleanupKey) {
            ModelCache.shared.removeOrphanedEouBundle()
            systemServices.userDefaults.set(true, forKey: eouCleanupKey)
        }
        let transcriberHolder = TranscriberHolder(
            cache: .shared,
            defaults: systemServices.userDefaults,
            transcriberFactory: { modelID, language in
                if let override = overrides?.transcriber {
                    return override
                }
                switch modelID {
                case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:
                    // English (v2, ineligible hardware) and every European
                    // language (v3) now drive their live preview through the
                    // batch-pseudo-streaming `PreviewScheduler` — the SAME
                    // engine validated for JA — instead of the EOU streaming
                    // bundle. The scheduler re-runs the SAME batch `Transcriber`
                    // instance over a trailing window, so the preview re-uses
                    // the already-loaded `AsrModels` (single model load) and
                    // tracks the final pass closely (design §8). `spaceless` is
                    // `false` for Latin/Cyrillic, so `join` keeps the word
                    // separator. The final transcript path is unchanged (batch
                    // `Transcriber.transcribe`; v2-gated post-processing + vocab
                    // on stop).
                    //
                    let batch = Transcriber(modelID: modelID, language: language)
                    return DualPipelineTranscriber(
                        batch: batch,
                        batchPreview: PreviewScheduler(
                            transcriber: batch,
                            spaceless: language.isSpaceless
                        )
                    )
                case .tdt_0_6b_v3_nemotron_streaming:
                    // Pre-v1.12 pairing kept for users who land here briefly
                    // before `runV12EouRenameIfNeeded` rewrites their
                    // stored default. Defensive — the migration runs first
                    // in `JotComposition.build`, so this branch is
                    // effectively dead in production but preserved for
                    // rollback / debug paths.
                    guard let streamingURL = ModelCache.shared.streamingPartialCacheURL(for: modelID) else {
                        return Transcriber(modelID: modelID, language: language)
                    }
                    return DualPipelineTranscriber(
                        batch: Transcriber(modelID: modelID, language: language),
                        nemotronStreaming: NemotronStreamingTranscriber(bundleDirectory: streamingURL)
                    )
                case .nemotron_en:
                    guard let streamingURL = ModelCache.shared.streamingPartialCacheURL(for: modelID) else {
                        return Transcriber(modelID: modelID, language: language)
                    }
                    return DualPipelineTranscriber(
                        nemotron: NemotronStreamingTranscriber(bundleDirectory: streamingURL)
                    )
                case .tdt_0_6b_ja:
                    // Japanese: batch final transcript + batch-pseudo-streaming
                    // live preview. JA has no paired streaming bundle
                    // (`supportsStreaming == false`), so the `PreviewScheduler`
                    // re-runs the SAME batch model over a trailing window to
                    // drive the pill — the only path to a JA live preview
                    // (docs/batch-pseudo-streaming/japanese-preview.md).
                    //
                    // The scheduler is constructed over the SAME `Transcriber`
                    // instance passed as `batch:`, so the preview re-uses the
                    // already-loaded `AsrModels` (no second model load), and
                    // `spaceless: true` makes the preview join CJK text without
                    // spurious inter-word spaces. The final transcript still
                    // runs the JA batch model + `JapaneseVocabularySubstituter`
                    // on stop (vocab deferred to the final pass, same as v2/v3).
                    let jaBatch = Transcriber(modelID: modelID, language: language)
                    return DualPipelineTranscriber(
                        batch: jaBatch,
                        batchPreview: PreviewScheduler(
                            transcriber: jaBatch,
                            spaceless: language.isSpaceless
                        )
                    )
                case .tdt_0_6b_v3, .tdt_0_6b_v3_int4:
                    return Transcriber(modelID: modelID, language: language)
                }
            },
            installedModelIDs: installedModelIDs
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
        //
        // Test-only short-circuit: harness flow tests pass
        // `useInMemoryModelStore: true` so the SwiftData container is
        // backed by an in-memory store (no real `default.store` writes).
        // The filesystem migration / cleanup dance below MUST be gated
        // behind this flag — otherwise tests still touch the real
        // `~/Library/Application Support/Jot/` tree on the dev/CI
        // machine.
        let fm = systemServices.fileManager
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jotDir = appSupportRoot.appendingPathComponent("Jot", isDirectory: true)
        let newURL = jotDir.appendingPathComponent("default.store")

        if !systemServices.useInMemoryModelStore {
            try? fm.createDirectory(at: jotDir, withIntermediateDirectories: true)

            let oldURL = appSupportRoot.appendingPathComponent("default.store")

            if fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) {
                for suffix in ["", "-wal", "-shm"] {
                    let src = appSupportRoot.appendingPathComponent("default.store\(suffix)")
                    let dst = jotDir.appendingPathComponent("default.store\(suffix)")
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }

        // Silent one-shot cleanup of v1.0-era orphans:
        //  • FluidAudio model cache (~443 MB) at app-support root.
        //  • Any default.store{,-shm,-wal} at app-support root that
        //    pre-dated the v1→v2 SwiftData store relocation.
        //
        // FluidAudio cleanup is safe ONLY when a current Parakeet model
        // (v3 or ja) is already cached at the new path
        // (~/Library/Application Support/Jot/Models/Parakeet/).
        // Otherwise we'd remove a v1.0 user's only model copy — current
        // code doesn't read from FluidAudio/Models/, so they were
        // already in 'still loading' purgatory, but removing the bytes
        // would make that state permanent. Skipping cleanup leaves
        // 443 MB on disk; it's the lesser evil.
        //
        // The migration sentinel is only set once cleanup actually runs,
        // so a future launch (after the user redownloads via Setup
        // Wizard / Transcription pane) will perform the cleanup.
        let anyCurrentModelCached = ParakeetModelID.allCases.contains { ModelCache.shared.isCached($0) }
        let didCleanup = systemServices.userDefaults.bool(forKey: "jot.migration.fluidAudioCleanupV1")
        if !systemServices.useInMemoryModelStore && !didCleanup && anyCurrentModelCached {
            try? fm.removeItem(at: appSupportRoot.appendingPathComponent("FluidAudio"))
            // Per-suffix orphan cleanup: only run if the main store
            // moved successfully (proves the v1→v2 SwiftData relocation
            // ran). Then delete any source that exists at root,
            // independent of whether each suffix has a destination —
            // SQLite -wal / -shm are legitimately absent on clean
            // shutdown, so 'destination missing' doesn't mean 'don't
            // delete the orphan source'.
            if fm.fileExists(atPath: jotDir.appendingPathComponent("default.store").path) {
                for suffix in ["", "-shm", "-wal"] {
                    let src = appSupportRoot.appendingPathComponent("default.store\(suffix)")
                    if fm.fileExists(atPath: src.path) {
                        try? fm.removeItem(at: src)
                    }
                }
            }
            systemServices.userDefaults.set(true, forKey: "jot.migration.fluidAudioCleanupV1")
        }

        let modelContainer: ModelContainer
        if systemServices.useInMemoryModelStore {
            // Harness flow tests pass `useInMemoryModelStore: true` so
            // `RewriteSession` writes from `RewriteController.persistSession(...)`
            // and `Recording` writes from `RecordingPersister` land in an
            // in-memory store rather than `default.store` on disk. Without
            // this seam, every harness rewrite test row would persist into
            // the real user library on the dev/CI machine.
            do {
                let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(
                    for: Recording.self, RewriteSession.self, PromptUsage.self, UserPrompt.self, EnrolledIdentity.self,
                    configurations: memoryConfig
                )
            } catch {
                throw JotCompositionError.modelContainerUnavailable(underlying: error)
            }
        } else {
            do {
                let config = ModelConfiguration(url: newURL)
                modelContainer = try ModelContainer(
                    for: Recording.self, RewriteSession.self, PromptUsage.self, UserPrompt.self, EnrolledIdentity.self,
                    configurations: config
                )
            } catch {
                do {
                    let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                    modelContainer = try ModelContainer(
                        for: Recording.self, RewriteSession.self, PromptUsage.self, UserPrompt.self, EnrolledIdentity.self,
                        configurations: memoryConfig
                    )
                } catch {
                    throw JotCompositionError.modelContainerUnavailable(underlying: error)
                }
            }
        }

        // App-level controllers. Construction order matches AppDelegate's
        // pre-Phase-0 `applicationDidFinishLaunching` body (lines 104-253):
        // pipeline → recorder → delivery → rewrite → hotkey router →
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

        let rewriteController = RewriteController(
            pipeline: pipeline,
            urlSession: urlSession,
            appleIntelligence: appleIntelligence,
            pasteboard: pasteboard,
            llmConfiguration: llmConfiguration,
            modelContext: modelContainer.mainContext,
            logSink: logSink
        )

        let hotkeyRouter = HotkeyRouter(
            recorder: recorder,
            delivery: delivery,
            rewriteController: rewriteController
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
            rewriteController: rewriteController,
            pipeline: pipeline,
            transcriberHolder: transcriberHolder
        )

        // Startup self-heal routing (design §Phase 3): the holder routes the
        // user to Settings → Transcription on detection / failure, and the
        // persistent repairing pill routes there on tap. Both go through the
        // menu bar's `openTranscriptionSettings(...)` deep-link so the window
        // is opened (or re-selected) from any launch state — hotkey-only users
        // included. Captured weakly so neither closure retains the menu bar.
        transcriberHolder.routeToSettings = { [weak menuBar] in
            menuBar?.openTranscriptionSettings()
        }
        overlay.pillViewModel.onRepairPillTap = { [weak menuBar] in
            menuBar?.openTranscriptionSettings()
        }

        // Wire the Prompt Picker tap-vs-hold dispatcher onto the
        // `.rewrite` hotkey now that the overlay exists. The picker
        // opener itself is set later (when the PromptPickerController
        // is constructed — Phase 1 of the picker rollout). Until then,
        // a completed hold collapses the pill but does not open
        // anything; the tap path remains today's default rewrite.
        hotkeyRouter.installRewriteHoldDispatch(
            setHoldProgress: { [weak pillVM = overlay.pillViewModel] progress in
                pillVM?.showHoldProgress(progress)
            },
            clearHoldProgress: { [weak pillVM = overlay.pillViewModel] in
                pillVM?.clearHoldProgress()
            }
        )

        // Prompt Picker — bundled library + per-prompt usage stats live
        // alongside the existing Library models in the same SwiftData
        // store. The opener closure is registered on the router so a
        // hold-past-threshold press surfaces the palette.
        let promptStore = PromptStore(modelContext: modelContainer.mainContext)
        let promptPicker = PromptPickerController(
            store: promptStore,
            rewriteController: rewriteController,
            activeProvider: { [weak llmConfiguration] in
                llmConfiguration?.provider.rawValue
            }
        )
        hotkeyRouter.setPromptPickerOpener { [weak promptPicker] in
            promptPicker?.open()
        }

        // Wire the TAP-default resolver: a TAP on the Rewrite hotkey fires
        // the user-selected default prompt (Settings → Prompts or the
        // picker's "Set as default") through the fixed-prompt path. Returns
        // nil when no default is set / the selection no longer resolves, so
        // the tap falls back to the editable shared Rewrite prompt.
        rewriteController.defaultRewriteResolver = { [weak promptStore] in
            guard let prompt = promptStore?.defaultPrompt() else { return nil }
            return (body: prompt.body, title: prompt.title)
        }

        // Speaker Labels piece A: lifecycle for the Sortformer diarization
        // model. Defaults to `.notSetUp` on existing installs — the
        // Settings pane CTA + post-stop labeling are gated on identities
        // being enrolled and the master toggle being ON.
        let sortformerHolder = SortformerHolder()
        let enrolledIdentitiesStore = EnrolledIdentitiesStore(
            context: modelContainer.mainContext
        )

        let recordingPersister = RecordingPersister(
            recorder: recorder,
            context: modelContainer.mainContext,
            transcriberHolder: transcriberHolder,
            sortformerHolder: sortformerHolder
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
            rewriteController: rewriteController,
            hotkeyRouter: hotkeyRouter,
            menuBar: menuBar,
            overlay: overlay,
            recordingPersister: recordingPersister,
            retention: retention,
            soundTriggers: soundTriggers,
            updaterController: updaterController,
            modelContainer: modelContainer,
            promptStore: promptStore,
            promptPicker: promptPicker,
            sortformerHolder: sortformerHolder,
            enrolledIdentitiesStore: enrolledIdentitiesStore
        )
    }
}
