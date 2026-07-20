import Foundation

/// Phase 3 F4: single source of truth for "which Parakeet model is
/// active and which `any Transcribing` instance the rest of the graph
/// should call". Replaces 3 scattered `@AppStorage("jot.defaultModelID")`
/// reads + 1 raw `UserDefaults.standard.string(forKey:)` read +
/// `RecordingPersister`'s hardcoded default with one observable holder
/// constructed in `JotComposition.build`.
///
/// **Why a holder, not a published property on the pipeline:**
/// callers come in three flavors —
///   1. Settings panes that read & mutate the active model (Picker)
///   2. SwiftUI surfaces that need the `any Transcribing` instance for
///      re-transcribe / wizard test (currently via `@Environment`)
///   3. RecordingPersister that needs the model id to stamp on each
///      `Recording` row.
/// A single observable owner gives all three a coherent view, and lets
/// us swap the inner `Transcribing` instance on a primary-model change
/// without re-wiring the call sites.
///
/// **Phase 4 follow-ups:**
/// - When a 2nd `ParakeetModelID` variant ships, `setPrimary(_:)` will
///   need to unload the old `Transcriber`'s ANE handle before dropping
///   the reference. Today's `Transcriber` doesn't expose `unload()`;
///   the swap path drops the reference and lets ARC clean up (a brief
///   memory spike during the model swap is acceptable for the rare
///   case).
@MainActor
final class TranscriberHolder: ObservableObject {

    /// Startup model-integrity self-heal state (design Phase 3 / G4). A
    /// **third producer** sibling to `migrationDownloadProgress/Error` — it
    /// is NOT a `RecorderController.State` case (that enum has 8 switch sites
    /// + two auto-clear layers; repairing is not a recording-lifecycle state).
    /// Both the `JotAppWindow` banner and the persistent Overlay pill render
    /// directly off `$repairState`, so the pill is naturally persistent (never
    /// handed to `scheduleDismiss`/`scheduleAutoRecoveryIfNeeded`).
    enum RepairState: Equatable {
        /// Re-downloading the active model after a failed launch probe.
        /// `modelName` is the model's `displayName` so surfaces can name what
        /// is being repaired; `progress` is `nil` until the first byte
        /// fraction lands.
        case downloading(modelName: String, progress: Double?)
        /// Self-heal could not complete; the user is routed to Settings →
        /// Transcription and the persistent pill stays up as the backup.
        /// `modelName` names the model that could not be repaired.
        case failed(modelName: String, reason: FailReason)

        enum FailReason: Equatable {
            /// The corrupt files survived the surgical purge (locked /
            /// permission) — re-download would no-op, so we bail (review M5).
            case cannotPurge
            /// The re-download itself failed (offline, server error). Marker
            /// discipline retries on the next launch.
            case download
        }

        /// The model `displayName` carried by either case — so UI can name the
        /// model without unwrapping the case.
        var modelName: String {
            switch self {
            case .downloading(let modelName, _): return modelName
            case .failed(let modelName, _): return modelName
            }
        }
    }

    @Published private(set) var repairState: RepairState?

    /// One-shot guard so a single launch never kicks off two self-heals
    /// (mirrors `nemotronUpgradeStarted` / `migrationDownloadStarted`).
    private var selfHealStarted = false

    /// Injected by composition (`JotComposition.build`) so the holder can
    /// route the user to Settings → Transcription on detection / failure
    /// without importing AppKit or the MenuBar layer. No-op default for
    /// tests / harnesses that don't wire a router.
    var routeToSettings: (@MainActor () -> Void)?

    @Published private(set) var primaryModelID: ParakeetModelID
    /// The active transcription language (design §5.4). Additive to
    /// `primaryModelID`: it drives the FluidAudio script hint and the
    /// language-picker UI, while `primaryModelID` stays the authoritative
    /// stored-model source of truth. They can disagree (a grandfathered v3 /
    /// Nemotron user whose language is `.english`) — `primaryModelID` wins so
    /// we never trigger a surprise download (design §5.4.1).
    @Published private(set) var activeLanguage: LanguageChoice
    @Published private(set) var transcriber: any Transcribing
    @Published private(set) var installedModelIDs: Set<ParakeetModelID>
    @Published private(set) var migrationDownloadProgress: Double?
    @Published private(set) var migrationDownloadError: String?

    /// A **manual** model/language switch whose target model isn't on disk yet
    /// (menu bar "Switch model" or the Settings language picker). Sibling to the
    /// migration and repair producers, deliberately kept OFF the shared
    /// `migrationDownloadProgress` banner state: a manual switch is
    /// user-initiated and interactive, so it must not silently defer behind a
    /// background migration the way the migration paths defer behind each other.
    ///
    /// The invariant matches the migration paths' download-first-then-flip
    /// (`startPendingNemotronUpgradeIfNeeded` §:312-317): the user keeps
    /// dictating on their CURRENT model the whole time the target downloads —
    /// `primaryModelID` / `activeLanguage` are NOT touched until the target's
    /// bytes are on disk, and no old model file is ever deleted on a switch.
    enum PendingSwitch {
        /// Downloading `target` while `from` stays the live, usable model.
        /// `language` is non-nil for a Settings language switch (so the picker
        /// can keep showing the user's chosen language mid-download) and nil for
        /// a model-only menu-bar switch. `progress` is `nil` until the first
        /// byte fraction lands, then carries the rich `ModelDownloadProgress`
        /// (bytes / speed / ETA, plus the terminal `.preparing` phase while
        /// CoreML compiles / loads so 100% doesn't dead-air).
        case downloading(target: ParakeetModelID, from: ParakeetModelID,
                         language: LanguageChoice?, progress: ModelDownloadProgress?)
        /// A retriable failure (host outage / transient corrupt fetch): the app
        /// stayed on `from` and is dictating normally while Jot auto-retries the
        /// download with backoff. `error` is the classified reason (for the UI
        /// message); `nextRetryAt` is when the next automatic attempt fires
        /// (`nil` while an attempt is actually in flight).
        case retrying(target: ParakeetModelID, from: ParakeetModelID,
                      language: LanguageChoice?, error: ModelDownloadError,
                      nextRetryAt: Date?)
        /// A non-retriable failure (offline / disk full / unclassified): the app
        /// stayed on `from`. The persisted intent survives, so a relaunch or a
        /// "Retry" tap re-attempts; there is no automatic backoff loop here.
        case failed(target: ParakeetModelID, from: ParakeetModelID,
                    language: LanguageChoice?, error: ModelDownloadError)

        /// The model being switched TO, carried by every case.
        var target: ParakeetModelID {
            switch self {
            case .downloading(let target, _, _, _),
                 .retrying(let target, _, _, _, _),
                 .failed(let target, _, _, _): return target
            }
        }

        /// The live model the user keeps dictating with meanwhile.
        var from: ParakeetModelID {
            switch self {
            case .downloading(_, let from, _, _),
                 .retrying(_, let from, _, _, _),
                 .failed(_, let from, _, _): return from
            }
        }

