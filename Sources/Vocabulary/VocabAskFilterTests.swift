#if DEBUG
import Foundation
import JotVocabCore

/// DEBUG-only runtime tests for the Phase-B live-pill ask logic — the pure
/// filter decision (suppression / always-replace grant / merge-teach one-shot),
/// the shared granted predicate, and the wider-span alt0 splice. Same
/// `assert()`-in-`#if DEBUG` idiom as the other in-app harnesses; runs once at
/// startup via `runAll()` and is stripped from release builds.
enum VocabAskFilterTests {

    static func runAll() {
        test_shouldOffer_cleanPasses()
        test_shouldOffer_suppressedDropped()
        test_shouldOffer_grantedDropped()
        test_shouldOffer_mergeOneShot()
        test_isGranted_normalizedCaseInsensitivePair()
        test_widerSpanSplice_multiWord()
        test_widerSpanSplice_wordBoundarySafe()
        // Review round: merge lane (H1), ranking + mixed-payload (M3), alt re-gate.
        test_admitAsk_mergeLaneAndAddendumGate()
        test_mixedPayload_dropsMergeWhenNormalPresent()
        test_mixedPayload_dedupesMergeWhenNoNormal()
        test_rankByPriorDescending_stable()
        test_rankForAsk_weakestEvidenceFirst()
        test_alternateOffer_reGatedByStagedText()
        test_widerSpanSplice_firstOccurrenceOnly()
    }

    private struct FlagItem { let key: String; let merge: Bool }
    private struct PriorItem { let key: String; let prior: Int }
    private struct EvidenceItem { let key: String; let evidence: String?; let prior: Int }

    // MARK: - shouldOfferAsk (pure ask-filter decision)

    private static func key(_ from: String, _ term: String) -> String {
        CorrectionKey.pairKey(originalWord: from, term: term)
    }

