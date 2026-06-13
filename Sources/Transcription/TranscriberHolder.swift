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

    private let cache: ModelCache
    private let defaults: UserDefaults
    /// Factory takes both the model id AND the active language so the
    /// constructed `Transcriber` can thread the FluidAudio hint through
    /// (design §5.4). Production's factory passes the language into
    /// `Transcriber(modelID:language:)`.
    private let transcriberFactory: (ParakeetModelID, LanguageChoice) -> any Transcribing
    private var migrationDownloadStarted = false

    static let defaultsKey = "jot.defaultModelID"

    /// New additive key (design §6.3): the raw `LanguageChoice`. Read at boot
    /// to seed `activeLanguage`; written by `setLanguage(_:)` and by the
    /// one-shot language migration. `jot.defaultModelID` remains the model
    /// source of truth.
    static let languageKey = "jot.transcriptionLanguage"

    init(
        cache: ModelCache = .shared,
        defaults: UserDefaults = .standard,
        transcriberFactory: @escaping (ParakeetModelID, LanguageChoice) -> any Transcribing
            = { Transcriber(modelID: $0, language: $1) },
        installedModelIDs: Set<ParakeetModelID>? = nil
    ) {
        self.cache = cache
        self.defaults = defaults
        self.transcriberFactory = transcriberFactory

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

    /// Switch the active transcription **language** (design §5.4). This is the
    /// write path behind the Setup Wizard / Settings language picker.
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
        if lang == .english,
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

    /// Re-scan the model cache directory and update `installedModelIDs`.
    /// Call after a download or removal so the Settings/Wizard "Downloaded"
    /// indicator reflects the disk state.
    func refreshInstalled() {
        installedModelIDs = Self.scan(cache: cache)
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

    private static func scan(cache: ModelCache) -> Set<ParakeetModelID> {
        Set(ParakeetModelID.allCases.filter { cache.isCached($0) })
    }
}
