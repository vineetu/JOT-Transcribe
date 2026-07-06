import Foundation

/// Pure WebVTT formatting. No FluidAudio / AVFoundation dependency so this
/// file can be compiled and exercised standalone (see `tools/jot-cli`'s
/// verification notes). Mirrors the conventions drafted for the (not yet
/// implemented) in-app exporter at `docs/webvtt-export/design.md` — same
/// timestamp shape, same escaping rules — so the two can converge later
/// without a behavior change (design doc §3 / task instructions: this is a
/// deliberate v1 duplication, not a shared module).
enum WebVTT {

    /// One caption cue: a time range, optional speaker voice-tag, and text.
    struct Cue {
        let start: TimeInterval
        let end: TimeInterval
        /// `<v LABEL>` voice tag. `nil` for the non-diarized paths.
        let speaker: String?
        let text: String
    }

    /// `HH:MM:SS.mmm` — hours always emitted (WebVTT allows omitting them,
    /// but always including them is unambiguous and safe for every player).
    static func timestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// WebVTT payload escaping (design doc §2): `&` / `<` / `>` entity-escaped,
    /// and a literal `-->` (illegal inside a cue) neutralized so it can never
    /// be mistaken for a cue timing line.
    static func escape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "-->", with: "-&gt;")
        return out
    }

    /// Render a full `.vtt` document from already-built cues.
    static func render(cues: [Cue]) -> String {
        var lines = ["WEBVTT", ""]
        for (index, cue) in cues.enumerated() {
            lines.append(String(index + 1))
            lines.append("\(timestamp(cue.start)) --> \(timestamp(cue.end))")
            if let speaker = cue.speaker {
                lines.append("<v \(escape(speaker))>\(escape(cue.text))")
            } else {
                lines.append(escape(cue.text))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Diarized path (§6, "with `--diarize`"): one cue per speaker-labeled
    /// segment, ordered by start time.
    static func vtt(diarizedSegments segments: [(speaker: String, start: Double, end: Double, text: String)]) -> String {
        let cues = segments
            .sorted { $0.start < $1.start }
            .map { Cue(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
        return render(cues: cues)
    }

    /// Non-diarized, WITH per-word timings (Parakeet `tokenTimings`): cues
    /// already grouped by the caller (`CueBuilder`) into sentence/~5-8s
    /// windows — this just renders them, no speaker tag.
    static func vtt(timedCues cues: [(start: Double, end: Double, text: String)]) -> String {
        let built = cues.map { Cue(start: $0.start, end: $0.end, speaker: nil, text: $0.text) }
        return render(cues: built)
    }

    /// Non-diarized, WITHOUT timings (Nemotron — `tokenTimings` is always
    /// `nil` on that path): a single cue spanning the whole clip.
    static func vtt(fullTranscript text: String, durationSeconds: Double) -> String {
        render(cues: [Cue(start: 0, end: max(0, durationSeconds), speaker: nil, text: text)])
    }
}
