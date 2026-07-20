#if DEBUG
import FluidAudio
import Foundation

/// DEBUG-only runtime tests for the diarization timeline pipeline —
/// `SpeakerTimelineBuilder.distributeText` sentence snapping,
/// `DiarizationTimelineBuilder` run coalescing / isolated-segment smoothing /
/// phantom re-fold, and the render-time display grouping. Same
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
        test_smoothing_isolatedShortFlipReassigned()
        test_smoothing_alternatingDialogueUntouched()
        test_smoothing_allShortAlternationUnchanged()
        test_smoothing_thenPhantomFoldRemovesEmptiedSpeaker()
        test_buildPayloadCore_singleSpeakerAfterSmoothingReturnsNil()
        test_repro_48SegmentsThreeSpeakers()
    }

    // MARK: - Helpers

    private static func timed(
        _ id: String, _ start: Double, _ end: Double, q: Float = 0.8
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: id,
            embedding: [],
            startTimeSeconds: Float(start),
            endTimeSeconds: Float(end),
            qualityScore: q
        )
    }

    // MARK: - FIX 1: run coalescing

    static func test_coalesce_sameSpeakerRunsAcrossGaps() {
        // Three same-speaker segments separated by 2-5s natural pauses (well
        // above mergeAdjacent's 0.5s tolerance) must collapse to ONE.
        let spans: [(speakerId: String, start: Double, end: Double)] = [
            ("A", 0, 8), ("A", 10, 20), ("A", 25, 40),
        ]
        let out = DiarizationTimelineBuilder.coalesceSameSpeakerRuns(spans)
        assert(out.count == 1, "3 same-speaker segments should coalesce to 1, got \(out.count)")
        assert(out[0].start == 0 && out[0].end == 40, "coalesced span should cover 0-40")

        // A speaker change still breaks the run.
        let mixed: [(speakerId: String, start: Double, end: Double)] = [
            ("A", 0, 8), ("B", 9, 14), ("A", 15, 20),
        ]
        let out2 = DiarizationTimelineBuilder.coalesceSameSpeakerRuns(mixed)
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

    // MARK: - FIX 3: isolated-segment smoothing

    static func test_smoothing_isolatedShortFlipReassigned() {
        // 2s flip to B between two agreeing A neighbors, low quality → A.
        let segs = [
            timed("A", 0, 10, q: 0.9),
            timed("B", 10, 12, q: 0.2),
            timed("A", 12, 20, q: 0.9),
        ]
        let out = DiarizationTimelineBuilder.smoothIsolatedSegments(segs)
        assert(out.allSatisfy { $0.speakerId == "A" }, "isolated low-quality flip should be reassigned to A")
    }

    static func test_smoothing_alternatingDialogueUntouched() {
        // Legitimate 10s/8s/12s alternation — nothing is short, nothing moves.
        let dialogue = [
            timed("A", 0, 10), timed("B", 10, 18), timed("A", 18, 30),
        ]
        let out = DiarizationTimelineBuilder.smoothIsolatedSegments(dialogue)
        assert(out.map(\.speakerId) == ["A", "B", "A"], "long alternating dialogue must not be smoothed")

        // Short middle segment but DISAGREEING neighbors → untouched.
        let threeWay = [
            timed("A", 0, 10), timed("B", 10, 13), timed("C", 13, 20),
        ]
        let out2 = DiarizationTimelineBuilder.smoothIsolatedSegments(threeWay)
        assert(out2.map(\.speakerId) == ["A", "B", "C"], "disagreeing neighbors must not trigger smoothing")

        // Run of TWO short same-speaker segments — neighbors of each include
        // the other B, so the run survives (no cascade by design).
        let shortRun = [
            timed("A", 0, 10), timed("B", 10, 13), timed("B", 13.5, 16), timed("A", 16, 26),
        ]
        let out3 = DiarizationTimelineBuilder.smoothIsolatedSegments(shortRun)
        assert(out3.map(\.speakerId) == ["A", "B", "B", "A"], "a short same-speaker RUN must not be smoothed away")
    }

    static func test_smoothing_allShortAlternationUnchanged() {
        // Adversarial-review counterexample (F2): all-short genuine
        // alternation A/B/A/B with uniform scores. Without the long-neighbor
        // requirement the two middle turns SWAP speakers (each sees agreeing
        // ORIGINAL neighbors). Must come through unchanged.
        let segs = [
            timed("A", 0, 3), timed("B", 3, 6), timed("A", 6, 9), timed("B", 9, 12),
        ]
        let out = DiarizationTimelineBuilder.smoothIsolatedSegments(segs)
        assert(out.map(\.speakerId) == ["A", "B", "A", "B"], "all-short alternation must not be smoothed/swapped, got \(out.map(\.speakerId))")
    }

    static func test_smoothing_thenPhantomFoldRemovesEmptiedSpeaker() {
        // B originally totals 8s (above the 6s floor). Smoothing flips its
        // isolated 3s low-quality segment to A, dropping B to 5s — the
        // phantom fold (running AFTER smoothing) must then fold B entirely.
        let segs = [
            timed("A", 0, 10, q: 0.9),
            timed("B", 10, 13, q: 0.1),
            timed("A", 13, 20, q: 0.9),
            timed("B", 20, 25, q: 0.9),
        ]
        let smoothed = DiarizationTimelineBuilder.smoothIsolatedSegments(segs)
        let folded = DiarizationTimelineBuilder.foldPhantomSpeakers(smoothed)
        assert(folded.allSatisfy { $0.speakerId == "A" }, "speaker emptied below the 6s floor by smoothing must fold away")
    }

    static func test_buildPayloadCore_singleSpeakerAfterSmoothingReturnsNil() {
        // F3: a "secondary" made of two isolated 3.5s low-quality flips
        // totals 7s — enough to pass the multiSpeaker gate — but smoothing
        // reassigns both and the fold collapses to one speaker. The payload
        // must be nil (designed "Single speaker" path), never a one-label
        // payload that would toast "Labeled 1 speakers.".
        let segs = [
            timed("A", 0, 10, q: 0.9),
            timed("B", 10, 13.5, q: 0.1),
            timed("A", 13.5, 25, q: 0.9),
            timed("B", 25, 28.5, q: 0.1),
            timed("A", 28.5, 40, q: 0.9),
        ]
        // Confirm the shape would clear the D7 gate (largest secondary ≥ 6s).
        let totals = DiarizationTimelineBuilder.perSpeakerSeconds(segs)
        let largestSecondary = totals.values.sorted(by: >).dropFirst().first ?? 0
        assert(largestSecondary >= DiarizationTimelineBuilder.minSecondarySeconds, "test shape must pass the multiSpeaker gate, secondary = \(largestSecondary)")

        let payload = DiarizationTimelineBuilder.buildPayloadCore(
            segments: segs,
            transcript: "Some words spoken here. More words follow after that.",
            duration: 40
        )
        assert(payload == nil, "single-speaker collapse after smoothing must return nil, got \(String(describing: payload?.segments.map(\.speakerLabel)))")
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
        var raw: [TimedSpeakerSegment] = []
        var t = 0.0
        for (speaker, count) in runs {
            for _ in 0..<count {
                raw.append(timed(speaker, t, t + 5))
                t += 8 // 5s speech + 3s pause
            }
        }
        assert(raw.count == 48, "repro shape must have 48 segments")

        // Same pipeline order as buildPayload.
        let smoothed = DiarizationTimelineBuilder.smoothIsolatedSegments(raw)
        let folded = DiarizationTimelineBuilder.foldPhantomSpeakers(smoothed)
        let merged = DiarizationTimelineBuilder.coalesceSameSpeakerRuns(
            DiarizationTimelineBuilder.mergeAdjacent(folded)
        )
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
