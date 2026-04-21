import Foundation
import SwiftUI

/// Loads, mutates, and persists the user's custom vocabulary list.
///
/// Persistence is a plain-text file at
/// `~/Library/Application Support/Jot/Vocabulary/vocabulary.txt`. One term
/// per line, optional aliases after a colon separator:
///
/// ```
/// UJET: you jet, ew jet
/// Osiris
/// D'Andre: dandre, dahndray
/// Parakeet
/// ```
///
/// Colon (not pipe) because that's the separator FluidAudio's own
/// `CustomVocabularyContext.loadFromSimpleFormat(from:)` recognizes at
/// v0.13.6 — the Phase B rescorer wiring can point FluidAudio at this
/// exact file without a format translation step. Format rules:
///   • `#` at the start of a line → comment, ignored.
///   • First colon on a line separates term from its alias list. Colons
///     within the alias segment are preserved verbatim (parser splits
///     on first colon only, matching FluidAudio's semantics).
///   • `,` always separates aliases — aliases containing commas cannot
///     be represented.
///   • Line endings: LF, CRLF, or mixed are tolerated; trimming strips
///     all whitespace + newlines, matching FluidAudio's trim rules so
///     a file externally edited on Windows loads identically in both.
///
/// Writes are serialized through an `@MainActor` barrier so rapid
/// mutations can't land out of order. File size is small (< 4 KB for
/// 100 terms) so synchronous writes on the main actor are below the
/// perceptual threshold; background `Task.detached` was tried earlier
/// but introduced a stale-overwrite race.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published private(set) var terms: [VocabTerm] = []

    /// Master toggle. When off, the vocabulary file is still preserved
    /// and editable; it's just not applied to transcription. Stored in
    /// UserDefaults so the preference survives a reset-permissions flow
    /// without wiping settings.
    @AppStorage("jot.vocabulary.enabled") var isEnabled: Bool = false

    static let shared = VocabularyStore()

    /// Location of the user's vocabulary file. Published (read-only) so
    /// other actors — notably `VocabularyRescorerHolder` on the
    /// transcription actor — can hand the path to FluidAudio without a
    /// round-trip through the store. Resolved once per process lifetime;
    /// a `nil` means Application Support was unavailable (sandboxed state
    /// we do not expect in the shipping app), in which case persistence
    /// silently no-ops and the pane still renders from the in-memory
    /// list.
    public private(set) lazy var fileURL: URL? = {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("Jot", isDirectory: true)
            .appendingPathComponent("Vocabulary", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    private init() {
        load()
    }

    // MARK: - Load / save

    func load() {
        guard let url = fileURL,
              let data = try? String(contentsOf: url, encoding: .utf8)
        else {
            terms = []
            return
        }
        terms = Self.parse(data)
    }

    func save() {
        guard let url = fileURL else { return }
        let body = Self.serialize(terms)
        // Synchronous write on the main actor. Vocabulary files are <4KB
        // even at 100 terms and `String.write(to:atomically:)` measures
        // in sub-millisecond territory — well inside the 16ms frame
        // budget. An earlier revision used `Task.detached` for the write
        // but that let two rapid mutations race (second mutation's save
        // could land before first's on disk), leaving the file stale.
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Swallow for now — a future phase will route this through
            // ErrorLog.append so users can surface it via the About pane
            // Troubleshooting section. Blocking the UI on a persistence
            // failure is worse than the silent drop for an MVP.
        }

        // Nudge the rescorer to re-tokenize against the updated file.
        // Cheap when the rescorer is already prepared; throws `.notPrepared`
        // (swallowed) otherwise, so a save with vocab boosting disabled
        // is a no-op. Keeps the "edit vocab, record immediately" UX
        // promised in docs/research/ctc-vocabulary-boosting.md §4.
        if isEnabled {
            Task {
                try? await VocabularyRescorerHolder.shared.rebuildVocabulary(from: url)
            }
        }
    }

    // MARK: - Mutations (each writes through)

    func addBlankTerm() -> VocabTerm {
        let new = VocabTerm(text: "")
        terms.append(new)
        save()
        return new
    }

    func delete(id: VocabTerm.ID) {
        terms.removeAll { $0.id == id }
        save()
    }

    func update(id: VocabTerm.ID, text: String? = nil, aliases: [String]? = nil) {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        if let text { terms[idx].text = text }
        if let aliases { terms[idx].aliases = aliases }
        save()
    }

    // MARK: - Simple-format parser / serializer

    /// Parse the plain-text format. Lines starting with `#` are treated
    /// as comments. Empty lines are skipped. Terms with duplicate text
    /// are preserved (the user gets to see the duplicate and delete it);
    /// we don't silently dedupe.
    ///
    /// Colon separator between term and aliases matches FluidAudio
    /// v0.13.6 `CustomVocabularyContext.loadFromSimpleFormat` — a term
    /// without a colon is the whole line verbatim. All trims use
    /// `.whitespacesAndNewlines` so CRLF line endings (Windows-edited
    /// files) parse identically to LF — the two implementations must
    /// agree on interpretation or Phase B's rescorer will see a
    /// different list than the pane shows.
    static func parse(_ body: String) -> [VocabTerm] {
        var result: [VocabTerm] = []
        let lines = body.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let text = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            let aliases: [String] = parts.count > 1
                ? parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                : []

            result.append(VocabTerm(text: text, aliases: aliases))
        }
        return result
    }

    static func serialize(_ terms: [VocabTerm]) -> String {
        var lines: [String] = []
        for t in terms where !t.isBlank {
            let trimmedText = t.text.trimmingCharacters(in: .whitespaces)
            if t.aliases.isEmpty {
                lines.append(trimmedText)
            } else {
                lines.append("\(trimmedText): \(t.aliases.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
