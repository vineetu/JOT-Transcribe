import Foundation

// SHARED FILE — compiled into BOTH the app and the `jot` CLI
// (`tools/jot-cli/Sources/jot/DiarizationProjection.swift` is a symlink to
// this file; `docs/speaker-diarization/nemotron-migration.md` A4). Keep it
// Foundation-only: no FluidAudio, no app types.

/// One exclusive speaker run on the recording's timeline, in seconds.
///
/// The Jot-owned shape of a diarizer result (design D3): nothing outside
/// `DiarizerHolder` / the CLI's `DiarizeEngine` sees FluidAudio's diarization
/// types. Runs never overlap — every downstream stage (coalescing,
/// `SegmentSlicing.sliceBounds`, the import transcript rewrite) assumes that.
struct DiarSegment: Equatable, Sendable {
    /// `"S<slot+1>"` — the diarizer's arrival-ordered speaker slot. Display
    /// labels ("Speaker N") are assigned later, by first appearance.
    var speakerId: String
    var start: Double
    var end: Double
    /// The speaker that was ALSO above threshold for most of this run's
    /// frames (overlapped speech), if any. Lets `foldShortRuns` hand a
    /// too-short run to the voice that was actually talking over it.
    var coSpeakerId: String?

    var duration: Double { end - start }
}

/// Frame probabilities → exclusive runs → the filtered, gap-free speaker
/// timeline. Pure and synchronous so the app's `DiarizationTimelineBuilder`
/// and the CLI run the exact same geometry (design D4, D5, A1).
enum DiarizationProjection {

    /// A slot is "speaking" in a frame when its probability clears this.
    static let activityThreshold: Float = 0.5

    /// Nemotron 3 emits one probability row per 10 ms.
    static let frameSeconds: Double = 0.01

    /// Solo gate + phantom floor (design D5). Absolute, not a fraction of
    /// the recording: a real 20-30 s second speaker after an hour of one
    /// voice must survive, while spurious slots stay well under 6 s.
    static let minSecondarySeconds: Double = 6.0

    /// Same-speaker runs separated by less than this are merged.
    static let mergeGapTolerance: Double = 0.5

    /// Shortest run the timeline may contain. Matches
    /// `SegmentSlicing.minRunSeconds`: the slicer gives shorter runs empty
    /// text, so a run this short would silently lose its words (A1).
    static let minRunSeconds: Double = 1.2

    static func speakerId(slot: Int) -> String { "S\(slot + 1)" }

    // MARK: - Projection (D4)

    /// Project per-frame probabilities (`[frameCount * numSpeakers]`,
    /// row-major) onto exclusive speech runs. Each frame belongs to the
    /// highest-probability slot among those above `activityThreshold`, or to
    /// nobody (silence). Contiguous same-owner frames form one run.
    static func project(
        probabilities: [Float],
        frameCount: Int,
        numSpeakers: Int
    ) -> [DiarSegment] {
        let frames = min(frameCount, numSpeakers > 0 ? probabilities.count / numSpeakers : 0)
        guard frames > 0 else { return [] }

        var out: [DiarSegment] = []
        var runOwner: Int?
        var runStart = 0
        var coCounts = [Int](repeating: 0, count: numSpeakers)

        func closeRun(at frame: Int) {
            guard let owner = runOwner else { return }
            var co: String?
            if let best = coCounts.indices.max(by: { coCounts[$0] < coCounts[$1] }),
               coCounts[best] > 0 {
                co = speakerId(slot: best)
            }
            out.append(DiarSegment(
                speakerId: speakerId(slot: owner),
                start: Double(runStart) * frameSeconds,
                end: Double(frame) * frameSeconds,
                coSpeakerId: co
            ))
        }

        for f in 0..<frames {
            let row = f * numSpeakers
            var owner: Int?
            var ownerP: Float = activityThreshold
            var runnerUp: Int?
            var runnerUpP: Float = activityThreshold
            for k in 0..<numSpeakers {
                let p = probabilities[row + k]
                if p > ownerP {
                    runnerUp = owner
                    runnerUpP = ownerP
                    owner = k
                    ownerP = p
                } else if p > runnerUpP {
                    runnerUp = k
                    runnerUpP = p
                }
            }
            if owner != runOwner {
                closeRun(at: f)
                runOwner = owner
                runStart = f
                coCounts = [Int](repeating: 0, count: numSpeakers)
            }
            if owner != nil, let runnerUp {
                coCounts[runnerUp] += 1
            }
        }
        closeRun(at: frames)
        return out
    }

