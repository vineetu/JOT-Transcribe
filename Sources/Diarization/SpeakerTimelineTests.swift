#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the diarization timeline pipeline —
/// `DiarizationProjection` (frame projection, solo gate, phantom fold, run
/// coalescing, gap fill, short-run fold), `SpeakerTimelineBuilder.distributeText`
/// sentence snapping, and the render-time display grouping. Same
/// `assert()`-in-`#if DEBUG` idiom as `WebVTTExporterTests` — the app target
/// doesn't link XCTest, so these run once at startup via `runAll()` and are
/// stripped from release builds.
enum SpeakerTimelineTests {

    @MainActor
    static func runAll() {
        test_coalesce_sameSpeakerRunsAcrossGaps()
        test_coalesce_displayRunsGroupsPersistedSegments()
        test_snap_boundaryMovesToNearestSentenceEnd()
        test_snap_punctuationFreeKeepsProportionalSplit()
        test_snap_distanceCapRespected()
        test_snap_neverEmptiesTrailingSegment()
        test_snap_forwardSnapCannotEmptyFollowingSegment()
        test_isSentenceEnd_abbreviationsAndInitials()
        test_projection_argmaxAboveThresholdOwnsFrame()
        test_projection_recordsCoSpeaker()
        test_projection_emptyAndSilentInput()
        test_gapFill_tilesWholeDurationAtMidpoints()
        test_foldShortRuns_prefersCoSpeakerThenLongerNeighbor()
        test_foldShortRuns_leavesLoneRunAlone()
        test_phantomFold_relabelsBelowFloorSpeaker()
        test_speakerRuns_soloGateReturnsNil()
        test_speakerRuns_gapFreeAndNoRunBelowSlicingFloor()
        test_speakerRuns_shortRealTurnsFoldToSingleSpeakerReturnsNil()
        test_repro_48SegmentsThreeSpeakers()
    }

    // MARK: - Helpers

    private static func seg(
        _ id: String, _ start: Double, _ end: Double, co: String? = nil
    ) -> DiarSegment {
        DiarSegment(speakerId: id, start: start, end: end, coSpeakerId: co)
    }

    /// `[frames * 8]` probability matrix where `rows[f]` lists the
    /// `(slot, p)` pairs active in frame `f`; every other cell is 0.
    private static func probabilities(_ rows: [[(Int, Float)]]) -> [Float] {
        var out = [Float](repeating: 0, count: rows.count * 8)
        for (f, row) in rows.enumerated() {
            for (slot, p) in row { out[f * 8 + slot] = p }
        }
        return out
    }

    // MARK: - FIX 1: run coalescing

    static func test_coalesce_sameSpeakerRunsAcrossGaps() {
        // Three same-speaker segments separated by 2-5s natural pauses (well
        // above mergeAdjacent's 0.5s tolerance) must collapse to ONE.
        let spans = [seg("A", 0, 8), seg("A", 10, 20), seg("A", 25, 40)]
        let out = DiarizationProjection.coalesceSameSpeakerRuns(spans)
        assert(out.count == 1, "3 same-speaker segments should coalesce to 1, got \(out.count)")
        assert(out[0].start == 0 && out[0].end == 40, "coalesced span should cover 0-40")

        // A speaker change still breaks the run.
        let mixed = [seg("A", 0, 8), seg("B", 9, 14), seg("A", 15, 20)]
        let out2 = DiarizationProjection.coalesceSameSpeakerRuns(mixed)
        assert(out2.count == 3, "A/B/A must stay 3 runs, got \(out2.count)")
    }

