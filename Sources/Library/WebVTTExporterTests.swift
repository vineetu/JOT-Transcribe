#if DEBUG
import Foundation

/// DEBUG-only runtime tests for `WebVTTExporter` (`docs/webvtt-export/design.md`).
/// Same `assert()`-in-`#if DEBUG` idiom as `HelpInfraTests` — the main Jot
/// app target doesn't link XCTest, so these run once at startup via
/// `WebVTTExporterTests.runAll()` and are stripped from release builds.
enum WebVTTExporterTests {

    @MainActor
    static func runAll() {
        test_timestamp_atKeyBoundaries()
        test_escape_ampersandLessGreaterAndArrow()
        test_diarized_twoSegmentRoundTrip()
        test_nonDiarized_singleCueFallback()
    }

    static func test_timestamp_atKeyBoundaries() {
        assert(WebVTTExporter.timestamp(0) == "00:00:00.000", "0s should format as 00:00:00.000")
        assert(WebVTTExporter.timestamp(59.999) == "00:00:59.999", "59.999s should format as 00:00:59.999")
        assert(WebVTTExporter.timestamp(3600) == "01:00:00.000", "3600s should roll over to 01:00:00.000")
        assert(WebVTTExporter.timestamp(5932) == "01:38:52.000", "5932s should format as 01:38:52.000")
    }

    static func test_escape_ampersandLessGreaterAndArrow() {
        let escaped = WebVTTExporter.escape("A & B <tag> x-->y")
        assert(escaped == "A &amp; B &lt;tag&gt; x-&gt;y", "escape() produced unexpected output: \(escaped)")
    }

    static func test_diarized_twoSegmentRoundTrip() {
        let segments = [
            SpeakerTimelineSegment(
                speakerLabel: "Speaker 1",
                startSec: 0,
                endSec: 12.34,
                text: "Hi everyone, thanks for joining the call today."
            ),
            SpeakerTimelineSegment(
                speakerLabel: "Vineet",
                startSec: 12.34,
                endSec: 20.1,
                text: "From my side, the backend work is nearly complete."
            ),
        ]
        let out = WebVTTExporter.vtt(segments: segments)
        assert(out.hasPrefix("WEBVTT\n\n"), "diarized vtt must start with WEBVTT header")
        assert(out.contains("00:00:00.000 --> 00:00:12.340"), "missing first cue timestamp")
        assert(out.contains("<v Speaker 1>Hi everyone, thanks for joining the call today."), "missing first cue voice line")
        assert(out.contains("00:00:12.340 --> 00:00:20.100"), "missing second cue timestamp")
        assert(out.contains("<v Vineet>From my side, the backend work is nearly complete."), "missing second cue voice line")
        // Cue index lines present and ordered.
        assert(out.contains("1\n00:00:00.000"), "missing cue index 1 immediately before its timestamp")
        assert(out.contains("2\n00:00:12.340"), "missing cue index 2 immediately before its timestamp")
    }

    static func test_nonDiarized_singleCueFallback() {
        let out = WebVTTExporter.vtt(fullTranscript: "Just one speaker talking the whole time.", durationSec: 42.5)
        assert(out.hasPrefix("WEBVTT\n\n"), "fallback vtt must start with WEBVTT header")
        assert(out.contains("00:00:00.000 --> 00:00:42.500"), "fallback cue span is wrong")
        assert(!out.contains("<v "), "fallback single cue must not carry a voice tag")
        assert(out.contains("Just one speaker talking the whole time."), "fallback cue missing transcript text")
    }
}
#endif
