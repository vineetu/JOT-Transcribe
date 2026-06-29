import Foundation

/// One renderable piece of a parsed Ask-Jot answer: either a run of prose or a
/// resolved citation chip pointing back at one of the source transcripts.
///
/// The in-app Ask surface renders `.text` as markdown prose and `.citation` as a
/// tappable chip labelled with the source's date. `recordingID` links the chip to
/// the recording the model cited so a tap can deep-link to it.
enum AskAnswerSegment: Equatable {
    case text(String)
    case citation(recordingID: UUID, label: String)
}

/// One source the model may cite, in the exact order it was presented to the
/// model. Citations are **1-based indices into this array** (NOT UUIDs): the
/// model writes `[cite: 3]` to point at the 3rd source. `label` is the
/// human-readable date string shown on the rendered chip.
struct AskCitationSource: Equatable {
    let recordingID: UUID
    let label: String

    init(recordingID: UUID, label: String) {
        self.recordingID = recordingID
        self.label = label
    }
}

/// Incremental parser that converts an LLM answer (with inline `[cite: N]`
/// markers) into a flat sequence of renderable `AskAnswerSegment` values.
///
/// ## Streaming contract
///
/// Callers pass the *cumulative* answer text after every stream chunk
/// (not deltas). The parser is idempotent: running it on a longer
/// prefix of the same answer produces a superset of the prior result.
/// This decouples the parser from whatever shape the streaming API
/// happens to emit (delta vs. snapshot vs. structured chunk).
///
/// ## Tail tolerance
///
/// If the text ends with a partial marker (e.g. `…answer [cite: 4`),
/// the partial is held back as pending — neither emitted as text nor
/// as a citation — so the user never sees a half-rendered `[cite:` in
/// the streamed answer. Once the closing `]` arrives in a later chunk,
/// the marker is resolved.
///
/// ## Hallucination / placeholder guard
///
/// Markers cite by 1-based index into the `sources` array (e.g. `[cite: 3]`).
/// Any marker whose inner text isn't a valid in-range index — an
/// out-of-range number, a stray UUID, or a leftover `TRANSCRIPT_ID`
/// placeholder the model echoed from the prompt — is dropped entirely:
/// both the marker text AND the surrounding bracket are stripped.
/// Dropping silently is better than leaking a raw marker onto the
/// screen or navigating to a transcript that wasn't retrieved.
///
/// ## Citation-tail orphans
///
/// If the stream terminates while a marker is still partial (e.g. user
/// cancelled, model died), the unresolved tail is emitted as plain
/// text via `finalize(...)`. Cosmetic glitch acceptable; rare.
enum AskCitationParser {
    /// Pre-compiled regex matching `[cite: …]` with ANY content inside
    /// the brackets — not just a valid index. Capturing the raw inner
    /// text (rather than only well-formed indices) lets `parse` strip
    /// *every* citation marker the model emits, including malformed ones
    /// like a leftover `[cite: TRANSCRIPT_ID]` placeholder or an
    /// out-of-range number. Only markers that resolve to a real
    /// transcript become chips; the rest disappear entirely instead of
    /// leaking onto the screen. Static so we don't recompile per call.
    private static let markerRegex: NSRegularExpression = {
        // Pattern: literal `[cite:`, then any run of non-`]` characters,
        // then `]`. Case-insensitive on `cite`.
        let pattern = #"\[cite:\s*([^\]]*?)\s*\]"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Strip EVERY `[cite: …]` marker from `text`, returning clean prose.
    /// The in-app Ask screen renders these markers as citation chips, but the
    /// spoken / voice path has nowhere to put chips, so the raw
    /// "[cite: 1][cite: 2]…" leaks as noise. Collapses the stray double-space a
    /// removed marker leaves between words.
    static func stripMarkers(from text: String) -> String {
        let ns = NSRange(text.startIndex..., in: text)
        let stripped = markerRegex.stringByReplacingMatches(
            in: text, options: [], range: ns, withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the cumulative answer text into segments. Use this while
    /// the stream is in flight — call after every chunk arrives.
    static func parseStreaming(
        cumulative text: String,
        sources: [AskCitationSource]
    ) -> [AskAnswerSegment] {
        parse(text: text, sources: sources, includeTailPartial: false)
    }

    /// Parse the final answer text after the stream has completed (or
    /// been cancelled). Includes any unresolved tail as plain text.
    static func finalize(
        cumulative text: String,
        sources: [AskCitationSource]
    ) -> [AskAnswerSegment] {
        parse(text: text, sources: sources, includeTailPartial: true)
    }

    // MARK: - Internal

    private static func parse(
        text: String,
        sources: [AskCitationSource],
        includeTailPartial: Bool
    ) -> [AskAnswerSegment] {
        // Identify the cutoff point — if there's an unclosed `[` that
        // could be the start of a partial marker, freeze everything
        // from that `[` onward into `pendingTail`. The completed prefix
        // is what we feed to regex matching.
        let (completedPrefix, pendingTail) = splitAtPartialMarker(text)
        let textToScan = includeTailPartial ? text : completedPrefix

        let nsText = textToScan as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = markerRegex.matches(in: textToScan, options: [], range: fullRange)

        var segments: [AskAnswerSegment] = []
        var cursor = 0

        for match in matches {
            // Emit text before this match (if any).
            if match.range.location > cursor {
                let between = nsText.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))
                if !between.isEmpty {
                    segments.append(.text(between))
                }
            }

            // Resolve the citation index. Range 1 = the capture group —
            // the raw text between `[cite:` and `]`. We expect a 1-based
            // index into `sources`; anything else (a leftover
            // `TRANSCRIPT_ID` placeholder, a stray UUID, an out-of-range
            // number) fails the lookup and the marker is dropped.
            let innerNSRange = match.range(at: 1)
            let inner = nsText.substring(with: innerNSRange)
                .trimmingCharacters(in: .whitespaces)
            if let index = Int(inner),
               index >= 1, index <= sources.count {
                let source = sources[index - 1]
                segments.append(.citation(
                    recordingID: source.recordingID,
                    label: source.label
                ))
            }
            // If the index is unparseable / out of range, the marker AND
            // its bracket disappear silently. The cursor advances past it
            // either way.
            cursor = match.range.location + match.range.length
        }

        // Trailing text after the last match.
        if cursor < nsText.length {
            let trailing = nsText.substring(with: NSRange(
                location: cursor,
                length: nsText.length - cursor
            ))
            if !trailing.isEmpty {
                segments.append(.text(trailing))
            }
        }

        // If we were called in streaming mode and there's a held-back
        // partial tail, do NOT append it. The next call (with more
        // text) will resolve it.
        _ = pendingTail
        return segments
    }

    /// Returns (completedPrefix, pendingTail). The pendingTail is the
    /// portion from the last unclosed `[` onward IF that `[` could be
    /// the start of a `[cite:` marker. Otherwise pendingTail is empty
    /// and completedPrefix == text.
    ///
    /// Heuristic: scan from the end for the last `[`. If everything
    /// after it is a strict prefix of `[cite: <index>]`, hold it back.
    /// Otherwise the `[` is just a literal bracket in the answer and
    /// we treat the whole text as completed.
    private static func splitAtPartialMarker(_ text: String) -> (String, String) {
        guard let openIdx = text.lastIndex(of: "[") else {
            return (text, "")
        }
        let tail = String(text[openIdx...])
        // Already-closed marker — let the regex handle it normally.
        if tail.contains("]") {
            return (text, "")
        }
        // Could this be a budding `[cite: …]` marker? Check whether
        // `tail` is a strict prefix of the canonical shape. If yes,
        // hold it back.
        if isLikelyPartialCitationMarker(tail) {
            let completedPrefix = String(text[..<openIdx])
            return (completedPrefix, tail)
        }
        // It's some other `[…` that won't become a marker. Leave alone.
        return (text, "")
    }

    private static func isLikelyPartialCitationMarker(_ tail: String) -> Bool {
        // Acceptable partials, in order of progress:
        //   "["
        //   "[c", "[ci", "[cit", "[cite"
        //   "[cite:"
        //   "[cite: "
        //   "[cite: <digits>"
        guard tail.hasPrefix("[") else { return false }
        let rest = tail.dropFirst()  // drop "["
        let prefix = "cite:"
        // Partial of "cite:"
        if prefix.hasPrefix(rest) { return true }
        // Past "cite:" — must be whitespace + index-like characters.
        guard rest.hasPrefix(prefix) else { return false }
        let afterColon = rest.dropFirst(prefix.count)
        // Allow optional whitespace then index-shape characters. We keep
        // the hex/hyphen tolerance from the original (which expected
        // UUID-shaped inners) so a model that echoes a stray UUID-like
        // token is still held back rather than flashed — the
        // out-of-range guard drops it on resolution either way.
        var sawNonWhitespace = false
        for ch in afterColon {
            if !sawNonWhitespace {
                if ch == " " || ch == "\t" { continue }
                sawNonWhitespace = true
            }
            // Once past whitespace, only hex digits or hyphens are
            // legal partial-marker characters. Anything else means the
            // `[` is NOT becoming a citation marker.
            let isHex = ch.isHexDigit
            let isHyphen = ch == "-"
            if !isHex && !isHyphen {
                return false
            }
        }
        return true
    }
}
