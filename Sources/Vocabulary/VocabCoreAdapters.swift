import Foundation
import JotVocabCore

/// **App-side wiring for the shared `JotVocabCore` package's injection seams.**
///
/// The vocabulary-correction brains (gate, correction/provenance stores, ask
/// policy, common-words membership) now live in `JotVocabCore` (see
/// `../../jot-shared`, same no-forks rule as `JotTextPipeline`). The package is
/// a pure Foundation island; everything platform-specific crosses one of its
/// four seams. This file supplies the macOS side of all four:
///   1. engine-neutral rescore input — mapped at the rescorer call site
///      (`VocabularyRescorerHolder`), not here;
///   2. `CommonWordsProvider` — `MacCommonWordsProvider` (Bundle.main lists);
///   3. `DiagnosticsSink` — `MacVocabDiagnosticsSink` → `ErrorLog`;
///   4. storage root — `MacVocabCore.containerRoot` (Application Support).
///
/// It also re-establishes the `.shared` singletons the app called before the
/// stores moved into the package (the package types are unopinionated about
/// process/paths and take injected roots/sinks), so every existing call site
/// keeps compiling unchanged.

/// Maps the package's typed diagnostics category onto the app's cross-cutting
/// `ErrorLog` (the macOS equivalent of iOS's `DiagnosticsLog`; `DiagnosticsLog`
/// was severed on macOS — design §6/V4). Replaces the direct `os.Logger` +
/// `ErrorLog.record` calls the in-tree stores/gate made. `ErrorLog` is an actor
/// (async), so the synchronous sink hop dispatches onto a detached `Task`.
struct MacVocabDiagnosticsSink: JotVocabCore.DiagnosticsSink {
    func record(category: JotVocabCore.DiagnosticsCategory, message: String, metadata: [String: String]) {
        switch category {
        case .vocabularyGate:
            Task { await ErrorLog.shared.info(component: "VocabularyGate", message: message, context: metadata) }
        case .vocabularySaveFailed:
            Task { await ErrorLog.shared.error(component: "VocabularyGate", message: message, context: metadata) }
        }
    }
}

/// The gate's common-word membership provider (seam 2). Reads the macOS app's
/// OWN bundled `common-words-<code>.txt` lists from `Bundle.main` (17 ship —
/// design §1 seam-2 keeps each app's resources; the package's
/// `BundledCommonWordsProvider` is NOT used here because its bundle lacks `hr`
/// and names English differently). Lazily loads and caches each list into a
/// `Set` for O(1) membership, exactly as the old Mac `CommonWords` did.
/// `nil` resource ⇒ empty set (no guard, silent — the language ships no list).
final class MacCommonWordsProvider: JotVocabCore.CommonWordsProvider, @unchecked Sendable {
    static let shared = MacCommonWordsProvider(diagnostics: MacVocabCore.diagnostics)

    private let lock = NSLock()
    private var cache: [String: Set<String>] = [:]
    private let diagnostics: JotVocabCore.DiagnosticsSink

    init(diagnostics: JotVocabCore.DiagnosticsSink) {
        self.diagnostics = diagnostics
    }

    func words(forResource resource: String?) -> Set<String> {
        guard let resource else { return [] }   // nil = intentional no-guard, silent
        lock.lock()
        if let cached = cache[resource] { lock.unlock(); return cached }
        let loaded = Self.load(resource)
        let set = loaded ?? []
        cache[resource] = set
        lock.unlock()
        // Emit OUTSIDE the lock. `loaded == nil` ⇒ a resource we mapped to a
        // real name but whose `.txt` is missing/unreadable — a BUG (the
        // common-word brake silently disabled: every name becomes Jamy). A
        // present-but-empty list returns `Set([])` and stays silent.
        if loaded == nil {
            diagnostics.record(
                category: .vocabularyGate,
                message: "common-words resource '\(resource)' missing/unreadable — common-word guard DISABLED for it",
                metadata: ["resource": resource])
        }
        return set
    }

