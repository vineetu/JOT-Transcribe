import Foundation
import os.log

/// **Per-transcript correction provenance + per-occurrence resolution store.**
/// Stores the gate's full proposal list for each saved transcript (so the
/// transcript pane can show "here's what Jot corrected / considered") AND the
/// owner's per-occurrence verdicts (so an answered occurrence never re-asks).
///
/// Two stores, deliberately separate:
///   - **proposals (`records`)** — what the gate did, per OCCURRENCE. Each record
///     carries a STABLE identity (`originalStart`, the span's offset in the
///     original pre-rescore text) plus a LIVE anchor (`publishedStart`) into the
///     current transcript text, maintained by `reconciledPayload`/`noteSelfEdit`.
///   - **verdicts** — the owner's `term | original` pick per occurrence, keyed by
///     that stable identity. A verdict HIDES the row (resolved) and drives the
///     this-occurrence text edit. It is the ONLY thing that decides "answered."
///   - **mappingsTaught** — guard so a mapping (`original→term`) feeds the
///     MAPPING-level learning store (`CorrectionStore`) at most once per
///     transcript, regardless of how many occurrences the owner adjudicates.
///     Prevents three "name→Jamy" picks from inflating net to 3.
///
/// Timing (the gate runs BEFORE the transcript id exists): the gate fills a
/// transient `pending` slot at rescore time; `commit(transcriptID:)` moves it to
/// a side-JSON keyed by the real id once the transcript is saved. Dictation is
/// serial → the single pending slot is safe.
///
/// Storage: `Application Support/Vocabulary/provenance/<transcriptID>.json`.
///
/// **Ported faithfully from jot-mobile**
/// (`Jot/App/Vocabulary/CorrectionProvenance.swift`). macOS deviation: the
/// iPhone-only `DiagnosticsLog.record(...)` in `commit(...)` is replaced by the
/// shared `os_log` logger (desktop subsystem) — `CorrectionProvenance` keeps no
/// dependency on the iPhone diagnostics surface.
actor CorrectionProvenance {
    static let shared = CorrectionProvenance()

    private let log = Logger(subsystem: "com.jot.Jot", category: "VocabularyGate")

    /// One gated occurrence. `originalStart`/`originalLength` are the stable
    /// identity (offset in the ORIGINAL text); `publishedStart` is a LIVE anchor
    /// into the CURRENT transcript text, kept valid by `reconciledPayload` across
    /// every edit — verdict edits AND hand-edits alike (see `anchoredText`).
    struct Record: Codable, Sendable, Equatable {
        let originalWord: String     // what TDT wrote ("Jamie")
        let term: String             // the vocab term ("Jamy")
        let decision: String         // "APPLY" | "BLOCK" | "OVERRIDE"
        let outcome: String          // "applied" | "kept"
        let confidence: Float
        let margin: Float
        let unsure: Bool
        let occurrenceIndex: Int     // display-only
        let originalStart: Int
        let originalLength: Int
        var publishedStart: Int      // LIVE anchor — mutated only by reconcile
        let publishedLength: Int     // gate-time span length (display/diag only)

        /// Stable per-occurrence identity key (verdict + mark lookup).
        var key: String { "\(originalWord.lowercased())|\(term.lowercased())|\(originalStart)" }
        /// Mapping key (shared by every occurrence of the same original→term).
        var mappingKey: String { "\(originalWord.lowercased())|\(term.lowercased())" }
    }

    /// On-disk shape: proposals + per-occurrence verdicts + this transcript's
    /// current contribution to each mapping's learning net (+1/−1, reversible).
    struct Payload: Codable, Sendable {
        var records: [Record] = []
        var verdicts: [String: String] = [:]      // record.key → "term" | "original"
        var contributions: [String: Int] = [:]    // record.mappingKey → this transcript's net contribution
        /// The transcript text the records' `publishedStart` anchors are valid
        /// for. `reconciledPayload` diffs this against the live text and shifts
        /// anchors, so an edit made ANYWHERE (verdict pick, hand-edit in the
        /// detail TextEditor) is accounted exactly once — the reconcile is
        /// state-based (fingerprint), not event-based. nil on payloads written
        /// before this field existed (adopted on first read).
        var anchoredText: String?
    }

    /// What a verdict change does to a mapping's global learning net. The caller
    /// applies it to `CorrectionStore.adjust`. `delta == 0` ⇒ nothing to do.
    struct MappingDelta: Sendable {
        let originalWord: String
        let term: String
        let delta: Int
    }

    private var pending: [Record] = []
    /// The gate-output text `pending`'s `publishedStart` offsets index into —
    /// the ONLY text those offsets are valid for. Becomes the payload's
    /// `anchoredText` baseline at commit; the post-gate transform chain
    /// (segmenter / filler sweep / number normalizer / AI cleanup) changes the
    /// text BEFORE it's saved, and the first `reconciledPayload` absorbs that
    /// drift exactly by diffing from this baseline.
    private var pendingAnchorText: String = ""

    // MARK: - Gate side (write)

    /// Called at rescore time (no transcript id yet) — stashes this dictation's
    /// proposals until the transcript is saved. `gatedText` is the gate's output
    /// text, i.e. the string the proposals' `publishedStart` offsets point into.
    func record(_ proposals: [VocabularyGate.Proposal], gatedText: String) {
        pendingAnchorText = gatedText
        pending = proposals.map {
            Record(
                originalWord: $0.originalWord, term: $0.term, decision: $0.decision,
                outcome: $0.outcome, confidence: $0.confidence, margin: $0.margin,
                unsure: $0.unsure, occurrenceIndex: $0.occurrenceIndex,
                originalStart: $0.originalStart, originalLength: $0.originalLength,
                publishedStart: $0.publishedStart, publishedLength: $0.publishedLength)
        }
    }

    /// Clears the pending slot. Called at the START of every transcription so a
    /// no-proposal dictation — or a non-saving caller (Ask/watch/file-import) that
    /// filled the slot — can never have a stale `pending` committed under the next
    /// transcript's id.
    func clearPending() {
        pending = []
        pendingAnchorText = ""
    }

    /// Persist the pending records under the saved transcript id (fresh verdicts).
    /// The anchor baseline is the GATE-OUTPUT text captured by `record(_:gatedText:)`
    /// — the one string the records' `publishedStart` offsets are actually valid
    /// for. (NOT the published/saved text: post-gate transforms already shifted
    /// that; seeding it would bake the drift in as "valid".)
    func commit(transcriptID: UUID) {
        let records = pending
        let anchorText = pendingAnchorText
        pending = []
        pendingAnchorText = ""
        guard !records.isEmpty, let url = fileURL(transcriptID) else {
            return
        }
        // Commit is once-per-fresh-id, but be defensive: if a payload already
        // exists for this id (a re-commit / retry), PRESERVE the owner's verdicts
        // and the mapping-taught guard — only the records are (re)written. A blind
        // overwrite would silently wipe answered rows.
        let existing = payload(transcriptID: transcriptID)
        let payload = Payload(
            records: records, verdicts: existing.verdicts,
            contributions: existing.contributions, anchoredText: anchorText)
        var wrote = false
        if let data = try? JSONEncoder().encode(payload) {
            do { try data.write(to: url, options: .atomic); wrote = true } catch {}
        }
        log.info(
            "provenance committed: records=\(records.count, privacy: .public) wrote=\(wrote, privacy: .public) id=\(transcriptID.uuidString, privacy: .public)"
        )
    }

    // MARK: - Pane side (read + verdict)

    /// Full payload for a transcript (proposals + verdicts).
    func payload(transcriptID: UUID) -> Payload {
        guard
            let url = fileURL(transcriptID),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return decoded
    }

    /// Payload with every record's `publishedStart` anchor reconciled to
    /// `currentText`. THE anchor-maintenance entry point — every reader that
    /// will resolve spans (the review model's `reload()`) goes through here.
    ///
    /// State-based, not event-based: the payload remembers the text its anchors
    /// are valid for (`anchoredText`); if the live text differs, the single
    /// contiguous changed region between the two is computed and every anchor
    /// at/after the region's end shifts by the length delta. This accounts for
    /// ANY edit — a verdict pick, a hand-edit in the detail TextEditor — exactly
    /// once, no matter which model instance made it or whether this one observed
    /// it happen. An anchor INSIDE the changed region keeps its offset and is
    /// left to strict span resolution: if the word still starts there it
    /// resolves; if the user edited it away, resolution fails and the surfaces
    /// fail SAFE (no mark, no text edit).
    func reconciledPayload(transcriptID: UUID, currentText: String) -> Payload {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty else { return p }
        guard let anchored = p.anchoredText else {
            // Legacy payload (written before anchoredText existed): adopt the
            // live text as the baseline WITHOUT shifting — anchors are as good
            // as they ever were; strict resolution backstops any prior drift.
            p.anchoredText = currentText
            persist(transcriptID: transcriptID, p)
            return p
        }
        guard anchored != currentText else { return p }
        let mapped = Self.mapOffsets(p.records.map(\.publishedStart), old: anchored, new: currentText)
        for i in p.records.indices {
            p.records[i].publishedStart = mapped[i]
        }
        p.anchoredText = currentText
        persist(transcriptID: transcriptID, p)
        return p
    }

    /// Records mapped into `text` WITHOUT persisting — for a one-off read
    /// against a text that is NOT the transcript's stored text. The durable
    /// chain stays gate-output → transcript.text, owned by `reconciledPayload`.
    func mappedPayload(transcriptID: UUID, into text: String) -> Payload {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty, let anchored = p.anchoredText, anchored != text else { return p }
        let mapped = Self.mapOffsets(p.records.map(\.publishedStart), old: anchored, new: text)
        for i in p.records.indices {
            p.records[i].publishedStart = mapped[i]
        }
        return p   // NOT persisted — anchoredText keeps the durable baseline
    }

    /// Account EXACTLY for one of OUR OWN verdict edits (a pick/undo replacing
    /// record `recordKey`'s span at Character offset `start`: oldLength →
    /// newLength chars, producing `newText`). A text diff cannot do this safely:
    /// when the replacement shares a suffix with the replaced word ("nathan" →
    /// "Ramanathan") the diff is genuinely ambiguous and can shift the edited
    /// record's own anchor off its word, breaking Undo. Self edits therefore
    /// REPORT their span; the blind diff in `reconciledPayload` is only for
    /// EXTERNAL edits (hand-edits), where strict span resolution backstops it.
    ///
    /// Race-tolerant against the detail view's onChange-triggered reconcile: if
    /// that reconcile already absorbed this edit (anchoredText == newText), the
    /// bulk shift has been applied by the diff and only the self record — the
    /// one span the diff can get wrong — is pinned. Otherwise the exact shift
    /// is applied and the fingerprint advanced (so the racing reconcile no-ops).
    func noteSelfEdit(
        transcriptID: UUID, recordKey: String,
        start: Int, oldLength: Int, newLength: Int, newText: String
    ) {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty else { return }
        if p.anchoredText == newText {
            for i in p.records.indices where p.records[i].key == recordKey {
                p.records[i].publishedStart = start
            }
        } else {
            let delta = newLength - oldLength
            for i in p.records.indices {
                if p.records[i].key == recordKey {
                    p.records[i].publishedStart = start
                } else if p.records[i].publishedStart >= start + oldLength {
                    p.records[i].publishedStart += delta
                }
            }
            p.anchoredText = newText
        }
        persist(transcriptID: transcriptID, p)
    }

    /// Exact old→new Character-offset mapping via a real collection diff —
    /// handles MULTI-region changes (the post-gate segmenter / filler / number
    /// transform chain makes several small edits in one hop; an AI-cleanup or
    /// hand-edit Save can too), which a single prefix/suffix region cannot.
    /// An offset inside a removed region maps to the removal point and relies
    /// on the caller's strict whole-word resolution to fail safe.
    static func mapOffsets(_ offsets: [Int], old: String, new: String) -> [Int] {
        let diff = Array(new).difference(from: Array(old))
        var removals: [Int] = []     // OLD-space indices
        var insertions: [Int] = []   // NEW-space indices
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.append(offset)
            case .insert(let offset, _, _): insertions.append(offset)
            }
        }
        removals.sort()
        insertions.sort()
        return offsets.map { anchor in
            var pos = anchor - removals.prefix(while: { $0 < anchor }).count
            for ins in insertions {
                if ins <= pos { pos += 1 } else { break }
            }
            return max(0, pos)
        }
    }

    /// Record a per-occurrence verdict and return how the mapping's global net
    /// should move (caller applies it to `CorrectionStore`). `verdict` ∈
    /// {"term","original"}. A transcript contributes at most ±1 per mapping
    /// (recomputed from ALL its verdicts), so three "name→Jamy" picks can't
    /// inflate net to 3, and a mixed transcript (some term, some revert) gives 0.
    func setVerdict(transcriptID: UUID, record: Record, verdict: String) -> MappingDelta? {
        var p = payload(transcriptID: transcriptID)
        p.verdicts[record.key] = verdict
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    /// Undo a verdict — clears the pick (row re-surfaces) and reverses this
    /// transcript's mapping contribution if no sibling verdict still supports it.
    func clearVerdict(transcriptID: UUID, record: Record) -> MappingDelta? {
        var p = payload(transcriptID: transcriptID)
        p.verdicts.removeValue(forKey: record.key)
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    /// Recompute this transcript's contribution to `record`'s mapping from its
    /// CURRENT verdicts, store it, and return the delta vs the stored value.
    private func finalize(_ p: inout Payload, transcriptID: UUID, record: Record) -> MappingDelta? {
        let mk = record.mappingKey
        let desired = desiredContribution(p, mappingKey: mk)
        let old = p.contributions[mk] ?? 0
        if desired == 0 { p.contributions[mk] = nil } else { p.contributions[mk] = desired }
        persist(transcriptID: transcriptID, p)
        let delta = desired - old
        return delta == 0 ? nil : MappingDelta(originalWord: record.originalWord, term: record.term, delta: delta)
    }

    /// +1 if the owner meant the term for this mapping (any "term", no revert),
    /// −1 if they reverted an applied one (any revert, no "term"), 0 if mixed or
    /// only "kept-original" (no learning signal).
    private func desiredContribution(_ p: Payload, mappingKey: String) -> Int {
        let occ = p.records.filter { $0.mappingKey == mappingKey }
        let anyTerm = occ.contains { p.verdicts[$0.key] == "term" }
        let anyDemote = occ.contains { p.verdicts[$0.key] == "original" && $0.outcome == "applied" }
        if anyTerm && !anyDemote { return 1 }
        if anyDemote && !anyTerm { return -1 }
        return 0
    }

    /// Drop a transcript's provenance (e.g. when the transcript is deleted).
    func discard(transcriptID: UUID) {
        guard let url = fileURL(transcriptID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Storage

    private func persist(transcriptID: UUID, _ p: Payload) {
        guard let url = fileURL(transcriptID), let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ id: UUID) -> URL? {
        guard
            let dir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        let prov = dir.appendingPathComponent("Vocabulary/provenance", isDirectory: true)
        try? FileManager.default.createDirectory(at: prov, withIntermediateDirectories: true)
        return prov.appendingPathComponent("\(id.uuidString).json")
    }
}
