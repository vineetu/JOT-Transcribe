import Foundation

/// One user-curated vocabulary term — the word Jot should prefer, plus
/// optional "sounds like" aliases that drive an alias-substitution fallback
/// when the acoustic CTC rescorer doesn't catch the misfire on its own.
///
/// Identifiable for SwiftUI `ForEach`, Codable for potential future JSON
/// export/import. On-disk persistence uses the plain-text "simple format"
/// (one term per line, `Term: alias1, alias2`) — not JSON — because that's
/// what FluidAudio's `CustomVocabularyContext.loadFromSimpleFormat(from:)`
/// consumes directly and it's human-editable.
struct VocabTerm: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var aliases: [String]

    init(id: UUID = UUID(), text: String, aliases: [String] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
    }

    /// True when the term is empty or whitespace only. Used to skip
    /// degenerate rows during persistence.
    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