    // MARK: - Solo gate + phantom fold (D5)

    /// Per-speaker total speech seconds.
    static func perSpeakerSeconds(_ segments: [DiarSegment]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for seg in segments {
            totals[seg.speakerId, default: 0] += seg.duration
        }
        return totals
    }

    /// Whether the recording is genuinely multi-speaker. Gates on the
    /// LARGEST SINGLE secondary speaker, not the sum of all secondaries —
    /// several small spurious slots must not add up to a second voice.
    static func multiSpeaker(_ segments: [DiarSegment]) -> Bool {
        let totals = perSpeakerSeconds(segments)
        guard totals.count > 1 else { return false }
        let sortedDesc = totals.values.sorted(by: >)
        return sortedDesc[1] >= minSecondarySeconds
    }

    /// Relabel every speaker whose total speech is under
    /// `minSecondarySeconds` to the nearest above-floor speaker, so a
    /// phantom's words stay in the transcript. If nobody clears the floor
    /// (defensive — `multiSpeaker` already gated), the largest speaker is
    /// kept as the only real one.
    static func foldPhantomSpeakers(_ segments: [DiarSegment]) -> [DiarSegment] {
        guard !segments.isEmpty else { return [] }
        let totals = perSpeakerSeconds(segments)
        var realSpeakers = Set(totals.filter { $0.value >= minSecondarySeconds }.keys)
        if realSpeakers.isEmpty, let top = totals.max(by: { $0.value < $1.value }) {
            realSpeakers = [top.key]
        }

        let sorted = segments.sorted { $0.start < $1.start }
        var result: [DiarSegment] = []
        result.reserveCapacity(sorted.count)

        for (idx, seg) in sorted.enumerated() {
            if realSpeakers.contains(seg.speakerId) {
                result.append(seg)
                continue
            }
            let prevReal = result.last(where: { realSpeakers.contains($0.speakerId) })
            let nextReal = sorted[(idx + 1)...].first(where: { realSpeakers.contains($0.speakerId) })
            var folded = seg
            switch (prevReal, nextReal) {
            case let (.some(prev), .some(next)):
                let distPrev = seg.start - prev.end
                let distNext = next.start - seg.end
                folded.speakerId = distPrev <= distNext ? prev.speakerId : next.speakerId
            case let (.some(prev), .none):
                folded.speakerId = prev.speakerId
            case let (.none, .some(next)):
                folded.speakerId = next.speakerId
            case (.none, .none):
                break
            }
            result.append(folded)
        }
        return result
    }

    // MARK: - Merge + coalesce