    /// `nil` ⇒ the resource is missing or unreadable (loud path). A present but
    /// empty file returns an empty `Set` (success, silent).
    private static func load(_ resource: String) -> Set<String>? {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return Set(text.split(separator: "\n").map { String($0).lowercased() })
    }
}

/// Canonical app-process instances of the package's injected dependencies.
enum MacVocabCore {
    static let diagnostics = MacVocabDiagnosticsSink()

    /// The container root the package's `Vocabulary/…` subtree lives under.
    /// Resolves the SAME `Application Support` directory the in-tree
    /// `CorrectionStore.fileURL` / `CorrectionProvenance.fileURL` used, so the
    /// package's fixed `<root>/Vocabulary/{corrections.json, provenance/,
    /// vocabulary.txt}` layout lands on top of the existing
    /// `Application Support/Vocabulary/…` files. (`vocabulary.txt` is relocated
    /// there from the legacy `Jot/Vocabulary/` path by `VocabMigration` before
    /// the store actors are first touched — design §3, L3.)
    static let containerRoot: URL? = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
}

/// The single main-app correction store (was the in-tree `CorrectionStore.shared`,
/// now the package actor with the app's root + sink injected).
extension CorrectionStore {
    static let shared = CorrectionStore(
        containerRoot: MacVocabCore.containerRoot, diagnostics: MacVocabCore.diagnostics)
}

/// The single main-app provenance store (was the in-tree `CorrectionProvenance.shared`).
extension CorrectionProvenance {
    static let shared = CorrectionProvenance(
        containerRoot: MacVocabCore.containerRoot, diagnostics: MacVocabCore.diagnostics)
}

extension LanguageChoice {
    /// The `common-words-<code>` resource name whose `.txt` the gate's
    /// common-word guard loads for this language, or `nil` when no list ships
    /// (the guard degrades to confidence/plausibility — still safe). Moved from
    /// the old `CommonWords.bcp47CommonWordsCode`: 17 lists ship today (en, es,
    /// fr, de, it, pt, ro, pl, cs, sk, sl, hr, nl, da, sv, fi, hu). The four
    /// recent locale variants share their base language's list
    /// (englishUK→en, spanishSpain→es, frenchCanada→fr, portuguesePortugal→pt).
    /// Languages with no bundled list return `nil` so the provider silently
    /// no-guards them instead of loud-diagnosing a known-absent file every
    /// dictation.
    var commonWordsResource: String? {
        switch self {
        case .english, .englishUK:             return "common-words-en"
        case .spanish, .spanishSpain:          return "common-words-es"
        case .french, .frenchCanada:           return "common-words-fr"
        case .portuguese, .portuguesePortugal: return "common-words-pt"
        case .german:                          return "common-words-de"
        case .italian:                         return "common-words-it"
        case .romanian:                        return "common-words-ro"
        case .polish:                          return "common-words-pl"
        case .czech:                           return "common-words-cs"
        case .slovak:                          return "common-words-sk"
        case .slovenian:                       return "common-words-sl"
        case .croatian:                        return "common-words-hr"
        case .dutch:                           return "common-words-nl"
        case .danish:                          return "common-words-da"
        case .swedish:                         return "common-words-sv"
        case .finnish:                         return "common-words-fi"
        case .hungarian:                       return "common-words-hu"
        case .japanese, .mandarin, .vietnamese, .arabic, .korean, .turkish,
             .hindi, .bosnian, .russian, .ukrainian, .belarusian, .bulgarian,
             .serbian, .greek, .latvian:
            return nil
        }
    }
}

