import Foundation

/// One-time, unconditional relocation of the curated vocabulary file into the
/// unified `Application Support/Vocabulary/` root that `JotVocabCore`'s stores
/// (`CorrectionStore` / `CorrectionProvenance`) and `VocabularyStore` now share
/// (design §3, JotVocabCore adoption).
///
/// Before adoption the macOS app kept `vocabulary.txt` under
/// `Application Support/Jot/Vocabulary/` while `corrections.json` and
/// `provenance/` already lived under `Application Support/Vocabulary/`. Adoption
/// canonicalizes on the latter (it already matches iOS and two of Mac's three
/// paths), so exactly one precious, human-curated file moves.
///
/// **Ordering is load-bearing (design §3, L3).** This must complete BEFORE the
/// `VocabularyStore` actor is constructed / its `fileURL` first resolved and
/// before any `save()` can fire — otherwise a `save()` against the new path
/// while the file still sits at the old one would write an empty list to the
/// new path (or race the move, a check-then-move TOCTOU). It is invoked at the
/// top of `applicationDidFinishLaunching` AND (structural guard) from
/// `VocabularyStore.fileURL`'s first resolution — idempotence makes the double
/// call free, and the second site makes the ordering true by construction.
enum VocabMigration {
    /// Move `Jot/Vocabulary/vocabulary.txt` → `Vocabulary/vocabulary.txt` when
    /// the source exists and the destination does not. Idempotent: a no-op on
    /// every subsequent launch (source gone, or destination already present).
    static func relocateVocabularyFileIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let old = appSupport
            .appendingPathComponent("Jot", isDirectory: true)
            .appendingPathComponent("Vocabulary", isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
        let newDir = appSupport.appendingPathComponent("Vocabulary", isDirectory: true)
        let new = newDir.appendingPathComponent("vocabulary.txt")

        // Move only when the source is present AND the destination is absent —
        // never clobber an already-relocated (possibly newer) file.
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }
}