    static func test_coalesce_displayRunsGroupsPersistedSegments() {
        // Old persisted payloads carry fine-grained segments — the view-level
        // grouping must merge consecutive same-label ones and drop empties.
        let segments = [
            SpeakerTimelineSegment(speakerLabel: "Speaker 1", startSec: 0, endSec: 5, text: "First part."),
            SpeakerTimelineSegment(speakerLabel: "Speaker 1", startSec: 8, endSec: 12, text: "Second part."),
            SpeakerTimelineSegment(speakerLabel: "Speaker 1", startSec: 15, endSec: 20, text: ""),
            SpeakerTimelineSegment(speakerLabel: "Speaker 2", startSec: 21, endSec: 25, text: "Reply."),
            SpeakerTimelineSegment(speakerLabel: "Speaker 1", startSec: 26, endSec: 30, text: "Closing."),
        ]
        let out = SpeakerTimelineBuilder.coalesceDisplayRuns(segments)
        assert(out.count == 3, "display grouping should yield 3 blocks, got \(out.count)")
        assert(out[0].text == "First part. Second part.", "grouped text wrong: \(out[0].text)")
        // The empty segment is dropped entirely — its span is not absorbed.
        assert(out[0].startSec == 0 && out[0].endSec == 12, "grouped span should be 0-12")
        assert(out[1].speakerLabel == "Speaker 2" && out[2].speakerLabel == "Speaker 1", "run order lost")
    }

    // MARK: - FIX 2: sentence-boundary snapping

    static func test_snap_boundaryMovesToNearestSentenceEnd() {
        // 13 words, sentence end after word 3. Proportional boundary lands at
        // word 6 (mid-sentence) and must snap back to 3.
        let transcript = "Hello there everyone. This is a test sentence spoken by the second person."
        let segments = [
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 1", startSec: 0, endSec: 6),
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 2", startSec: 6, endSec: 13),
        ]
        let out = SpeakerTimelineBuilder.distributeText(transcript: transcript, duration: 13, segments: segments)
        assert(out.count == 2)
        assert(out[0].text == "Hello there everyone.", "boundary should snap to the period, got: \(out[0].text)")
        assert(out[1].text.hasPrefix("This is a test"), "second segment should start the next sentence, got: \(out[1].text)")
    }

    static func test_snap_punctuationFreeKeepsProportionalSplit() {
        // No sentence punctuation → identical to the pre-snapping
        // proportional behavior (6/7 word split for 6s/7s segments).
        let words = (1...13).map { "word\($0)" }
        let transcript = words.joined(separator: " ")
        let segments = [
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 1", startSec: 0, endSec: 6),
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 2", startSec: 6, endSec: 13),
        ]
        let out = SpeakerTimelineBuilder.distributeText(transcript: transcript, duration: 13, segments: segments)
        assert(out[0].text == words[0..<6].joined(separator: " "), "punctuation-free split changed: \(out[0].text)")
        assert(out[1].text == words[6...].joined(separator: " "), "punctuation-free remainder changed")
    }

    static func test_snap_distanceCapRespected() {
        // Only sentence end is after word 5; proportional boundary is at 25.
        // Distance 20 > cap 15 → boundary must NOT move.
        var words = (1...40).map { "word\($0)" }
        words[4] = "word5."
        let transcript = words.joined(separator: " ")
        let segments = [
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 1", startSec: 0, endSec: 25),
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 2", startSec: 25, endSec: 40),
        ]
        let out = SpeakerTimelineBuilder.distributeText(transcript: transcript, duration: 40, segments: segments)
        let firstCount = out[0].text.split(separator: " ").count
        assert(firstCount == 25, "snap crossed the 15-word cap: first segment has \(firstCount) words")
    }

    static func test_snap_neverEmptiesTrailingSegment() {
        // 20 words, every word period-free except the final one. The only
        // sentence end is the transcript's end — an internal boundary must
        // NOT snap there (that would swallow speaker 2 entirely).
        var words = (1...20).map { "word\($0)" }
        words[19] = "word20."
        let transcript = words.joined(separator: " ")
        let segments = [
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 1", startSec: 0, endSec: 15),
            SpeakerTimelineBuilder.LabeledSegment(label: "Speaker 2", startSec: 15, endSec: 20),
        ]
        let out = SpeakerTimelineBuilder.distributeText(transcript: transcript, duration: 20, segments: segments)
        assert(!out[1].text.isEmpty, "trailing speaker was emptied by snapping to the final period")
        assert(out[0].text.split(separator: " ").count == 15, "boundary should stay proportional at 15")
    }

