#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the segment-sliced transcription math —
/// `SegmentSlicing.sliceBounds` padding/clamping/gap-splitting, the
/// short-run empty-text policy, `sampleRange` clamping, the joined-transcript
/// builder, and `DiarizationTimelineBuilder.slicedPayload` text mapping.
/// Same `assert()`-in-`#if DEBUG` idiom as `SpeakerTimelineTests` — run once
/// at startup via `runAll()`, stripped from release builds.
enum SegmentSlicingTests {

    @MainActor
    static func runAll() {
        test_bounds_padsAppliedWhenGapsAreWide()
        test_bounds_clampAtFileEdges()
        test_bounds_narrowGapSplitsAtMidpoint()
        test_bounds_zeroGapMeetsAtSharedBoundary()
        test_bounds_shortRunGetsNilAndIsNotAbsorbed()
        test_bounds_noOverlapInvariant()
        test_sampleRange_clampsAndNeverInverts()
        test_joinedTranscript_skipsEmpties()
        test_slicedPayload_mapsTextPerRun()
        test_transcribeRuns_shortRunsSkippedOthersSliced()
    }

    // MARK: - sliceBounds

    static func test_bounds_padsAppliedWhenGapsAreWide() {
        // Gap of 2s ≫ 0.4s → both runs get the full ±0.2s pad.
        let out = SegmentSlicing.sliceBounds(runs: [(1.0, 10.0), (12.0, 20.0)], duration: 30)
        assert(out.count == 2)
        assert(out[0] == .init(startSec: 0.8, endSec: 10.2), "full pad expected, got \(String(describing: out[0]))")
        assert(out[1] == .init(startSec: 11.8, endSec: 20.2), "full pad expected, got \(String(describing: out[1]))")
    }

    static func test_bounds_clampAtFileEdges() {
        // Run starts 0.1s in → left pad clamps at 0. Run ends 0.05s before
        // EOF → right pad clamps at duration.
        let out = SegmentSlicing.sliceBounds(runs: [(0.1, 5.0), (7.0, 9.95)], duration: 10.0)
        assert(out[0]?.startSec == 0, "left pad must clamp at 0, got \(String(describing: out[0]))")
        assert(out[1]?.endSec == 10.0, "right pad must clamp at duration, got \(String(describing: out[1]))")
    }

    static func test_bounds_narrowGapSplitsAtMidpoint() {
        // Gap of 0.2s < 0.4s → split at midpoint: slice 0 ends at 10.1,
        // slice 1 starts at 10.1 — contiguous, zero overlap.
        let out = SegmentSlicing.sliceBounds(runs: [(0.0, 10.0), (10.2, 20.0)], duration: 30)
        assert(abs((out[0]?.endSec ?? -1) - 10.1) < 1e-9, "narrow gap must split at midpoint, got \(String(describing: out[0]))")
        assert(abs((out[1]?.startSec ?? -1) - 10.1) < 1e-9, "narrow gap must split at midpoint, got \(String(describing: out[1]))")
    }

    static func test_bounds_zeroGapMeetsAtSharedBoundary() {
        // Back-to-back runs (gap 0) → no pad crosses the boundary at all.
        let out = SegmentSlicing.sliceBounds(runs: [(0.0, 10.0), (10.0, 20.0)], duration: 20)
        assert(out[0]?.endSec == 10.0, "zero gap: slice must end at the run boundary")
        assert(out[1]?.startSec == 10.0, "zero gap: slice must start at the run boundary")
    }

    static func test_bounds_shortRunGetsNilAndIsNotAbsorbed() {
        // Middle run is 1.0s < 1.2s → nil (empty-text policy). Its audio must
        // NOT be absorbed by the neighbors: their pads still stop at the
        // short run's real boundaries (gaps here are 0.5s ≥ 0.4s → full pad).
        let out = SegmentSlicing.sliceBounds(runs: [(0.0, 10.0), (10.5, 11.5), (12.0, 25.0)], duration: 25)
        assert(out[1] == nil, "sub-1.2s run must get nil bounds")
        assert(out[0]?.endSec == 10.2, "neighbor pad must not swallow the short run, got \(String(describing: out[0]))")
        assert(out[2]?.startSec == 11.8, "neighbor pad must not swallow the short run, got \(String(describing: out[2]))")
        assert((out[0]?.endSec ?? .infinity) <= 10.5 && (out[2]?.startSec ?? -1) >= 11.5,
               "no neighbor slice may overlap the short run's own audio")
    }

