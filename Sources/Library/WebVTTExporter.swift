import Foundation

/// Pure, engine-agnostic WebVTT (`.vtt`) formatter for a recording's
/// transcript. Two entry points mirror the two shapes a recording can be in:
///
/// - Diarized (`Recording.speakerTimeline` decodes to a non-empty
///   `SpeakerTimelinePayload`): one cue per `SpeakerTimelineSegment`, each
///   carrying a `<v LABEL>` voice tag.
/// - Non-diarized (the common case — no per-token timings are persisted
///   in-app, only diarized recordings carry any timestamps at all): a
///   single cue spanning the whole recording with the full transcript and
///   no voice tag.
///
/// No view/model coupling — takes plain segments/strings, returns a
/// `String`. `RecordingDetailView`'s export action decides which overload
/// to call and writes the result to disk (`docs/webvtt-export/design.md`).
enum WebVTTExporter {

    /// Diarized export: cue-per-segment, ordered by `startSec`, each cue
    /// carrying a `<v LABEL>` voice tag ahead of the (escaped) text.
    static func vtt(segments: [SpeakerTimelineSegment]) -> String {
        let ordered = segments.sorted { $0.startSec < $1.startSec }
        var out = "WEBVTT\n\n"
        for (idx, seg) in ordered.enumerated() {
            out += "\(idx + 1)\n"
            out += "\(timestamp(seg.startSec)) --> \(timestamp(seg.endSec))\n"
            out += "<v \(escape(seg.speakerLabel))>\(cueText(seg.text))\n"
            out += "\n"
        }
        return out
    }

    /// Non-diarized fallback: a single cue spanning the whole recording,
    /// no `<v>` tag — we have no per-turn timing or speaker split without a
    /// timeline. `durationSec` degenerates to `0` (still a valid, if
    /// pointless, cue span) rather than failing when duration is unknown.
    static func vtt(fullTranscript: String, durationSec: Double) -> String {
        let duration = durationSec.isFinite && durationSec > 0 ? durationSec : 0
        var out = "WEBVTT\n\n"
        out += "1\n"
        out += "\(timestamp(0)) --> \(timestamp(duration))\n"
        out += "\(cueText(fullTranscript))\n"
        return out
    }

    /// Escaped cue text with blank lines collapsed. A blank line inside a cue
    /// TERMINATES it in WebVTT, so a multi-paragraph transcript (paragraph
    /// breaks are `\n\n`) exported as one cue would corrupt the file — the
    /// rest would parse as stray malformed cues. Normalize `\r`, collapse any
    /// run of 2+ newlines to a single newline (keeps a valid multi-line cue),
    /// and trim leading/trailing newlines so the cue boundary stays clean.
    static func cueText(_ s: String) -> String {
        let escaped = escape(s)
        let normalized = escaped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n[ \t]*\n[\n \t]*", with: "\n", options: .regularExpression)
        return normalized.trimmingCharacters(in: .newlines)
    }

    /// `sec` → `HH:MM:SS.mmm`. Always emits the hours component (WebVTT
    /// makes it optional, but always-on is safer across players). Rounds to
    /// the nearest millisecond rather than truncating, so e.g. 59.9994s
    /// doesn't silently become `.999` when it should round up.
    static func timestamp(_ sec: Double) -> String {
        let clamped = max(0, sec)
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// WebVTT payload escaping: `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, applied
    /// to cue text AND the label inside a `<v …>` tag. A literal `-->` in
    /// text would otherwise terminate the cue early / corrupt the file, so
    /// it's additionally rewritten to `-&gt;` (the `>`→`&gt;` pass above
    /// already covers the `>`; this pass targets the exact `-->` run so the
    /// arrow reads intentionally rather than as a stray escaped `>`).
    static func escape(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "--&gt;", with: "-&gt;")
        return out
    }
}