    static func test_snap_forwardSnapCannotEmptyFollowingSegment() {
        // Adversarial-review counterexample (F1): 30 words, only sentence
        // end at word 20, segments A(10w)/B(1w)/A(19w) → coarse [10,11,30].
        // Without the next-coarse-boundary bound, boundary 1 snaps 10→20,
        // boundary 2 clamps to 20 → segment B empties and the speaker
        // vanishes from the labeled view. B must retain at least one word.
        var words = (1...30).map { "word\($0)" }
        words[19] = "word20."
        let transcript = words.joined(separator: " ")
        let segments = [
            SpeakerTimelineBuilder.LabeledSegment(label: "A", startSec: 0, endSec: 10),
            SpeakerTimelineBuilder.LabeledSegment(label: "B", startSec: 10, endSec: 11),
            SpeakerTimelineBuilder.LabeledSegment(label: "A", startSec: 11, endSec: 30),
        ]
        let out = SpeakerTimelineBuilder.distributeText(transcript: transcript, duration: 30, segments: segments)
        assert(out.count == 3)
        assert(!out[1].text.isEmpty, "forward snap emptied the following segment — speaker B vanished")
        let total = out.reduce(0) { $0 + $1.text.split(separator: " ").count }
        assert(total == 30, "words not conserved in F1 counterexample, got \(total)")
    }