        /// The deferred language (Settings language switch), if any.
        var language: LanguageChoice? {
            switch self {
            case .downloading(_, _, let language, _),
                 .retrying(_, _, let language, _, _),
                 .failed(_, _, let language, _): return language
            }
        }

        /// The classified failure reason for the `.retrying` / `.failed` cases;
        /// `nil` while actively downloading.
        var error: ModelDownloadError? {
            switch self {
            case .downloading: return nil
            case .retrying(_, _, _, let error, _),
                 .failed(_, _, _, let error): return error
            }
        }
    }

    @Published private(set) var pendingSwitch: PendingSwitch?

    /// Monotonic token so a later manual switch supersedes an in-flight one:
    /// every `beginPendingSwitch` / `cancelPendingSwitch` bumps this, and the
    /// download Task's success/failure block is a no-op when its captured
    /// generation is stale. The superseded download still runs to completion in
    /// `DownloadCoordinator` (its bytes are cached for later); we simply stop
    /// acting on its result.
    private var switchGeneration = 0

    /// The running download-then-flip (and auto-retry) loop for the current
    /// pending switch. Held so `cancelPendingSwitch` / a superseding switch can
    /// cancel its in-flight download and (crucially) its backoff sleep. `nil`
    /// when no switch is in flight.
    private var switchTask: Task<Void, Never>?

    /// Re-entrancy guard for the cross-launch intent re-arm's async
    /// "already-cached, flip now" branch, where `pendingSwitch` stays `nil`
    /// across the await and so can't gate a second re-arm on its own.
    private var intentRearmInFlight = false

    /// Speed/ETA meter for the current switch download attempt. Held on the
    /// MainActor (not captured into the `@Sendable` progress closure — `SpeedMeter`
    /// isn't `Sendable`) so the closure captures only `[weak self]` and reads the
    /// meter back through `self` on its MainActor hop. Reset each attempt.
    private var switchMeter: SpeedMeter?

    /// The language a Settings language switch is downloading TO, so the picker
    /// can keep showing the user's choice while the model downloads instead of
    /// snapping back to the still-active language. Only `.downloading` drives
    /// this — a `.failed` switch leaves the picker honestly on the old language.
    var pendingLanguage: LanguageChoice? {
        switch pendingSwitch {
        case .downloading(_, _, let language, _),
             .retrying(_, _, let language, _, _):
            // Both "in flight" states keep the picker on the user's chosen
            // language; only a terminal `.failed` lets it snap back honestly.
            return language
        default:
            return nil
        }
    }

    private let cache: ModelCache
    private let defaults: UserDefaults
    /// Factory takes both the model id AND the active language so the
    /// constructed `Transcriber` can thread the FluidAudio hint through
    /// (design §5.4). Production's factory passes the language into
    /// `Transcriber(modelID:language:)`.
    private let transcriberFactory: (ParakeetModelID, LanguageChoice) -> any Transcribing
    /// Factory for the model fetcher (design Phase 2). Default is the real
    /// `ModelDownloader(cache:)`; tests inject a no-op `ModelDownloading` so
    /// the self-heal path can be exercised without a real HuggingFace fetch.
    /// Mirrors `transcriberFactory`'s injection style.
    private let downloaderFactory: @MainActor (ModelCache) -> any ModelDownloading
    private var migrationDownloadStarted = false
    private var nemotronUpgradeStarted = false
    private var nemotronMultilingualUpgradeStarted = false

    static let defaultsKey = "jot.defaultModelID"

    /// New additive key (design §6.3): the raw `LanguageChoice`. Read at boot
    /// to seed `activeLanguage`; written by `setLanguage(_:)` and by the
    /// one-shot language migration. `jot.defaultModelID` remains the model
    /// source of truth.
    static let languageKey = "jot.transcriptionLanguage"

    /// Persisted **intent** for a manual model/language switch whose download
    /// hasn't finished (design: download-retry §4). Written when a background
    /// download-then-flip starts, cleared only on success or an explicit cancel
    /// — NOT on failure — so "the user asked for this model" survives a relaunch
    /// and Jot resumes the download when the network returns. Stored under
    /// domain `com.jot.Jot`.
    static let pendingIntentKey = "jot.pendingModelDownloadIntent"

    init(
        cache: ModelCache = .shared,
        defaults: UserDefaults = .standard,
        transcriberFactory: @escaping (ParakeetModelID, LanguageChoice) -> any Transcribing
            = { Transcriber(modelID: $0, language: $1) },
        downloaderFactory: @escaping @MainActor (ModelCache) -> any ModelDownloading
            = { ModelDownloader(cache: $0) },
        installedModelIDs: Set<ParakeetModelID>? = nil
    ) {
        self.cache = cache
        self.defaults = defaults
        self.transcriberFactory = transcriberFactory
        self.downloaderFactory = downloaderFactory

        let stored = defaults.string(forKey: Self.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))
            ?? .tdt_0_6b_v3_eou_streaming
        // Seed the active language from its own key when present; otherwise
        // derive it from the stored model (covers users who upgraded before
        // the one-shot migration ran, and keeps boot resilient if the key is
        // ever absent). The migration in `LanguageMigration` is the canonical
        // writer; this is a safe fallback, not a substitute for it.
        let language = defaults.string(forKey: Self.languageKey)
            .flatMap(LanguageChoice.init(rawValue:))
            ?? LanguageChoice.fromStoredModelID(stored)
        self.primaryModelID = stored
        self.activeLanguage = language
        self.transcriber = transcriberFactory(stored, language)
        // Phase 4 hermetic-harness fix: callers (the harness) can seed
        // an explicit installed-set so tests don't read the dev
        // machine's `~/Library/Application Support/Jot/Models/...`
        // cache. Production omits the arg and gets a real disk scan.
        self.installedModelIDs = installedModelIDs ?? Self.scan(cache: cache)