    /// Merge same-speaker runs separated by at most `gapTolerance`.
    static func mergeAdjacent(
        _ segments: [DiarSegment],
        gapTolerance: Double = mergeGapTolerance
    ) -> [DiarSegment] {
        var merged: [DiarSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) where seg.end > seg.start {
            if let last = merged.last, last.speakerId == seg.speakerId, seg.start - last.end <= gapTolerance {
                merged[merged.count - 1] = joined(last, seg)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// Collapse consecutive same-speaker runs into one REGARDLESS of gap:
    /// the gap belongs to no other speaker, so the display treats the whole
    /// stretch as one turn. Input must be start-ordered.
    static func coalesceSameSpeakerRuns(_ segments: [DiarSegment]) -> [DiarSegment] {
        var out: [DiarSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            if let last = out.last, last.speakerId == seg.speakerId {
                out[out.count - 1] = joined(last, seg)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    private static func joined(_ a: DiarSegment, _ b: DiarSegment) -> DiarSegment {
        let co = [a.coSpeakerId, b.coSpeakerId]
            .compactMap { $0 }
            .first { $0 != a.speakerId }
        return DiarSegment(
            speakerId: a.speakerId,
            start: min(a.start, b.start),
            end: max(a.end, b.end),
            coSpeakerId: co
        )
    }

    // MARK: - Gap-free timeline (A1)

    /// Tile `[0, duration]` with the runs: silence between two speakers is
    /// split at its midpoint, leading silence goes to the first run and
    /// trailing silence to the last. Nemotron marks intra-turn pauses as
    /// silence; without this, words spoken in a low-confidence stretch would
    /// fall outside every slice and vanish from a sliced import. Input must
    /// be start-ordered and exclusive (coalesced).
    static func gapFilled(_ runs: [DiarSegment], duration: Double) -> [DiarSegment] {
        guard !runs.isEmpty else { return [] }
        var out = runs
        out[0].start = 0
        for i in 1..<out.count {
            let mid = (out[i - 1].end + out[i].start) / 2
            out[i - 1].end = mid
            out[i].start = mid
        }
        out[out.count - 1].end = max(out[out.count - 1].end, duration)
        return out
    }

    /// Fold every run shorter than `minRunSeconds` into an adjacent run,
    /// shortest first, until none is left (or one run remains). The target
    /// is the neighbour whose speaker was also above threshold during the
    /// short run (`coSpeakerId`) when exactly one neighbour matches, else
    /// the longer neighbour. Input must be gap-free and coalesced; output is
    /// too.
    static func foldShortRuns(_ runs: [DiarSegment]) -> [DiarSegment] {
        var out = runs
        while out.count > 1 {
            guard let i = out.indices
                .filter({ out[$0].duration < minRunSeconds })
                .min(by: { out[$0].duration < out[$1].duration })
            else { break }

            let hasPrev = i > 0
            let hasNext = i < out.count - 1
            let target: Int
            if hasPrev && hasNext {
                let co = out[i].coSpeakerId
                let prevMatches = co != nil && out[i - 1].speakerId == co
                let nextMatches = co != nil && out[i + 1].speakerId == co
                if prevMatches != nextMatches {
                    target = prevMatches ? i - 1 : i + 1
                } else {
                    target = out[i - 1].duration >= out[i + 1].duration ? i - 1 : i + 1
                }
            } else {
                target = hasPrev ? i - 1 : i + 1
            }

            out[target].start = min(out[target].start, out[i].start)
            out[target].end = max(out[target].end, out[i].end)
            out.remove(at: i)
            out = coalesceSameSpeakerRuns(out)
        }
        return out
    }

    // MARK: - Full pipeline

    /// Exclusive speech runs (from `project`) → the timeline both the app
    /// and the CLI label: solo gate → phantom fold → adjacent merge → full
    /// coalesce → gap fill → short-run fold. `nil` means single speaker:
    /// the gate said so, or folding left only one voice.
    ///
    /// The gate and the phantom floor measure SPEECH seconds, so they run
    /// before gap filling turns silence into run time.
    static func speakerRuns(from segments: [DiarSegment], duration: Double) -> [DiarSegment]? {
        guard multiSpeaker(segments) else { return nil }
        let folded = foldPhantomSpeakers(segments)
        let coalesced = coalesceSameSpeakerRuns(mergeAdjacent(folded))
        let runs = foldShortRuns(gapFilled(coalesced, duration: duration))
        guard Set(runs.map(\.speakerId)).count > 1 else { return nil }
        return runs
    }
}
