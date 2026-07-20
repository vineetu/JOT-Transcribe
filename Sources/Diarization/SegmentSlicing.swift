import Foundation

/// Segment-sliced transcription for diarized imports
/// (docs/speaker-diarization/design.md follow-up): instead of transcribing the
/// whole file once and distributing the flat text across speaker runs
/// proportionally-by-time (a guess — Nemotron emits no word timings, so the
/// owner-verified failure mode is text landing on the wrong speaker), the
/// diarized path transcribes EACH coalesced speaker run's own audio slice.
/// Attribution becomes exact by construction: a run's text can only come from
/// that run's audio.
///
/// Pure geometry (`sliceBounds` / `sampleRange` / `joinedTranscript`) is kept
/// separate from the async driver (`transcribeRuns`) so the DEBUG harness
/// (`SegmentSlicingTests`) can exercise the math without an engine.
enum SegmentSlicing {

    /// Context pad on each side of a run's diarizer boundary. VBx boundaries
    /// are frame-quantized and can shave the first/last phoneme; ±0.2s
    /// recovers word edges without pulling in a meaningful amount of the
    /// neighbor's speech.
    static let padSeconds: Double = 0.2

    /// Runs shorter than this are NOT transcribed alone — they stay in the
    /// timeline with EMPTY text (the display layer already drops empty-text
    /// blocks — `SpeakerTimelineBuilder.coalesceDisplayRuns`). Policy choice
    /// (vs. merging the short run's audio into an adjacent longer run's
    /// slice): (a) the engines reject sub-1s buffers as `.audioTooShort`
    /// anyway, so pad-inclusive slices need a floor near 1s regardless;
    /// (b) merging a short run's audio into a NEIGHBOR's slice would hand its
    /// words to the wrong speaker — exactly the mis-attribution bug this
    /// whole path exists to fix; (c) a post-coalescing run this short is
    /// almost always a backchannel ("yeah", "mm-hm") with negligible content.
    /// Dropping ~a word of backchannel beats mis-attributing it.
    static let minRunSeconds: Double = 1.2

    /// Canonical pipeline rate (`AudioFormat.sampleRate`).
    static let sampleRate: Double = 16_000

    /// Half-open slice window in seconds.
    struct Bounds: Equatable {
        var startSec: Double
        var endSec: Double
    }

    /// Padded, non-overlapping slice bounds for the coalesced runs.
    ///
    /// - Each run is padded ±`padSeconds`, clamped to `[0, duration]`.
    /// - A pad never crosses into the NEXT/PREVIOUS run's pad: when the gap
    ///   between two runs is smaller than `2 * padSeconds`, the gap is split
    ///   at its midpoint (a zero gap yields slices that meet exactly at the
    ///   shared boundary; a defensively-clamped negative gap yields the runs'
    ///   own boundaries). So for non-overlapping input runs, slices never
    ///   overlap — no word can be transcribed into two runs.
    /// - Runs shorter than `minRunSeconds` get `nil` (empty-text policy, see
    ///   above). Their audio is NOT absorbed by neighbors: neighbor pads are
    ///   computed against the short run's real boundaries regardless.
    static func sliceBounds(
        runs: [(start: Double, end: Double)],
        duration: Double
    ) -> [Bounds?] {
        guard !runs.isEmpty else { return [] }
        var out: [Bounds?] = []
        out.reserveCapacity(runs.count)
        for (i, run) in runs.enumerated() {
            guard run.end - run.start >= minRunSeconds else {
                out.append(nil)
                continue
            }
            var start = run.start - padSeconds
            var end = run.end + padSeconds
            if i > 0 {
                let gap = run.start - runs[i - 1].end
                if gap < 2 * padSeconds {
                    start = run.start - max(0, gap) / 2
                }
            }
            if i < runs.count - 1 {
                let gap = runs[i + 1].start - run.end
                if gap < 2 * padSeconds {
                    end = run.end + max(0, gap) / 2
                }
            }
            start = max(0, start)
            end = min(duration, end)
            out.append(end > start ? Bounds(startSec: start, endSec: end) : nil)
        }
        return out
    }

    /// Sample-index window for `bounds`, clamped to `0..<sampleCount` and
    /// guaranteed non-inverted.
    static func sampleRange(_ bounds: Bounds, sampleCount: Int) -> Range<Int> {
        let lo = max(0, min(sampleCount, Int((bounds.startSec * sampleRate).rounded())))
        let hi = max(lo, min(sampleCount, Int((bounds.endSec * sampleRate).rounded())))
        return lo..<hi
    }

    /// The diarized recording's PLAIN transcript: the runs' texts joined with
    /// blank lines — speaker changes read as natural paragraph breaks. Empty
    /// slices (short runs, `.audioTooShort` slivers) are skipped.
    static func joinedTranscript(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Async driver

    /// Transcribe one slice's already-decoded 16 kHz mono samples into
    /// cleaned text. Implementations must apply the SAME post-processing the
    /// whole-file import path applies (see `sliceTranscriber(using:)`).
    typealias SliceTranscribe = @Sendable ([Float]) async throws -> String

    /// Transcribe each run's slice sequentially (the engines are
    /// single-in-flight — parallel slices would just trip their own `.busy`
    /// guard). Returns one text per run, `""` for short runs.
    ///
    /// Error contract: `.audioTooShort` on an individual slice degrades that
    /// slice to `""`; cancellation and every other error (including
    /// `TranscriberError.busy`) propagate to the caller, which decides
    /// between parking the job and falling back to proportional distribution.
    static func transcribeRuns(
        runs: [(speakerId: String, start: Double, end: Double)],
        samples: [Float],
        transcribe: SliceTranscribe
    ) async throws -> [String] {
        let duration = Double(samples.count) / sampleRate
        let bounds = sliceBounds(runs: runs.map { ($0.start, $0.end) }, duration: duration)
        var texts: [String] = []
        texts.reserveCapacity(bounds.count)
        for b in bounds {
            try Task.checkCancellation()
            guard let b else {
                texts.append("")
                continue
            }
            let range = sampleRange(b, sampleCount: samples.count)
            // Engines reject sub-1s buffers (`.audioTooShort`) — don't even
            // dispatch a sliver (possible only via end-of-file clamping).
            guard range.count >= Int(sampleRate) else {
                texts.append("")
                continue
            }
            do {
                texts.append(try await transcribe(Array(samples[range])))
            } catch TranscriberError.audioTooShort {
                texts.append("")
            }
        }
        return texts
    }

    // The production `SliceTranscribe` factory over the active engine lives
    // in `SegmentSlicingTranscriber.swift` — kept separate so THIS file has
    // no engine-type dependencies (Foundation + `TranscriberError` only) and
    // can be compiled verbatim into standalone verification probes
    // (`tools/diarize-slice-probe`).
}
