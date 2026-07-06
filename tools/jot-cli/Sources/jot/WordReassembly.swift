import FluidAudio
import Foundation

/// Word-level view of FluidAudio's per-token timings. Ported from the app's
/// `Sources/Transcription/ParagraphSegmenter.reassembleWords(from:)` — same
/// BPE word-boundary heuristic (`▁` / leading-space prefixed tokens start a
/// new word; everything else extends the previous one). Kept as a small
/// standalone copy here rather than importing the app target (this package
/// builds independently of the Xcode project, per the CLI's design doc §4
/// option A).
enum WordReassembly {
    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private static let wordStartMarkers: [Character] = ["▁", " "]

    static func words(from tokens: [TokenTiming]) -> [Word] {
        guard !tokens.isEmpty else { return [] }

        var words: [Word] = []
        var currentText = ""
        var currentStart: TimeInterval = tokens[0].startTime
        var currentEnd: TimeInterval = tokens[0].endTime

        for (index, token) in tokens.enumerated() {
            let trimmed = stripWordStartMarker(token.token)
            guard !trimmed.isEmpty else { continue }

            let isWordStart = index == 0 || isWordStartToken(token.token)

            if isWordStart {
                if !currentText.isEmpty {
                    words.append(Word(text: currentText, start: currentStart, end: currentEnd))
                }
                currentText = trimmed
                currentStart = token.startTime
                currentEnd = token.endTime
            } else {
                currentText += trimmed
                currentEnd = token.endTime
            }
        }

        if !currentText.isEmpty {
            words.append(Word(text: currentText, start: currentStart, end: currentEnd))
        }

        return words
    }

    private static func isWordStartToken(_ raw: String) -> Bool {
        guard let first = raw.first else { return false }
        return wordStartMarkers.contains(first)
    }

    private static func stripWordStartMarker(_ raw: String) -> String {
        guard let first = raw.first, wordStartMarkers.contains(first) else { return raw }
        return String(raw.dropFirst())
    }
}