    static func test_isSentenceEnd_abbreviationsAndInitials() {
        assert(SpeakerTimelineBuilder.isSentenceEnd("done."), "plain period should end a sentence")
        assert(SpeakerTimelineBuilder.isSentenceEnd("really?"), "question mark should end a sentence")
        assert(SpeakerTimelineBuilder.isSentenceEnd("stop!"), "exclamation should end a sentence")
        assert(SpeakerTimelineBuilder.isSentenceEnd("done.\""), "trailing quote after period should still end")
        assert(SpeakerTimelineBuilder.isSentenceEnd("wait..."), "ASCII ellipsis should end a sentence")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("Dr."), "abbreviation must not end a sentence")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("J."), "single-letter initial must not end a sentence")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("u.s."), "dotted acronym must not end a sentence")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("word"), "bare word must not end a sentence")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("3.5"), "decimal number must not end a sentence")
        assert(SpeakerTimelineBuilder.isSentenceEnd("no."), "\"The answer is no.\" is a legitimate sentence end")
        assert(!SpeakerTimelineBuilder.isSentenceEnd("3.", next: "mai"), "ordinal before lowercase continuation must not end a sentence")
        assert(SpeakerTimelineBuilder.isSentenceEnd("3.", next: "Then"), "number+period before a capitalized word stays a sentence end")
        assert(SpeakerTimelineBuilder.isSentenceEnd("42."), "number+period with no continuation ends a sentence")
    }

    // MARK: - Projection (D4)

    static func test_projection_argmaxAboveThresholdOwnsFrame() {
        // 0.00-0.03 slot 0 alone; 0.03-0.05 both above 0.5 with slot 1
        // higher → slot 1 owns them; 0.05-0.06 nobody above 0.5 → silence;
        // 0.06-0.08 slot 1 alone.
        let rows: [[(Int, Float)]] = [
            [(0, 0.9)], [(0, 0.9)], [(0, 0.8)],
            [(0, 0.6), (1, 0.7)], [(0, 0.6), (1, 0.9)],
            [(0, 0.4), (1, 0.3)],
            [(1, 0.9)], [(1, 0.9)],
        ]
        let out = DiarizationProjection.project(
            probabilities: probabilities(rows), frameCount: rows.count, numSpeakers: 8)
        assert(out.map(\.speakerId) == ["S1", "S2", "S2"], "owners wrong: \(out.map(\.speakerId))")
        assert(abs(out[0].end - 0.03) < 1e-9 && abs(out[1].start - 0.03) < 1e-9, "overlap frames must go to the higher slot")
        assert(abs(out[1].end - 0.05) < 1e-9 && abs(out[2].start - 0.06) < 1e-9, "sub-threshold frame must be silence")
        assert(abs(out[2].end - 0.08) < 1e-9, "last run must end at the last frame")
        for pair in zip(out, out.dropFirst()) {
            assert(pair.0.end <= pair.1.start + 1e-9, "projected runs must never overlap")
        }
    }

    static func test_projection_recordsCoSpeaker() {
        // Slot 2 owns every frame; slot 5 is also above threshold in two of
        // them → it is the run's co-speaker. A run with no overlap has none.
        let rows: [[(Int, Float)]] = [
            [(2, 0.9)], [(2, 0.9), (5, 0.6)], [(2, 0.8), (5, 0.7)], [(2, 0.9)],
        ]
        let out = DiarizationProjection.project(
            probabilities: probabilities(rows), frameCount: rows.count, numSpeakers: 8)
        assert(out.count == 1 && out[0].speakerId == "S3", "one S3 run expected, got \(out)")
        assert(out[0].coSpeakerId == "S6", "co-speaker should be S6, got \(String(describing: out[0].coSpeakerId))")

        let solo = DiarizationProjection.project(
            probabilities: probabilities([[(0, 0.9)], [(0, 0.9)]]), frameCount: 2, numSpeakers: 8)
        assert(solo.first?.coSpeakerId == nil, "a run with no overlap must have no co-speaker")
    }

    static func test_projection_emptyAndSilentInput() {
        assert(DiarizationProjection.project(probabilities: [], frameCount: 0, numSpeakers: 8).isEmpty)
        let silent = probabilities(Array(repeating: [(0, 0.2)], count: 50))
        assert(DiarizationProjection.project(probabilities: silent, frameCount: 50, numSpeakers: 8).isEmpty,
               "all-below-threshold frames must project to no runs")
        // frameCount larger than the buffer must not read out of bounds.
        let short = probabilities([[(0, 0.9)]])
        assert(DiarizationProjection.project(probabilities: short, frameCount: 99, numSpeakers: 8).count == 1)
    }

    // MARK: - Gap fill + short-run fold (A1)

    static func test_gapFill_tilesWholeDurationAtMidpoints() {
        let runs = [seg("A", 2, 10), seg("B", 14, 20), seg("A", 21, 30)]
        let out = DiarizationProjection.gapFilled(runs, duration: 35)
        assert(out[0].start == 0, "leading silence must go to the first run")
        assert(out[0].end == 12 && out[1].start == 12, "4s gap must split at its midpoint (12)")
        assert(out[1].end == 20.5 && out[2].start == 20.5, "1s gap must split at its midpoint (20.5)")
        assert(out[2].end == 35, "trailing silence must go to the last run")
    }

    static func test_foldShortRuns_prefersCoSpeakerThenLongerNeighbor() {
        // 0.8s B turn between a long A and a shorter C, but C was also
        // talking over it → it folds into C, not the longer A.
        let withCo = [seg("A", 0, 20), seg("B", 20, 20.8, co: "C"), seg("C", 20.8, 25)]
        let out = DiarizationProjection.foldShortRuns(withCo)
        assert(out.map(\.speakerId) == ["A", "C"], "short run should fold into its co-speaker, got \(out.map(\.speakerId))")
        assert(out[1].start == 20, "C must absorb the short run's span")

        // No co-speaker → the longer neighbour wins.
        let noCo = [seg("A", 0, 20), seg("B", 20, 20.8), seg("C", 20.8, 25)]
        let out2 = DiarizationProjection.foldShortRuns(noCo)
        assert(out2.map(\.speakerId) == ["A", "C"] && out2[0].end == 20.8,
               "short run should fold into the longer neighbour, got \(out2)")

        // Folding into a neighbour that matches the run on the other side
        // re-coalesces them into one turn.
        let sandwich = [seg("A", 0, 10), seg("B", 10, 10.5), seg("A", 10.5, 20), seg("C", 20, 30)]
        let out3 = DiarizationProjection.foldShortRuns(sandwich)
        assert(out3.map(\.speakerId) == ["A", "C"] && out3[0].end == 20,
               "A/short-B/A must re-coalesce into one A turn, got \(out3)")
        assert(out3.allSatisfy { $0.duration >= DiarizationProjection.minRunSeconds })
    }

    static func test_foldShortRuns_leavesLoneRunAlone() {
        let out = DiarizationProjection.foldShortRuns([seg("A", 0, 0.5)])
        assert(out.count == 1, "a lone run has nowhere to fold and must survive")
    }

    // MARK: - Solo gate + phantom fold (D5)

    static func test_phantomFold_relabelsBelowFloorSpeaker() {
        // C totals 3s (< 6s floor) and sits nearer B → relabelled B.
        let segs = [seg("A", 0, 20), seg("C", 21, 24), seg("B", 24.5, 40)]
        let out = DiarizationProjection.foldPhantomSpeakers(segs)
        assert(out.map(\.speakerId) == ["A", "B", "B"], "phantom C should fold into nearer B, got \(out.map(\.speakerId))")
    }

    static func test_speakerRuns_soloGateReturnsNil() {
        // Largest secondary speaks 5s in total (two 2.5s bursts) — below the
        // 6s gate, so the recording is single-speaker.
        let segs = [seg("A", 0, 30), seg("B", 31, 33.5), seg("A", 34, 60), seg("B", 61, 63.5)]
        assert(!DiarizationProjection.multiSpeaker(segs), "5s secondary must not pass the 6s gate")
        assert(DiarizationProjection.speakerRuns(from: segs, duration: 65) == nil)
        let payload = DiarizationTimelineBuilder.buildPayloadCore(
            segments: segs, transcript: "Some words here.", duration: 65)
        assert(payload == nil, "solo recording must build no payload")
    }

    static func test_speakerRuns_gapFreeAndNoRunBelowSlicingFloor() {
        // Speech-only runs with silences, a 0.4s backchannel, and leading /
        // trailing silence. The result must tile [0, duration] exactly —
        // every second of audio lands in some slice — and no run may be
        // shorter than the slicer's empty-text floor.
        let segs = [
            seg("S1", 1.0, 12.0), seg("S2", 13.5, 25.0), seg("S1", 25.3, 25.7, co: "S2"),
            seg("S2", 26.0, 40.0), seg("S1", 44.0, 58.0),
        ]
        guard let runs = DiarizationProjection.speakerRuns(from: segs, duration: 61) else {
            assertionFailure("two real speakers must survive")
            return
        }
        assert(runs.first?.start == 0 && runs.last?.end == 61, "runs must cover 0…duration, got \(runs)")
        for pair in zip(runs, runs.dropFirst()) {
            assert(abs(pair.0.end - pair.1.start) < 1e-9, "runs must be contiguous: \(pair.0.end) vs \(pair.1.start)")
            assert(pair.0.speakerId != pair.1.speakerId, "adjacent runs must be different speakers")
        }
        assert(runs.allSatisfy { $0.duration >= SegmentSlicing.minRunSeconds }, "no run may fall below the slicing floor")
        assert(runs.map(\.speakerId) == ["S1", "S2", "S1"], "backchannel should fold into the S2 turn, got \(runs.map(\.speakerId))")

        // Every slice is transcribed (none nil) and together they tile the file.
        let bounds = SegmentSlicing.sliceBounds(runs: runs.map { ($0.start, $0.end) }, duration: 61)
        assert(bounds.allSatisfy { $0 != nil }, "gap-free runs must all be sliced")
        assert(bounds.first??.startSec == 0 && bounds.last??.endSec == 61, "slices must span the whole file")
    }

    static func test_speakerRuns_shortRealTurnsFoldToSingleSpeakerReturnsNil() {
        // B passes the 6s gate only in total — seven 1s turns, each shorter
        // than the slicing floor once gap-filled between long A turns. Every
        // B turn folds away, leaving one voice: that is the single-speaker
        // path, never a one-label payload ("Labeled 1 speakers.").
        var segs: [DiarSegment] = []
        var t = 0.0
        for _ in 0..<7 {
            segs.append(seg("A", t, t + 10))
            segs.append(seg("B", t + 10, t + 11))
            t += 11
        }
        assert(DiarizationProjection.multiSpeaker(segs), "shape must pass the gate")
        assert(DiarizationProjection.speakerRuns(from: segs, duration: t) == nil,
               "collapse to one speaker must return nil")
    }

    // MARK: - Repro-shaped end-to-end (48 segments / 3 speakers / 6 flips)

    static func test_repro_48SegmentsThreeSpeakers() {
        // Mirrors the persisted repro payload's shape (store row Z_PK 4333):
        // 48 segments, 42/4/2 across three speakers, 6 label-flip points —
        // i.e. runs S1x11, S2x2, S1x11, S3x2, S1x10, S2x2, S1x10. Segments
        // are 5s with 3s natural pauses (beyond mergeAdjacent's 0.5s).
        let runs: [(String, Int)] = [
            ("S1", 11), ("S2", 2), ("S1", 11), ("S3", 2), ("S1", 10), ("S2", 2), ("S1", 10),
        ]
        var raw: [DiarSegment] = []
        var t = 0.0
        for (speaker, count) in runs {
            for _ in 0..<count {
                raw.append(seg(speaker, t, t + 5))
                t += 8 // 5s speech + 3s pause
            }
        }
        assert(raw.count == 48, "repro shape must have 48 segments")

        // Same pipeline as `DiarizationTimelineBuilder.buildPayloadCore`.
        guard let merged = DiarizationProjection.speakerRuns(from: raw, duration: t) else {
            assertionFailure("repro shape must stay multi-speaker")
            return
        }
        assert(merged.count == 7, "48 repro segments should coalesce to 7 blocks, got \(merged.count)")
        let survivors = Set(merged.map(\.speakerId))
        assert(survivors == ["S1", "S2", "S3"], "all 3 real speakers must survive, got \(survivors)")

        // Distribute a sentence-punctuated transcript and confirm words are
        // conserved across the 7 blocks.
        var orderedIds: [String] = []
        for seg in merged where !orderedIds.contains(seg.speakerId) { orderedIds.append(seg.speakerId) }
        let labels = DiarizationTimelineBuilder.resolveLabels(orderedSpeakerIds: orderedIds)
        let labeled = merged.map {
            SpeakerTimelineBuilder.LabeledSegment(label: labels[$0.speakerId] ?? $0.speakerId, startSec: $0.start, endSec: $0.end)
        }
        let words = (1...240).map { i in i % 6 == 0 ? "word\(i)." : "word\(i)" }
        let payloadSegments = SpeakerTimelineBuilder.distributeText(
            transcript: words.joined(separator: " "), duration: t, segments: labeled
        )
        let totalOut = payloadSegments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        assert(totalOut == 240, "words must be conserved across blocks, got \(totalOut)")
        for seg in payloadSegments.dropLast() where !seg.text.isEmpty {
            assert(seg.text.hasSuffix("."), "every snapped block should end at a sentence boundary: …\(seg.text.suffix(12))")
        }
    }
}
#endif
