import Foundation
import JotVocabCore

/// Model-free vocabulary correction (JotVocabCore `VocabularyCorrector` +
/// `VocabularyGate`) over the same `vocabulary.txt` the app writes. Reading a
/// documented path is a shared on-disk convention, not a runtime dependency —
/// the app and the CLI never talk (design doc §10/§15).
///
/// This is deliberately the acoustic-model-free path: no CTC spotter, no
/// CoreML, no extra downloads — right for a headless binary. The acoustic
/// spot+gate upgrade for stream mode (design §15) is follow-up work gated on
/// the JotEngine extraction.
struct VocabularyApplier {
    let terms: [VocabTerm]
    let language: String

    /// `~/Library/Application Support/Jot/Vocabulary/vocabulary.txt` — the
    /// exact file `VocabularyStore` persists (FluidAudio simple format).
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot/Vocabulary/vocabulary.txt")
    }

    /// Resolve the vocabulary for this invocation. Returns `nil` (vocab off)
    /// when disabled, when the default file is absent, or when the file
    /// parses to zero usable terms. An explicit `--vocab` path that cannot be
    /// read is a hard error — the caller asked for that file specifically.
    static func load(
        explicitPath: String?, disabled: Bool, language: CLILanguage
    ) throws -> VocabularyApplier? {
        guard !disabled else { return nil }
        let url = explicitPath.map { URL(fileURLWithPath: $0) } ?? defaultFileURL

        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if explicitPath != nil {
                throw CLIVocabError.unreadable(url, error)
            }
            return nil  // no default vocabulary file — vocab silently off
        }

        let terms = VocabularyFile.parse(body).filter { !$0.isBlank }
        guard !terms.isEmpty else { return nil }
        return VocabularyApplier(terms: terms, language: language.base)
    }

    /// Fuzzy-match transcript words against the user's terms and apply the
    /// gated corrections. `VocabularyCorrector.correct` is internally
    /// language-served (unsupported languages are an identity no-op).
    func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return VocabularyCorrector.correct(
            transcript: text,
            terms: terms,
            language: language,
            commonWords: BundledCommonWordsProvider.shared
        ).text
    }
}

enum CLIVocabError: Error, CustomStringConvertible {
    case unreadable(URL, Error)

    var description: String {
        switch self {
        case .unreadable(let url, let error):
            return "cannot read vocabulary file \(url.path): \(error.localizedDescription)"
        }
    }
}