/// Mac-side shared predicates over a `CorrectionStore` override snapshot, so the
/// live-pill ask filter (and any future consumer) share ONE implementation.
enum MacVocabGate {
    /// Whether `(originalWord → term)` carries an "Always replace" grant in
    /// `overrides`. **Mirrors `JotVocabCore.AskPolicy.granted`** exactly (same
    /// `CorrectionKey.normalize(originalWord)` + `term.lowercased()` match on
    /// `alwaysReplace`); duplicated Mac-side pending a public package helper —
    /// the ask path is Mac-only (UXCorrection-shaped) and doesn't run `AskPolicy`.
    static func isGranted(
        originalWord: String, term: String, in overrides: [CorrectionStore.OverrideEntry]
    ) -> Bool {
        overrides.first {
            $0.originalWord == CorrectionKey.normalize(originalWord)
                && $0.term.lowercased() == term.lowercased()
        }?.alwaysReplace == true
    }

    /// Whether a live-pill ask should be OFFERED, given the current cross-recording
    /// state. Pure decision (no store access) so it's unit-testable:
    ///   - drop pairs the owner suppressed ("Stop asking" / ≥ threshold keeps),
    ///   - drop always-replace grants (they auto-apply, never ask),
    ///   - drop a merge-shaped ask already taught once (design §1 one-shot — the
    ///     `noteMergeAsked` SPEND happens later, after the ask is surfaced).
    /// All keys are `CorrectionKey.pairKey`-shaped so they compare byte-identically
    /// to `keyboardSuppressedPairs()` / `mergeAskedPairs()`.
    static func shouldOfferAsk(
        suppressionKey: String,
        isMerge: Bool,
        isGranted: Bool,
        suppressed: Set<String>,
        mergeAsked: Set<String>
    ) -> Bool {
        if suppressed.contains(suppressionKey) { return false }
        if isGranted { return false }
        if isMerge, mergeAsked.contains(suppressionKey) { return false }
        return true
    }

    /// Whether a gate proposal is admitted as a live-pill ask candidate — a
    /// UXCorrection-shaped mirror of `AskPolicy.worthAsking`'s admission arms
    /// (JotVocabCore, not called on this Mac path). A KEPT merge
    /// ("sri ram" → "Sriram") is the designed teach ask and is EXEMPT from the
    /// common-word gate (a merge original is a multi-word phrase; single-word
    /// common-membership doesn't apply). Everything else: an APPLIED correction,
    /// or a non-common ask candidate. Returns whether to admit + whether it's the
    /// merge-teach shape (drives the once-ever one-shot + mixed-payload rules).
    static func admitAsk(
        outcome: String, shape: String?, askCandidate: Bool, originalIsCommon: Bool
    ) -> (admit: Bool, isMergeTeach: Bool) {
        let isMergeTeach = (shape == "merge" && outcome == "kept")
        let ask = isMergeTeach || (askCandidate && !originalIsCommon)
        return (admit: outcome == "applied" || ask, isMergeTeach: isMergeTeach)
    }

    /// Stable prior-descending order — a UXCorrection-shaped mirror of
    /// `AskPolicy`'s `sorted { prior($0) > prior($1) }` (closest-to-automatic
    /// first). Ties keep input order.
    static func rankByPriorDescending<T>(_ items: [T], prior: (T) -> Int) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let pa = prior(a.element), pb = prior(b.element)
                return pa != pb ? pa > pb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Mixed-payload rule — a UXCorrection-shaped mirror of `AskPolicy`
    /// (JotVocabCore) semantics: if ANY non-merge-teach ask is present, drop ALL
    /// merge-teach asks from THIS batch (a teach card must never ride a paste-
    /// holding deck) WITHOUT spending their one-shot; otherwise dedupe merge-teach
    /// asks by pair key. Order is preserved. Pure — the caller performs the
    /// `noteMergeAsked` spend only for the merges that SURVIVE and are surfaced.
    static func applyMixedPayload<T>(
        _ items: [T], isMergeTeach: (T) -> Bool, pairKey: (T) -> String
    ) -> [T] {
        let hasNormalAsk = items.contains { !isMergeTeach($0) }
        var seenMergePairs: Set<String> = []
        return items.filter { item in
            guard isMergeTeach(item) else { return true }
            if hasNormalAsk { return false }
            return seenMergePairs.insert(pairKey(item)).inserted
        }
    }
}
