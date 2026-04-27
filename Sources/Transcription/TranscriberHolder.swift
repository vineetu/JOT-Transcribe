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
    @Published private(set) var transcriber: any Transcribing
    @Published private(set) var installedModelIDs: Set<ParakeetModelID>

    private let cache: ModelCache
    private let defaults: UserDefaults
    private let transcriberFactory: (ParakeetModelID) -> any Transcribing

    static let defaultsKey = "jot.defaultModelID"

    init(
        cache: ModelCache = .shared,
        defaults: UserDefaults = .standard,
        transcriberFactory: @escaping (ParakeetModelID) -> any Transcribing = { Transcriber(modelID: $0) },
        installedModelIDs: Set<ParakeetModelID>? = nil
    ) {
        self.cache = cache
        self.defaults = defaults
        self.transcriberFactory = transcriberFactory

        let stored = defaults.string(forKey: Self.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))
            ?? .tdt_0_6b_v3
        self.primaryModelID = stored
        self.transcriber = transcriberFactory(stored)
        // Phase 4 hermetic-harness fix: callers (the harness) can seed
        // an explicit installed-set so tests don't read the dev
        // machine's `~/Library/Application Support/Jot/Models/...`
        // cache. Production omits the arg and gets a real disk scan.
        self.installedModelIDs = installedModelIDs ?? Self.scan(cache: cache)
    }

    /// Swap to a different primary model. No-op when `id == primaryModelID`.
    /// Persists the new id to `UserDefaults` under the legacy
    /// `jot.defaultModelID` key so existing users' selection survives.
    /// `try? await ensureLoaded()` is best-effort — failures surface to the
    /// next `transcribe(_:)` call, which already handles the not-loaded case.
    func setPrimary(_ id: ParakeetModelID) async {
        guard id != primaryModelID else { return }
        let new = transcriberFactory(id)
        primaryModelID = id
        transcriber = new
        defaults.set(id.rawValue, forKey: Self.defaultsKey)
        try? await new.ensureLoaded()
    }

    /// Re-scan the model cache directory and update `installedModelIDs`.
    /// Call after a download or removal so the Settings/Wizard "Downloaded"
    /// indicator reflects the disk state.
    func refreshInstalled() {
        installedModelIDs = Self.scan(cache: cache)
    }

    private static func scan(cache: ModelCache) -> Set<ParakeetModelID> {
        Set(ParakeetModelID.allCases.filter { cache.isCached($0) })
    }
}