    static func test_bounds_noOverlapInvariant() {
        // Mixed gaps (wide / narrow / zero / short-run) — consecutive
        // non-nil slices must never overlap for non-overlapping input runs.
        let runs: [(start: Double, end: Double)] = [
            (0.5, 8.0), (8.1, 15.0), (15.0, 22.0), (24.0, 24.9), (25.0, 40.0), (43.0, 60.0),
        ]
        let out = SegmentSlicing.sliceBounds(runs: runs, duration: 60.1)
        var previousEnd = -Double.infinity
        for bounds in out {
            guard let bounds else { continue }
            assert(bounds.endSec > bounds.startSec, "slice must be non-empty")
            assert(bounds.startSec >= previousEnd - 1e-9,
                   "slices overlap: \(bounds.startSec) < \(previousEnd)")
            previousEnd = bounds.endSec
        }
    }

    // MARK: - sampleRange

    static func test_sampleRange_clampsAndNeverInverts() {
        // Beyond-EOF bounds clamp to sampleCount; never inverted.
        let r1 = SegmentSlicing.sampleRange(.init(startSec: 0.5, endSec: 99), sampleCount: 32_000)
        assert(r1 == 8_000..<32_000, "range must clamp to sampleCount, got \(r1)")
        let r2 = SegmentSlicing.sampleRange(.init(startSec: 5, endSec: 6), sampleCount: 16_000)
        assert(r2.isEmpty, "fully-beyond-EOF bounds must yield an empty range, got \(r2)")
        let r3 = SegmentSlicing.sampleRange(.init(startSec: 0, endSec: 1), sampleCount: 32_000)
        assert(r3 == 0..<16_000, "1s at 16k must be 16000 samples, got \(r3)")
    }

    // MARK: - joinedTranscript

    static func test_joinedTranscript_skipsEmpties() {
        let joined = SegmentSlicing.joinedTranscript(["First turn.", "", "  ", "Second turn.", "Third."])
        assert(joined == "First turn.\n\nSecond turn.\n\nThird.",
               "empties must be skipped and turns joined with blank lines, got: \(joined)")
        assert(SegmentSlicing.joinedTranscript(["", "  "]).isEmpty, "all-empty must join to empty")
    }

    // MARK: - slicedPayload

    static func test_slicedPayload_mapsTextPerRun() {
        // A/B/A runs with per-run texts — labels number by first appearance
        // and each run keeps ITS OWN text (no distribution).
        let merged: [(speakerId: String, start: Double, end: Double)] = [
            ("spk_b", 0, 10), ("spk_a", 11, 14), ("spk_b", 15, 30),
        ]
        let payload = DiarizationTimelineBuilder.slicedPayload(
            merged: merged,
            texts: ["Opening remarks here.", "A quick question?", "The long answer follows."]
        )
        assert(payload.segments.count == 3)
        assert(payload.segments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"],
               "first-appearance numbering lost: \(payload.segments.map(\.speakerLabel))")
        assert(payload.segments[0].text == "Opening remarks here.")
        assert(payload.segments[1].text == "A quick question?")
        assert(payload.segments[2].text == "The long answer follows.")
        assert(payload.segments[1].startSec == 11 && payload.segments[1].endSec == 14,
               "time bounds must be the run's own bounds")
    }

    // MARK: - transcribeRuns (async driver, fake engine)

    /// Semaphore-bridged result slot — signal/wait gives the happens-before
    /// edge, so the unguarded fields are safe for this DEBUG-only test.
    private final class ResultBox: @unchecked Sendable {
        var texts: [String] = []
        var error: Error?
    }

    static func test_transcribeRuns_shortRunsSkippedOthersSliced() {
        // Fake engine: echoes the slice length so the test can verify each
        // run got its OWN padded window and short runs were never dispatched.
        // The driver runs to completion SYNCHRONOUSLY (semaphore over a
        // detached task) so a failing assert can never be skipped by app
        // startup racing an un-awaited Task. Safe to block the main thread
        // here: the driver and the fake engine never touch any actor.
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            let samples = [Float](repeating: 0, count: 30 * 16_000) // 30s
            let runs: [(speakerId: String, start: Double, end: Double)] = [
                ("A", 1.0, 10.0),   // sliced 0.8–10.2 → 9.4s
                ("B", 10.5, 11.5),  // short → "" (never dispatched)
                ("A", 12.0, 29.9),  // sliced 11.8–30.0 (right pad clamps) → 18.2s
            ]
            do {
                box.texts = try await SegmentSlicing.transcribeRuns(
                    runs: runs,
                    samples: samples,
                    transcribe: { slice in "len=\(slice.count)" }
                )
            } catch {
                box.error = error
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            assertionFailure("transcribeRuns test timed out")
            return
        }
        assert(box.error == nil, "transcribeRuns threw unexpectedly: \(String(describing: box.error))")
        let texts = box.texts
        assert(texts.count == 3, "expected 3 texts, got \(texts.count)")
        assert(texts[0] == "len=\(Int(9.4 * 16_000))", "run 0 slice window wrong: \(texts[0])")
        assert(texts[1].isEmpty, "short run must yield empty text without dispatching")
        assert(texts[2] == "len=\(Int(18.2 * 16_000))", "run 2 slice window wrong: \(texts[2])")
    }
}
#endif