    static func test_shouldOffer_cleanPasses() {
        let k = key("jamie", "Jamy")
        assert(MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: false, isGranted: false,
                                           suppressed: [], mergeAsked: []),
               "a clean, unsuppressed, ungranted, non-merge ask should be offered")
    }

    static func test_shouldOffer_suppressedDropped() {
        let k = key("jamie", "Jamy")
        assert(!MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: false, isGranted: false,
                                            suppressed: [k], mergeAsked: []),
               "a suppressed pair must not be offered")
    }

    static func test_shouldOffer_grantedDropped() {
        let k = key("jamie", "Jamy")
        assert(!MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: false, isGranted: true,
                                            suppressed: [], mergeAsked: []),
               "an always-replace grant auto-applies — never offered")
    }

    static func test_shouldOffer_mergeOneShot() {
        let k = key("sri ram", "Sriram")
        // Merge already taught once → dropped forever.
        assert(!MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: true, isGranted: false,
                                            suppressed: [], mergeAsked: [k]),
               "a merge-shaped ask already in mergeAsked must be dropped")
        // Merge not yet taught → offered (its shot is spent AFTER surfacing).
        assert(MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: true, isGranted: false,
                                           suppressed: [], mergeAsked: []),
               "a first-time merge ask should be offered")
        // The merge-one-shot rule applies ONLY to merge-shaped asks — a non-merge
        // ask whose key coincidentally sits in mergeAsked is NOT dropped by it.
        assert(MacVocabGate.shouldOfferAsk(suppressionKey: k, isMerge: false, isGranted: false,
                                           suppressed: [], mergeAsked: [k]),
               "a non-merge ask ignores the mergeAsked set")
    }

    // MARK: - isGranted (shared granted predicate, mirrors AskPolicy.granted)

    static func test_isGranted_normalizedCaseInsensitivePair() {
        let overrides = [
            CorrectionStore.OverrideEntry(
                originalWord: CorrectionKey.normalize("Jamie"), term: "Jamy", net: 2, alwaysReplace: true),
            CorrectionStore.OverrideEntry(
                originalWord: CorrectionKey.normalize("bob"), term: "Bob", net: 1, alwaysReplace: false),
        ]
        assert(MacVocabGate.isGranted(originalWord: "Jamie", term: "jamy", in: overrides),
               "granted pair matches case-insensitively under the normalized key")
        assert(!MacVocabGate.isGranted(originalWord: "bob", term: "Bob", in: overrides),
               "a present-but-not-granted pair is not granted")
        assert(!MacVocabGate.isGranted(originalWord: "absent", term: "Absent", in: overrides),
               "an absent pair is not granted")
    }

    // MARK: - wider-span alt0 splice (altFind → altTerm)

    static func test_widerSpanSplice_multiWord() {
        let out = AppDelegate.replaceWholeWord("sri ram", with: "Sriram", in: "please call sri ram now")
        assert(out == "please call Sriram now",
               "multi-word altFind should splice to the wider altTerm, got \(out)")
    }

    static func test_widerSpanSplice_wordBoundarySafe() {
        // The alternate slice must match on whole-word boundaries (first occurrence).
        let out = AppDelegate.replaceWholeWord("ann", with: "Anne", in: "announcement by ann today")
        assert(out == "announcement by Anne today",
               "splice must skip 'ann' inside 'announcement', got \(out)")
    }

    // MARK: - Merge lane admission (H1)

    static func test_admitAsk_mergeLaneAndAddendumGate() {
        // A KEPT merge is the teach ask — admitted EVEN when the gate marks it
        // askCandidate=false.
        let merge = MacVocabGate.admitAsk(
            outcome: "kept", shape: "merge", askCandidate: false, originalIsCommon: false)
        assert(merge.admit && merge.isMergeTeach, "kept merge admitted as teach, got \(merge)")
        // …but not when its original is common: the store refuses to learn it,
        // so the one-shot must not burn (matches iOS AskPolicy).
        let commonMerge = MacVocabGate.admitAsk(
            outcome: "kept", shape: "merge", askCandidate: false, originalIsCommon: true)
        assert(!commonMerge.admit && !commonMerge.isMergeTeach,
               "common-original merge must not be a teach ask, got \(commonMerge)")
        // An applied correction is admitted (not a merge teach).
        let applied = MacVocabGate.admitAsk(
            outcome: "applied", shape: nil, askCandidate: false, originalIsCommon: false)
        assert(applied.admit && !applied.isMergeTeach, "applied admitted, not merge")
        // A COMMON-word ask candidate is NOT admitted (addendum gate).
        let common = MacVocabGate.admitAsk(
            outcome: "kept", shape: nil, askCandidate: true, originalIsCommon: true)
        assert(!common.admit, "common-word ask candidate must not be admitted")
        // A non-common ask candidate is admitted.
        let ok = MacVocabGate.admitAsk(
            outcome: "kept", shape: nil, askCandidate: true, originalIsCommon: false)
        assert(ok.admit && !ok.isMergeTeach, "non-common ask candidate admitted")
    }

    // MARK: - Mixed-payload drop (M3b)

    static func test_mixedPayload_dropsMergeWhenNormalPresent() {
        let items = [FlagItem(key: "a", merge: false),
                     FlagItem(key: "m1", merge: true),
                     FlagItem(key: "m2", merge: true)]
        let out = MacVocabGate.applyMixedPayload(items, isMergeTeach: { $0.merge }, pairKey: { $0.key })
        assert(out.map(\.key) == ["a"],
               "a normal ask present → all merge-teach asks dropped, got \(out.map(\.key))")
    }

    static func test_mixedPayload_dedupesMergeWhenNoNormal() {
        let items = [FlagItem(key: "m1", merge: true),
                     FlagItem(key: "m1", merge: true),
                     FlagItem(key: "m2", merge: true)]
        let out = MacVocabGate.applyMixedPayload(items, isMergeTeach: { $0.merge }, pairKey: { $0.key })
        assert(out.map(\.key) == ["m1", "m2"],
               "no normal ask → merge-teach asks deduped by pair, got \(out.map(\.key))")
    }

    // MARK: - Prior-desc ranking (M3a)

    static func test_rankByPriorDescending_stable() {
        let items = [PriorItem(key: "a", prior: 0), PriorItem(key: "b", prior: 2),
                     PriorItem(key: "c", prior: 1), PriorItem(key: "d", prior: 2)]
        let out = MacVocabGate.rankByPriorDescending(items) { $0.prior }
        // Highest prior first; ties keep input order (b before d).
        assert(out.map(\.key) == ["b", "d", "c", "a"],
               "prior-desc stable order, got \(out.map(\.key))")
    }

    // MARK: - Evidence-first ranking (design A5)

    static func test_rankForAsk_weakestEvidenceFirst() {
        let items = [EvidenceItem(key: "a", evidence: "acoustic", prior: 2),
                     EvidenceItem(key: "b", evidence: "textual", prior: 0),
                     EvidenceItem(key: "c", evidence: nil, prior: 1),
                     EvidenceItem(key: "d", evidence: "textual", prior: 1)]
        let out = MacVocabGate.rankForAsk(items, evidence: { $0.evidence }, prior: { $0.prior })
        // Textual (string-only) first, prior-desc within a kind; legacy nil ranks
        // with acoustic.
        assert(out.map(\.key) == ["d", "b", "a", "c"],
               "evidence-first stable order, got \(out.map(\.key))")
    }

    // MARK: - Alternate offer re-gate + repeat-phrase splice (L1 limitation)

    static func test_alternateOffer_reGatedByStagedText() {
        // The alt is offered only when its in-text slice is still present.
        assert(AppDelegate.containsWholeWord("sri ram", in: "call sri ram now"),
               "altFind present → offerable")
        assert(!AppDelegate.containsWholeWord("sri ram", in: "call Sri now"),
               "a prior ask's edit removed altFind → not offerable")
    }

    static func test_widerSpanSplice_firstOccurrenceOnly() {
        // Documents the M2 limitation shape: a repeat phrase splices only the FIRST
        // occurrence (the confirmed alt doesn't auto-apply the rest / next time).
        let out = AppDelegate.replaceWholeWord("sri ram", with: "Sriram", in: "sri ram and sri ram")
        assert(out == "Sriram and sri ram",
               "only the first occurrence is spliced, got \(out)")
    }
}
#endif