        // Self-heal Fix-b: clear a stale `.failed` repair when the ACTIVE model
        // becomes healthy via ANY successful download — even one this holder
        // didn't initiate (a racing fetch, a migration/upgrade download). The
        // coordinator fires this off-actor, so hop to the main actor. The
        // `@Sendable` observer captures its own independent `[weak self]`
        // (built outside the registration `Task`) to dodge Swift 6's
        // "reference to captured var 'self' in concurrently-executing code"
        // diagnostic — the same idiom as the `progressBinding` closures below.
        let coordinator = DownloadCoordinator.shared
        let onDownloadSuccess: @Sendable (ParakeetModelID) -> Void = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                if id == self.activeModelID, self.repairState != nil {
                    self.repairState = nil
                }
            }
        }
        Task {
            await coordinator.addSuccessObserver(onDownloadSuccess)
        }

        // Cross-launch resume (design: download-retry §4): if a prior session
        // asked to switch to a model whose download never finished, pick the
        // background download-then-flip back up now. Deferred behind migration
        // markers and re-tried from `refreshInstalled` when they retire.
        rearmPendingDownloadIntentIfNeeded()
    }

    /// The model that should actually be loaded/used: the explicit stored
    /// choice always wins over the language's resolved default (design §5.4.1).
    /// In steady state `primaryModelID` already IS this value; the helper makes
    /// the precedence explicit and is the single readable expression of the
    /// no-surprise-download invariant.
    var activeModelID: ParakeetModelID {
        primaryModelID
    }

    /// Swap to a different primary model. No-op when `id == primaryModelID`.
    /// Persists the new id to `UserDefaults` under the legacy
    /// `jot.defaultModelID` key so existing users' selection survives.
    /// `try? await ensureLoaded()` is best-effort — failures surface to the
    /// next `transcribe(_:)` call, which already handles the not-loaded case.
    func setPrimary(_ id: ParakeetModelID) async {
        guard id != primaryModelID else { return }
        let new = transcriberFactory(id, activeLanguage)
        primaryModelID = id
        transcriber = new
        defaults.set(id.rawValue, forKey: Self.defaultsKey)
        try? await new.ensureLoaded()
    }

    /// Switch the active transcription **language** (design §5.4), flipping the
    /// model **immediately** even if it must download. This is the write path
    /// behind the **Setup Wizard** `LanguageStep`, which drives its own in-step
    /// download UI + an advance gate keyed on `primaryModelID` and so relies on
    /// the immediate flip. The **Settings** language picker instead routes
    /// through `requestLanguageSwitch(_:)`, which keeps the current model live
    /// and download-then-flips; it delegates the no-download cases back here.
    ///
    /// It persists `jot.transcriptionLanguage` and resolves the language to a
    /// model, but with a **no-clobber guard** so re-confirming a language that
    /// the stored English-only model already serves never swaps the model or
    /// triggers a download (design §5.4.1):
    ///
    /// - A user stored on Nemotron or v2 (both English-only) who (re-)picks
    ///   English keeps their stored model untouched — v2 *is* the English
    ///   default (re-pick is a no-op) and Nemotron is grandfathered (no
    ///   downgrade to v3). The guard is **hardware-blind on purpose**: a
    ///   Nemotron user on a now-unqualifying Mac stays on Nemotron.
    /// - Otherwise the language drives the model via `setPrimary`, which
    ///   persists `jot.defaultModelID` and downloads/loads if missing — the
    ///   common, user-initiated case.
    func setLanguage(_ lang: LanguageChoice) async {
        defaults.set(lang.rawValue, forKey: Self.languageKey)
        let resolved = lang.modelID()

        // No-clobber rule for English-only stored models (Nemotron / v2).
        if lang.baseLanguage == .english,
           primaryModelID == .nemotron_en || primaryModelID == .tdt_0_6b_v2_en_streaming {
            // Language metadata updates; MODEL is untouched. We still rebuild
            // the transcriber so the (English → nil) hint is reflected, but
            // the model id and the stored `jot.defaultModelID` are unchanged,
            // so there is no download.
            activeLanguage = lang
            transcriber = transcriberFactory(primaryModelID, lang)
            try? await transcriber.ensureLoaded()
            return
        }

        // Common case: the language drives the model.
        activeLanguage = lang
        if resolved == primaryModelID {
            // Same model, new hint — rebuild the transcriber so the hint is
            // threaded, without re-persisting/re-downloading the model.
            transcriber = transcriberFactory(primaryModelID, lang)
            try? await transcriber.ensureLoaded()
            return
        }
        await setPrimary(resolved)
    }

    // MARK: - Manual switch (download-then-flip)

    /// Single choke point for a **manual model switch** (menu bar "Switch
    /// model"). Closes the gap where picking a not-yet-downloaded model flipped
    /// `primaryModelID` immediately and stranded the user on a broken
    /// transcriber for the length of a multi-hundred-MB download:
    ///
    /// - Target already installed → flip immediately via `setPrimary` (the
    ///   original behavior; every menu row is an installed model today).
    /// - Target not installed → KEEP the current model live and download in the
    ///   background (`beginPendingSwitch`), flipping only when the bytes land.
    ///
    /// No language change on this path — the active language is preserved.
    /// Re-selecting the current primary cancels any in-flight pending switch.
    func requestSwitch(to id: ParakeetModelID) async {
        guard id != primaryModelID else { cancelPendingSwitch(); return }
        if cache.isCached(id) {
            cancelPendingSwitch()
            await setPrimary(id)
            return
        }
        beginPendingSwitch(to: id, language: nil)
    }

    /// Single choke point for a **Settings language switch** (General pane
    /// picker). The Settings equivalent of `requestSwitch(to:)`: it resolves
    /// exactly like `setLanguage` for the no-download cases (no-clobber English,
    /// same-model hint rebuild, already-installed target — all delegated so the
    /// guard logic keeps one owner), but when the resolved model isn't on disk
    /// it does NOT flip. It keeps the current model + language live and
    /// downloads in the background, applying the new language only when the
    /// bytes land.
    ///
    /// The Setup Wizard's `LanguageStep` deliberately keeps calling
    /// `setLanguage` directly, not this: it drives its own in-step download UI
    /// and an advance gate keyed on `primaryModelID`, both of which rely on
    /// `setLanguage`'s immediate flip.
    func requestLanguageSwitch(_ lang: LanguageChoice) async {
        let resolved = lang.modelID()
        let needsDownload = Self.languageSwitchNeedsDownload(
            lang: lang,
            resolved: resolved,
            primary: primaryModelID,
            isResolvedInstalled: cache.isCached(resolved))

        // No-download cases resolve identically to `setLanguage` — delegate so
        // the no-clobber guard + hint-rebuild logic isn't duplicated.
        guard needsDownload else {
            cancelPendingSwitch()
            await setLanguage(lang)
            return
        }

        // Target model not installed: download-then-flip, applying the language
        // only on success so the current (working) model + hint stay live.
        beginPendingSwitch(to: resolved, language: lang)
    }

    /// Pure routing predicate for a Settings language switch: does the resolved
    /// model need a download-then-flip, or can it flip immediately? Extracted
    /// static so the decision — the exact thing that was flipping too early —
    /// is unit-testable without the cache/async machinery. Mirrors the
    /// no-download cases `setLanguage` already handles:
    /// - English re-picked on an English-only stored model (Nemotron / v2):
    ///   no-clobber, model untouched → no download.
    /// - The resolved model already IS the primary → hint rebuild only.
    /// - The resolved model is installed → immediate flip.
    /// Otherwise (resolved differs AND isn't on disk) → download-then-flip.
    nonisolated static func languageSwitchNeedsDownload(
        lang: LanguageChoice,
        resolved: ParakeetModelID,
        primary: ParakeetModelID,
        isResolvedInstalled: Bool
    ) -> Bool {
        if lang.baseLanguage == .english,
           primary == .nemotron_en || primary == .tdt_0_6b_v2_en_streaming {
            return false
        }
        if resolved == primary { return false }
        return !isResolvedInstalled
    }

    /// Abandon any in-flight pending switch: bump the generation so its
    /// download Task's success/failure block no-ops when it lands, cancel the
    /// loop (including any backoff sleep), clear the persisted intent (explicit
    /// user cancel), and clear the banner. The underlying `DownloadCoordinator`
    /// task keeps running (its bytes are cached for a later switch); we just
    /// stop caring about it. No model files are removed.
    func cancelPendingSwitch() {
        switchGeneration &+= 1
        switchTask?.cancel()
        switchTask = nil
        switchMeter = nil
        clearPendingIntent()
        pendingSwitch = nil
    }

    /// Re-attempt the current pending switch **immediately**, skipping any
    /// remaining backoff wait. Drives the UI "Retry" / "Retry now" affordance on
    /// the `.retrying` and `.failed` banners. A bare `.downloading` switch is
    /// already in flight, so this is a no-op there.
    func retryPendingSwitch() {
        guard let pending = pendingSwitch else { return }
        switch pending {
        case .downloading:
            return
        case .retrying(let target, _, let language, _, _),
             .failed(let target, _, let language, _):
            // Restart the loop from a fresh attempt (backoff resets). This
            // cancels the sleeping retry loop via the generation bump + task
            // cancel inside `beginPendingSwitch`, so no duplicate loop runs.
            beginPendingSwitch(to: target, language: language)
        }
    }

    /// Human-readable name for a model — used by switch banners for the
    /// "keep dictating in <from>" / target labels. Thin passthrough to the
    /// model's own `displayName` so callers don't need to import the enum's
    /// naming surface.
    static func displayName(for id: ParakeetModelID) -> String {
        id.displayName
    }

    /// Backoff schedule for auto-retry of a retriable download failure:
    /// 30 → 60 → 120 → 240 → capped at 300 seconds. `attempt` is 1-based.
    static func retryDelay(attempt: Int) -> TimeInterval {
        let base = 30.0 * pow(2.0, Double(max(0, attempt - 1)))
        return min(300.0, base)
    }

    /// Shared download-then-flip core for `requestSwitch` / `requestLanguage-
    /// Switch` / cross-launch resume. Keeps `primaryModelID` / `activeLanguage`
    /// untouched until the target bundle is fully on disk, then flips — the same
    /// "no window where the active model is uninstalled" invariant the migration
    /// paths hold (§:312-317). `language` non-nil also applies the deferred
    /// language on success so the FluidAudio hint matches the new model.
    ///
    /// Retriable failures (host outage / transient corrupt fetch) do NOT dead-end
    /// to `.failed`: the loop publishes `.retrying` and re-attempts with backoff
    /// while the user keeps dictating on the current model — the current model is
    /// never uninstalled or altered. Non-retriable failures (offline / disk full)
    /// land in `.failed`; the persisted intent survives either way so a relaunch
    /// resumes. The whole loop respects `switchGeneration` supersession and is
    /// cancellable via `cancelPendingSwitch`.
    private func beginPendingSwitch(to id: ParakeetModelID, language: LanguageChoice?) {
        switchGeneration &+= 1
        let generation = switchGeneration
        let from = primaryModelID
        // Persist intent so a relaunch resumes this switch (cleared on success /
        // explicit cancel only). Written before the first byte so an immediate
        // crash still leaves the intent recorded.
        persistPendingIntent(model: id, language: language)
        pendingSwitch = .downloading(target: id, from: from, language: language, progress: nil)

        switchTask?.cancel()
        switchTask = Task { @MainActor [weak self] in
            await self?.runPendingSwitchLoop(
                id: id, from: from, language: language, generation: generation)
        }
    }

    /// The download-then-flip + auto-retry loop. Runs on the MainActor; each
    /// iteration is one full download attempt (byte-level resume is out of
    /// scope). Exits on success, a non-retriable failure, cancellation, or
    /// supersession by a newer switch.
    private func runPendingSwitchLoop(
        id: ParakeetModelID,
        from: ParakeetModelID,
        language: LanguageChoice?,
        generation: Int
    ) async {
        var attempt = 0
        while true {
            guard switchGeneration == generation, !Task.isCancelled else { return }

            // Fresh speed meter per attempt (a retry re-downloads from the
            // start, so byte/ETA accounting restarts too). Held on `self`, not
            // captured into the `@Sendable` closure below.
            switchMeter = SpeedMeter(bytesTotal: id.approxBytes)
            pendingSwitch = .downloading(target: id, from: from, language: language, progress: nil)

            let downloader = downloaderFactory(cache)
            // @Sendable progress closure with its own independent `[weak self]`,
            // matching the migration paths' Swift 6 idiom. The generation guard
            // drops progress from a superseded switch; the meter is read back
            // through `self` (it isn't `Sendable`, so it can't be captured).
            let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.switchGeneration == generation,
                          let progress = self.switchMeter?.record(fraction: fraction) else { return }
                    self.pendingSwitch = .downloading(
                        target: id, from: from, language: language, progress: progress)
                }
            }

            do {
                try await downloader.downloadIfMissing(id, progress: progressBinding)
                guard switchGeneration == generation, !Task.isCancelled else { return }
                // Retire the meter so a late progress straggler can't clobber the
                // terminal state below back to `.downloading`.
                switchMeter = nil

                // PREPARING: bytes have landed; CoreML compile / model load can
                // take seconds. Publish the indeterminate `.preparing` sentinel
                // so the UI shows "Preparing…" instead of dead-air at 100%.
                pendingSwitch = .downloading(
                    target: id, from: from, language: language,
                    progress: .preparing(bytesTotal: id.approxBytes))

                // Apply the deferred language first (if any) so `setPrimary`
                // rebuilds the transcriber with the matching hint, mirroring
                // `setLanguage`'s installed-model path.
                if let language {
                    defaults.set(language.rawValue, forKey: Self.languageKey)
                    activeLanguage = language
                }
                await setPrimary(id)
                guard switchGeneration == generation else { return }

                // SUCCESS: the model is now primary. Clear intent + banner.
                clearPendingIntent()
                pendingSwitch = nil
                switchTask = nil
                refreshInstalled()
                return
            } catch {
                guard switchGeneration == generation, !Task.isCancelled else { return }
                // Retire the meter (see success path) before publishing the
                // retry/failed banner so no straggler resurrects `.downloading`.
                switchMeter = nil
                let classified = ModelDownloadError.classify(error)
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Manual model switch download failed",
                    context: [
                        "modelID": id.rawValue,
                        "reason": classified.logTag,
                        "error": ErrorLog.redactedAppleError(error),
                    ]
                )

                guard classified.isRetriable else {
                    // Non-retriable (offline / disk full / unclassified): stay on
                    // the old model. Intent survives so a relaunch or "Retry"
                    // resumes; no automatic backoff loop for these.
                    pendingSwitch = .failed(
                        target: id, from: from, language: language, error: classified)
                    switchTask = nil
                    refreshInstalled()
                    return
                }

                // Retriable: keep the current (working) model live and auto-retry
                // with backoff. The current model is never uninstalled or altered.
                attempt += 1
                let delay = Self.retryDelay(attempt: attempt)
                pendingSwitch = .retrying(
                    target: id, from: from, language: language,
                    error: classified, nextRetryAt: Date().addingTimeInterval(delay))

                // Interruptible backoff: a supersede / cancel / "Retry now"
                // cancels this Task, waking the sleep; the top-of-loop guard then
                // returns (for supersede/cancel) or a fresh loop takes over.
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Loop for the next automatic attempt.
            }
        }
    }

    // MARK: - Persisted switch intent (cross-launch resume)

    /// Codable payload for `pendingIntentKey` — the desired model plus the
    /// optional deferred language, both stored as their stable raw values.
    private struct PendingDownloadIntent: Codable, Equatable {
        let model: String
        let language: String?
    }

    private func persistPendingIntent(model: ParakeetModelID, language: LanguageChoice?) {
        let intent = PendingDownloadIntent(model: model.rawValue, language: language?.rawValue)
        if let data = try? JSONEncoder().encode(intent) {
            defaults.set(data, forKey: Self.pendingIntentKey)
        }
    }

    private func clearPendingIntent() {
        defaults.removeObject(forKey: Self.pendingIntentKey)
    }

    private func loadPendingIntent() -> PendingDownloadIntent? {
        guard let data = defaults.data(forKey: Self.pendingIntentKey) else { return nil }
        return try? JSONDecoder().decode(PendingDownloadIntent.self, from: data)
    }

    /// Resume a manual switch persisted by a prior session (or reactivated when
    /// the network returns): if the intent's model still isn't the primary,
    /// flip to it now (if its bytes are already on disk) or restart the
    /// background download-then-flip. Never blocks dictation and never removes an
    /// installed engine. Safe to call repeatedly — guarded on `pendingSwitch`
    /// (a live switch already owns the intent) and the migration markers (defer
    /// while a migration/self-heal download owns the shared machinery).
    func rearmPendingDownloadIntentIfNeeded() {
        guard pendingSwitch == nil, !intentRearmInFlight else { return }
        guard let intent = loadPendingIntent() else { return }
        guard let model = ParakeetModelID(rawValue: intent.model) else {
            // Corrupt / stale payload — retire it.
            clearPendingIntent()
            return
        }
        let language = intent.language.flatMap(LanguageChoice.init(rawValue:))

        // Already satisfied (the intent model is live) → retire the intent.
        if model == primaryModelID {
            clearPendingIntent()
            return
        }

        // Defer while a migration / self-heal download is pending, mirroring the
        // launch arbitration those paths use. `refreshInstalled` re-runs this
        // once the markers retire.
        guard !defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey),
              !defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey),
              !defaults.bool(forKey: QwenRetirementMigration.multilingualUpgradePendingKey) else {
            return
        }

        if cache.isCached(model) {
            // Bytes already on disk (an earlier/racing fetch landed them):
            // complete the deferred flip now — no re-download, no banner flash.
            intentRearmInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let language {
                    self.defaults.set(language.rawValue, forKey: Self.languageKey)
                    self.activeLanguage = language
                }
                await self.setPrimary(model)
                self.clearPendingIntent()
                self.intentRearmInFlight = false
                self.refreshInstalled()
            }
            return
        }

        // Still missing → resume the background download-then-flip (which
        // re-persists the same intent and clears it on success).
        beginPendingSwitch(to: model, language: language)
    }

    /// Re-scan the model cache directory and update `installedModelIDs`.
    /// Call after a download or removal so the Settings/Wizard "Downloaded"
    /// indicator reflects the disk state.
    func refreshInstalled() {
        installedModelIDs = Self.scan(cache: cache)
        // A model appearing on disk (or a migration retiring its marker) is
        // exactly the "things have settled / the network came back" moment to
        // resume a persisted deferred switch. Guarded internally so an in-flight
        // switch or a cleared intent makes this a no-op — and so the re-arm's own
        // success path (which calls `refreshInstalled`) can't recurse.
        rearmPendingDownloadIntentIfNeeded()
    }

    /// Consumes the post-migration one-shot download marker and downloads the
    /// selected model with progress that the main window can render as a
    /// banner. Failure clears the marker so the app does not retry on every
    /// launch; Settings and the Setup Wizard remain the manual retry paths.
    func startPendingMigrationDownloadIfNeeded() {
        guard !migrationDownloadStarted else { return }
        guard defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) else {
            return
        }

        migrationDownloadStarted = true
        migrationDownloadError = nil

        if cache.isCached(primaryModelID) {
            defaults.set(false, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
            migrationDownloadProgress = nil
            refreshInstalled()
            return
        }

        migrationDownloadProgress = 0
        let modelID = primaryModelID
        let cache = self.cache
        // Capture the @Sendable progress closure outside the outer Task so its
        // own `[weak self]` is independent of the surrounding closure's var-self.
        // The previous nested `Task { @MainActor [weak self] in ... }` tripped
        // Swift 6's "reference to captured var 'self' in concurrently-executing
        // code" diagnostic — the inner `[weak self]` was capturing the outer
        // optional `self` var rather than a fresh weak reference.
        let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.migrationDownloadProgress = fraction
            }
        }
        Task { @MainActor [weak self] in
            let downloader = ModelDownloader(cache: cache)
            do {
                try await downloader.downloadIfMissing(modelID, progress: progressBinding)
                guard let self else { return }
                self.defaults.set(false, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = nil
                self.refreshInstalled()
                try? await self.transcriber.ensureLoaded()
            } catch {
                guard let self else { return }
                self.defaults.set(false, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = error.localizedDescription
                self.refreshInstalled()
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Post-migration model download failed",
                    context: ["modelID": modelID.rawValue, "error": ErrorLog.redactedAppleError(error)]
                )
            }
        }
    }

    /// Consumes the one-shot Nemotron auto-upgrade pending marker
    /// (`NemotronAutoUpgradeMigration.autoUpgradePendingKey`) and performs a
    /// **download-first-then-flip** upgrade for existing English users on
    /// high-RAM Macs.
    ///
    /// The invariant: the user keeps dictating on their **current** model the
    /// entire time Nemotron downloads. `primaryModelID` is NOT changed until
    /// the `.nemotron_en` bundle is fully on disk — `setPrimary(.nemotron_en)`
    /// runs only inside the download `do` block's success path, so there is no
    /// window where the active model is uninstalled.
    ///
    /// Reuses the existing `migrationDownloadProgress` / `migrationDownloadError`
    /// `@Published` fields so the same `migrationDownloadBanner` in
    /// `JotAppWindow` renders for this path with no extra UI wiring.
    ///
    /// On **failure** the pending marker is left set (unlike
    /// `startPendingMigrationDownloadIfNeeded`, which clears it): there is no
    /// manual Nemotron picker on the auto-upgrade path, so a failed download
    /// must be retried on the next launch. `nemotronUpgradeStarted` still
    /// guards against a second attempt *within the same launch*.
    func startPendingNemotronUpgradeIfNeeded() {
        guard !nemotronUpgradeStarted else { return }
        guard defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) else {
            return
        }

        // Defer one launch if the four-option post-migration download is still
        // pending. Both paths reuse the shared `migrationDownloadProgress` /
        // `migrationDownloadError` banner state, so running them in the same
        // launch corrupts the banner (progress flip-flop, one clears the
        // other). The pending marker persists, so the upgrade simply proceeds
        // on the next launch once the four-option download has retired its
        // own marker.
        guard !defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) else {
            return
        }

        nemotronUpgradeStarted = true
        migrationDownloadError = nil

        // Already on Nemotron (e.g. the user manually switched after the
        // marker was set): nothing to do, retire the marker.
        if primaryModelID == .nemotron_en {
            defaults.set(false, forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey)
            migrationDownloadProgress = nil
            return
        }

        // Already cached on disk: flip immediately (still download-first in
        // spirit — the bytes are present, so the active model never points at
        // an uninstalled bundle).
        if cache.isCached(.nemotron_en) {
            migrationDownloadProgress = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setPrimary(.nemotron_en)
                self.defaults.set(false, forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey)
                self.refreshInstalled()
            }
            return
        }

        migrationDownloadProgress = 0
        let cache = self.cache
        // @Sendable progress closure with its own independent `[weak self]`,
        // matching `startPendingMigrationDownloadIfNeeded`'s Swift 6 idiom.
        let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.migrationDownloadProgress = fraction
            }
        }
        Task { @MainActor [weak self] in
            let downloader = ModelDownloader(cache: cache)
            do {
                try await downloader.downloadIfMissing(.nemotron_en, progress: progressBinding)
                guard let self else { return }
                // SUCCESS: only now flip the active model. `setPrimary`
                // persists `jot.defaultModelID` and loads the new model.
                await self.setPrimary(.nemotron_en)
                self.defaults.set(false, forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey)
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = nil
                self.refreshInstalled()
            } catch {
                guard let self else { return }
                // FAILURE: leave the pending marker set so the next launch
                // retries (there is no manual picker on this path). The
                // current model stays active — dictation is unaffected.
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = error.localizedDescription
                self.refreshInstalled()
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Nemotron auto-upgrade download failed",
                    context: ["modelID": ParakeetModelID.nemotron_en.rawValue, "error": ErrorLog.redactedAppleError(error)]
                )
            }
        }
    }

    /// Download-then-flip for a surviving-Qwen user (≥24 GB) being migrated to
    /// Nemotron Multilingual. Mirrors `startPendingNemotronUpgradeIfNeeded`, but
    /// the download is language-aware (`latin` vs `multilingual` ship) and on
    /// success it also clears the cross-language English fallback marker. The
    /// active (dead Qwen) model never blocks dictation meanwhile —
    /// `resolveSessionTranscriber` routes the session to English while
    /// `crossLanguageFallbackKey` is set.
    func startPendingNemotronMultilingualUpgradeIfNeeded() {
        guard !nemotronMultilingualUpgradeStarted else { return }
        guard defaults.bool(forKey: QwenRetirementMigration.multilingualUpgradePendingKey) else {
            return
        }
        // Defer one launch if ANOTHER migration download is pending — they
        // share the `migrationDownloadProgress` / `migrationDownloadError`
        // banner, so they must not run concurrently. (Do NOT include this
        // path's own `multilingualUpgradePendingKey` — it's necessarily set
        // here, so guarding on it would make this function dead code.)
        guard !defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey),
              !defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) else {
            return
        }

        nemotronMultilingualUpgradeStarted = true
        migrationDownloadError = nil

        // The active language resolves to a specific ship (latin vs full
        // multilingual). If it no longer routes to a multilingual ship (e.g.
        // hardware changed / fell back), there's nothing to upgrade — retire
        // the markers.
        let targetID = activeLanguage.modelID()
        guard targetID == .nemotron_multilingual || targetID == .nemotron_multilingual_latin else {
            clearMultilingualUpgradeMarkers()
            migrationDownloadProgress = nil
            return
        }

        // Already cached (or already flipped): flip + retire the markers now.
        if cache.isCached(targetID) {
            migrationDownloadProgress = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setPrimary(targetID)
                self.clearMultilingualUpgradeMarkers()
                self.refreshInstalled()
            }
            return
        }

        migrationDownloadProgress = 0
        let cache = self.cache
        let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.migrationDownloadProgress = fraction
            }
        }
        Task { @MainActor [weak self] in
            let downloader = ModelDownloader(cache: cache)
            do {
                try await downloader.downloadNemotronMultilingual(targetID, progress: progressBinding)
                guard let self else { return }
                // SUCCESS: only now flip the active model + drop the dead-Qwen
                // cross-language fallback.
                await self.setPrimary(targetID)
                self.clearMultilingualUpgradeMarkers()
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = nil
                self.refreshInstalled()
            } catch {
                guard let self else { return }
                // FAILURE: leave both markers set so the next launch retries and
                // the session keeps falling back to English. Dictation unaffected.
                self.migrationDownloadProgress = nil
                self.migrationDownloadError = error.localizedDescription
                self.refreshInstalled()
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Nemotron multilingual upgrade download failed",
                    context: ["model": targetID.rawValue, "error": ErrorLog.redactedAppleError(error)]
                )
            }
        }
    }

    private func clearMultilingualUpgradeMarkers() {
        defaults.set(false, forKey: QwenRetirementMigration.multilingualUpgradePendingKey)
        defaults.set(false, forKey: QwenRetirementMigration.crossLanguageFallbackKey)
    }

    // MARK: - Startup model-integrity self-heal (design §Phase 1–2, 5)

    /// Strict per-side integrity probe of the ACTIVE model on the single live
    /// `transcriber` instance (review G1 — this IS the launch load, replacing
    /// `prewarmTranscriber`'s discarded fire-and-forget). Returns the set of
    /// sides whose strict load FAILED, plus whether the probe found everything
    /// healthy.
    ///
    /// For a `DualPipelineTranscriber` we call `probeIntegrity()` (review B1:
    /// loads both sides WITHOUT the error-swallowing quiet path). For a bare
    /// `Transcriber` (v3 / int4 / JA — no streaming side) we probe the single
    /// side via `ensureLoaded()` and report it as `.batch`.
    func probeActiveModelOnLaunch() async -> (allHealthy: Bool, failedSides: Set<ModelSide>) {
        var failed: Set<ModelSide> = []

        if let dual = transcriber as? DualPipelineTranscriber {
            let result = await dual.probeIntegrity()
            if case .failure = result.batch { failed.insert(.batch) }
            if case .failure = result.streaming { failed.insert(.streaming) }
        } else {
            // Bare Transcriber: single-side passthrough.
            do {
                try await transcriber.ensureLoaded()
            } catch {
                failed.insert(.batch)
            }
        }

        return (allHealthy: failed.isEmpty, failedSides: failed)
    }

    /// The active model loaded cleanly — nothing to do. Kept as an explicit
    /// call site (rather than an implicit no-op) so the launch hook reads as a
    /// two-armed decision and a future "last verified" marker has a home.
    func markActiveModelHealthy() {
        // No state to clear: `repairState` is only ever set by `beginSelfHeal`.
    }

    /// Proven-healthy signal (self-heal Fix-a): a successful transcription on
    /// the ACTIVE model proves it loaded fine, so any lingering `repairState`
    /// (including a stale `.failed` from an earlier self-heal that has since
    /// been resolved by some other download path, or a transient probe
    /// failure) must be cleared. Without this, `PillViewModel.reassertRepair-
    /// IfNeeded` would re-show the failure pill after every recording stop
    /// until the user manually retried or restarted the app.
    ///
    /// Idempotent and cheap — a no-op when nothing is in flight. Only call this
    /// when the transcript came from the active model (NOT the Phase-5 transient
    /// fallback), since a fallback success says nothing about the active model.
    func noteActiveModelHealthy() {
        if repairState != nil {
            repairState = nil
        }
    }

    /// Heal the active model after a failed launch probe (design §Phase 2,
    /// reviews M4 + M5 + m7). Surgically purges ONLY a side that is
    /// present-but-load-failed (corrupt), leaves a merely-missing side for
    /// `downloadIfMissing` to fetch, verifies the purge actually removed the
    /// bad files, then re-downloads and reloads. Routes the user to Settings →
    /// Transcription as the primary recovery surface; the persistent pill is
    /// the backup.
    func beginSelfHeal(failedSides: Set<ModelSide>) async {
        guard !selfHealStarted else { return }
        selfHealStarted = true
        guard !failedSides.isEmpty else { return }

        // Respect the existing launch arbitration (review G5 + Phase 4): if a
        // four-option or nemotron-upgrade download is pending this launch,
        // DEFER self-heal to the next launch — don't run a 3rd concurrent
        // download. The probe re-runs next launch; the heal then proceeds once
        // those markers have retired.
        guard !defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey),
              !defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey),
              !defaults.bool(forKey: QwenRetirementMigration.multilingualUpgradePendingKey) else {
            return
        }

        let modelID = activeModelID
        let modelName = modelID.displayName

        for side in failedSides {
            // Disambiguate corrupt vs transient (review m7): only purge a side
            // that is present-but-load-failed. A merely-missing side skips the
            // purge — `downloadIfMissing` will fetch it. A side whose files
            // look intact but failed to load could be a transient CoreML/ANE
            // hiccup; we only purge when the file is genuinely on disk AND the
            // strict load failed, which is the corruption signal.
            guard cache.stillPresent(modelID, side: side) else { continue }

            cache.removeCache(
                for: modelID,
                removeBatch: side == .batch,
                removeStreaming: side == .streaming
            )

            // M5: removeCache swallows errors. If the bad files survive,
            // `downloadIfMissing` would no-op (it guards on isCached) and the
            // once-flag would strand the user in "repairing" forever. Verify
            // and bail to `.failed` + route instead.
            if cache.stillPresent(modelID, side: side) {
                repairState = .failed(modelName: modelName, reason: .cannotPurge)
                routeToSettings?()
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Self-heal could not purge corrupt model side",
                    context: ["modelID": modelID.rawValue, "side": "\(side)"]
                )
                return
            }
        }

        repairState = .downloading(modelName: modelName, progress: nil)
        // Primary recovery surface (user-decided): bring the user to Settings →
        // Transcription so they see the download progress in context. The
        // persistent pill is the backup for hotkey-only / window-dismissed use.
        routeToSettings?()

        // Build the fetcher via the injected factory (default: real
        // `ModelDownloader`; tests: a no-op `ModelDownloading`) so the
        // self-heal path is unit-testable without a real HuggingFace fetch.
        let downloader = downloaderFactory(cache)
        // @Sendable progress closure with its own independent `[weak self]`,
        // matching `startPendingNemotronUpgradeIfNeeded`'s Swift 6 idiom.
        let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.repairState = .downloading(modelName: modelName, progress: fraction)
            }
        }
        Task { @MainActor [weak self] in
            do {
                try await downloader.downloadIfMissing(modelID, progress: progressBinding)
                guard let self else { return }
                try? await self.transcriber.ensureLoaded()
                self.repairState = nil
                self.refreshInstalled()
            } catch {
                guard let self else { return }
                // Marker discipline: `selfHealStarted` is per-launch, so a
                // failed heal naturally retries on the next launch's probe.
                self.repairState = .failed(modelName: modelName, reason: .download)
                self.routeToSettings?()
                self.refreshInstalled()
                await ErrorLog.shared.error(
                    component: "TranscriberHolder",
                    message: "Self-heal model re-download failed",
                    context: ["modelID": modelID.rawValue, "error": ErrorLog.redactedAppleError(error)]
                )
            }
        }
    }

    /// User-initiated retry of the ACTIVE model's download, driven through
    /// `repairState` so every repair surface (Settings row, persistent pill,
    /// window banner) stays consistent. Use this when the active model is the
    /// one being downloaded — e.g. the Settings → Transcription "Download" /
    /// "Retry" button after a self-heal landed `.failed`. Without this, a
    /// successful manual retry would leave the failure UI stuck (because the
    /// only `repairState = nil` clear lived in `beginSelfHeal`'s success path)
    /// and the in-flight retry would show no progress (the repair branch masks
    /// `rowState`).
    ///
    /// Unlike `beginSelfHeal` this is explicit user intent: no purge, no
    /// per-launch once-flag, no migration-pending deferral. It awaits so the
    /// caller (`TranscriptionPane.startDownload`) can surface a thrown error if
    /// it wants; `repairState` already carries success/failure for the UI.
    /// `DownloadCoordinator` still collapses this with any in-flight self-heal
    /// download of the same id, so they can't collide.
    func runManualRepair(_ id: ParakeetModelID) async {
        let modelName = id.displayName
        repairState = .downloading(modelName: modelName, progress: nil)

        // Corrupt-but-present escape hatch. `downloadIfMissing` short-circuits
        // on `isCached` (presence only), so against a bundle whose files are on
        // disk but won't LOAD, a plain retry is a hollow "already downloaded"
        // that re-fetches nothing and leaves the user stuck (the exact loop a
        // corrupt Nemotron produced). This is explicit user intent to repair,
        // so probe-load the active model first; if it's present yet unloadable,
        // purge it so the fetch below actually re-downloads a clean bundle.
        // Gated on `id == activeModelID` (this method's contract) because we can
        // only load-probe the active `transcriber`. A model that loads fine
        // makes this a no-op and the retry simply clears the stale failure UI.
        if id == activeModelID, cache.isCached(id) {
            let loaded = (try? await transcriber.ensureLoaded()) != nil
            let ready = await transcriber.isReady
            if !(loaded && ready) {
                cache.removeCache(for: id)
                // A normal recovery action, not an error — `.warn` so it doesn't
                // inflate error-count signals.
                await ErrorLog.shared.warn(
                    component: "TranscriberHolder",
                    message: "Manual repair force-purged present-but-unloadable model",
                    context: ["modelID": id.rawValue]
                )
            }
        }

        let downloader = downloaderFactory(cache)
        let progressBinding: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.repairState = .downloading(modelName: modelName, progress: fraction)
            }
        }
        do {
            try await downloader.downloadIfMissing(id, progress: progressBinding)
            // Propagate (not `try?`) so a re-download that STILL won't load
            // reports failure instead of falsely clearing the UI to "repaired".
            // The honest failure is self-correcting: a later successful
            // transcription clears `repairState` via `noteActiveModelHealthy`.
            try await transcriber.ensureLoaded()
            repairState = nil
            refreshInstalled()
        } catch {
            repairState = .failed(modelName: modelName, reason: .download)
            refreshInstalled()
            await ErrorLog.shared.error(
                component: "TranscriberHolder",
                message: "Manual model repair download failed",
                context: ["modelID": id.rawValue, "error": ErrorLog.redactedAppleError(error)]
            )
        }
    }

    // MARK: - Phase 5: transient fallback during repair ("never block")

    /// Resolve the transcriber to use for a recording session that is about to
    /// start (design §Phase 5, review m6 — resolved at recording START, never
    /// mid-session). Default path: the live active `transcriber`.
    ///
    /// During an in-flight repair where the active model isn't loadable, this
    /// returns a **transient** transcriber for another *installed + loadable*
    /// model **that serves the active language** so dictation never blocks. It
    /// NEVER calls `setPrimary` — that would persist `jot.defaultModelID` and
    /// silently change the user's saved model. The next recording after the
    /// heal completes naturally resolves back to the active model.
    ///
    /// The fallback is **language-gated** (otherwise a corrupt Japanese model
    /// would fall back to an English-only model fed Japanese audio → silent
    /// garbage). English active language uses the
    /// `[v2, nemotron_en, v3_eou, v3]` preference; a non-English European
    /// language restricts to multilingual models (`v3_eou`, `v3`); Japanese has
    /// no compatible alternate, so it blocks.
    ///
    /// Returns `.blocked` when no compatible alternate is installed/loadable AND
    /// the active model isn't ready during a repair — the caller then falls
    /// back to the persistent repairing pill (cannot record yet).
    enum SessionResolution {
        /// Use the live active `transcriber` (steady state, or the active model
        /// is loadable despite an in-flight repair). The pipeline keeps reading
        /// `holder.transcriber` so a swap stays visible.
        case active
        /// Use this transient alternate transcriber for the whole session, and
        /// surface `notice`. Never persisted (no `setPrimary`).
        case transient(any Transcribing, notice: String)
        /// A repair is in flight, the active model isn't loadable, and no
        /// installed language-compatible alternate could be loaded → cannot record.
        case blocked
    }

    func resolveSessionTranscriber() async -> SessionResolution {
        // Qwen-retirement → Nemotron Multilingual: while a surviving-Qwen user's
        // multilingual download is still pending, the active model is the
        // unloadable Qwen bundle and there is NO same-language Parakeet fallback.
        // Route the session to English so the user can dictate meanwhile. Read
        // BEFORE the repairState gate — self-heal is deferred while this download
        // is pending (see `beginSelfHeal`), so `repairState` is never set here.
        if defaults.bool(forKey: QwenRetirementMigration.crossLanguageFallbackKey) {
            for english in [ParakeetModelID.tdt_0_6b_v2_en_streaming,
                            ParakeetModelID.tdt_0_6b_v3_eou_streaming] where cache.isCached(english) {
                let candidate = transcriberFactory(english, .english)
                if (try? await candidate.ensureLoaded()) != nil, await candidate.isReady {
                    return .transient(
                        candidate,
                        notice: "Transcribing in English while your language model finishes downloading")
                }
            }
            // No English bundle on disk yet → block; the migration banner shows
            // the download progress.
            return .blocked
        }

        // Steady state: no repair in flight → always the active transcriber.
        guard repairState != nil else { return .active }

        // Repair in flight but the active model loaded fine (e.g. the failed
        // side was a non-essential preview that has since re-downloaded, or the
        // probe was a transient hiccup) → use the active model.
        if await transcriber.isReady { return .active }

        // Active model not ready during repair: try a transient, language-
        // compatible alternate.
        guard let alt = installedFallbackModel(for: activeLanguage, excluding: activeModelID) else {
            // No compatible alternate installed (e.g. fresh install with only
            // the broken model, or a non-English language with no multilingual
            // backup) → block: caller shows the persistent repairing pill.
            return .blocked
        }

        let candidate = transcriberFactory(alt, activeLanguage)
        do {
            try await candidate.ensureLoaded()
        } catch {
            // The "installed" alternate failed to load too → block.
            return .blocked
        }
        guard await candidate.isReady else { return .blocked }
        let notice = "Temporarily using \(alt.displayName) while \(activeModelID.displayName) re-downloads"
        return .transient(candidate, notice: notice)
    }

    /// The best installed fallback model for `language`, other than `excluded`.
    /// Language-gated so a transient fallback never transcribes audio in a
    /// language the alternate model can't serve:
    /// - **English** → `[v2, nemotron_en, v3_eou, v3]` (v2 first: English-
    ///   optimized + lighter; then Nemotron; then the v3 family).
    /// - **European (non-English)** → multilingual only (`v3_eou`, `v3`).
    /// - **Japanese** → none (the JA model is a separate, non-multilingual
    ///   model; v3 doesn't serve Japanese), so the caller blocks.
    /// Only returns a model whose bundle is fully present on disk (`isCached`);
    /// the caller still strict-loads it before use.
    private func installedFallbackModel(
        for language: LanguageChoice,
        excluding excluded: ParakeetModelID
    ) -> ParakeetModelID? {
        let preference: [ParakeetModelID]
        switch language {
        case .english, .englishUK:
            preference = [
                .tdt_0_6b_v2_en_streaming,
                .nemotron_en,
                .tdt_0_6b_v3_eou_streaming,
                .tdt_0_6b_v3,
            ]
        case .japanese:
            // No compatible alternate: JA is a distinct model and the v3
            // family does not serve Japanese.
            preference = []
        case .mandarin, .vietnamese, .arabic, .korean, .turkish, .hindi:
            // Only the Nemotron multilingual ship serves these; no Parakeet
            // fallback exists.
            preference = []
        case .spanish, .spanishSpain, .french, .frenchCanada, .german, .italian,
             .portuguese, .portuguesePortugal, .romanian,
             .polish, .czech, .slovak, .slovenian, .croatian, .bosnian,
             .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish, .latvian:
            // European languages are served by the multilingual v3 family only.
            preference = [
                .tdt_0_6b_v3_eou_streaming,
                .tdt_0_6b_v3,
            ]
        }
        return preference.first { $0 != excluded && cache.isCached($0) }
    }

    private static func scan(cache: ModelCache) -> Set<ParakeetModelID> {
        Set(ParakeetModelID.allCases.filter { cache.isCached($0) })
    }
}

// MARK: - PendingSwitch Equatable

/// Hand-written conformance because `ModelDownloadError` isn't `Equatable` (its
/// `.unknown(any Error)` payload can't be). We compare the error by its stable,
/// log-safe `logTag` — two states that render the same message compare equal,
/// which is exactly what SwiftUI diffing needs. All other associated values are
/// natively `Equatable`.
extension TranscriberHolder.PendingSwitch: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.downloading(lt, lf, ll, lp), .downloading(rt, rf, rl, rp)):
            return lt == rt && lf == rf && ll == rl && lp == rp
        case let (.retrying(lt, lf, ll, le, ln), .retrying(rt, rf, rl, re, rn)):
            return lt == rt && lf == rf && ll == rl && le.logTag == re.logTag && ln == rn
        case let (.failed(lt, lf, ll, le), .failed(rt, rf, rl, re)):
            return lt == rt && lf == rf && ll == rl && le.logTag == re.logTag
        default:
            return false
        }
    }
}
