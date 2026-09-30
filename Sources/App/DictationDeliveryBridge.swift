import AppKit
import Combine
import JotVocabCore
import SwiftData
import os.log

/// What the delivery bridge needs from the status pill: the live "Did you
/// mean…?" prompt and the saved-to-Recents notice. `PillViewModel` in the
/// app; a scripted stand-in in the DEBUG replay harness.
@MainActor
protocol DictationPrompting: AnyObject {
    func showAskCorrection(
        original: String,
        term: String,
        contextBefore: String,
        contextAfter: String,
        applied: Bool,
        alternate: String?,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onAccept: @escaping () -> Void,
        onAlternate: (() -> Void)?
    )
    func showSavedToRecents(preview: String, audioFileName: String?)
}

extension PillViewModel: DictationPrompting {}

/// One finished dictation, exactly as the recorder published it.
struct FinishedDictation {
    let result: TranscriptionResult
    /// The text the session produced (post-cleanup when AI cleanup ran).
    let text: String
    let audio: AudioRecording?
    /// "Return to the app I started in" (design §5.1), stamped on this session.
    let originApp: NSRunningApplication?
    /// Stopped with the in-app pill / Esc: save to Recents, don't paste.
    let skipsPaste: Bool
}

/// **The one `$lastResult` sink** (docs/transcript-consistency A1/A8/A17): a
/// finished dictation is saved first, and its row id then travels with the
/// text to the paste — so nothing downstream guesses "the last recording".
/// Three paths for a freshly landed transcript:
///   1. stopped without paste (in-app pill / Esc): saved to Recents, the
///      saved-to-Recents notice, no paste;
///   2. ask-before-paste — one or more ask-candidate corrections whose word is
///      present in the final text: hold the paste, ask "Did you mean X?" one at
///      a time, write each answer back to the saved row (text, review record,
///      receipt), then paste the saved row's text once;
///   3. the fast path — paste at once (zero added latency).
/// So the pasted text, the saved text, the review list, search, and Paste
/// Last always agree.
@MainActor
final class DictationDeliveryBridge {
    private let recorder: RecorderController
    private let persister: RecordingPersister
    private let delivery: DeliveryService
    private let prompt: any DictationPrompting
    private let context: ModelContext
    private let log = Logger(subsystem: "com.jot.Jot", category: "DictationDelivery")
    /// **Must never be nilled after `start()`** — releasing it would silently
    /// stop every dictation from being saved and delivered.
    private var cancellable: AnyCancellable?

    init(
        recorder: RecorderController,
        persister: RecordingPersister,
        delivery: DeliveryService,
        prompt: any DictationPrompting,
        context: ModelContext
    ) {
        self.recorder = recorder
        self.persister = persister
        self.delivery = delivery
        self.prompt = prompt
        self.context = context
    }

    func start() {
        // Synchronous: the recorder sets every companion value (text, audio,
        // origin, skip-paste) BEFORE `lastResult`, so this reads the session
        // that produced `result`, consistently.
        cancellable = recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak self] result in
                guard let self else { return }
                self.handle(FinishedDictation(
                    result: result,
                    text: self.recorder.lastTranscript ?? result.text,
                    audio: self.recorder.lastAudioRecording,
                    originApp: self.recorder.lastResultOriginApp,
                    skipsPaste: self.recorder.lastResultSkipsPaste))
            }
    }

    /// Save `dictation`, then deliver it (after any asks). Internal so the
    /// DEBUG replay harness can drive a scripted dictation through the same
    /// path the recorder does.
    func handle(_ dictation: FinishedDictation) {
        var saved: RecordingPersister.SavedDictation?
        if let audio = dictation.audio {
            saved = persister.persistDictation(result: dictation.result, transcript: dictation.text, audio: audio)
        } else {
            log.warning("lastResult fired without a paired lastAudioRecording; not saved")
            Task { await ErrorLog.shared.warn(component: "DictationDelivery", message: "lastResult fired without a paired lastAudioRecording") }
        }
        let text = dictation.text
        guard !text.isEmpty else { return }

        if dictation.skipsPaste {
            prompt.showSavedToRecents(
                preview: text,
                audioFileName: dictation.audio?.fileURL.lastPathComponent)
            return
        }

        // Slice D §8 B1 — Transform-safe hold. The gate's `{from,to}` pairs are
        // matched against the FINAL text (char offsets are meaningless after
        // the segmenter / AI cleanup): an APPLIED candidate has its term in the
        // text, a BLOCKED one its original. If cleanup reworded both away, the
        // correction is moot and the ask is dropped.
        let candidates = dictation.result.corrections
            .filter(\.askCandidate)
            .compactMap { AskItem(correction: $0, in: text) }
        guard let saved, !candidates.isEmpty else {
            deliver(text, originApp: dictation.originApp)
            return
        }

        let run = AskRun(recordingID: saved.recording.id, originApp: dictation.originApp, expected: text)
        Task { @MainActor in
            // The answers mark this row's review records, so its records must
            // be committed first.
            await saved.provenanceCommitted.value
            run.items = await askable(candidates)
            await askNext(run)
        }
    }

    // MARK: - Ask selection

    /// One resolvable ask: the gate's pair, plus the wider alternate when the
    /// gate offered one. Built only when a word of the pair is present in the
    /// final text.
    private struct AskItem {
        let from: String
        let term: String
        /// 3-option ask (design §2a, alt0): the wider-span alternate — a longer
        /// term (`altTerm`) over a wider in-text slice (`altFind`).
        let altTerm: String?
        let altFind: String?
        /// Merge-shaped ask ("sri ram" → "Sriram") — gated to one teach ask ever.
        let isMerge: Bool
        /// What the correction rests on — ranks the ask (weakest first).
        let evidence: String?

        init?(correction c: VocabularyRescorerHolder.UXCorrection, in text: String) {
            guard WholeWord.firstRange(of: c.to, in: text) != nil
                    || WholeWord.firstRange(of: c.from, in: text) != nil else { return nil }
            from = c.from
            term = c.to
            altTerm = c.altTerm
            altFind = c.altFind
            isMerge = c.isMerge
            evidence = c.evidence
        }

        /// `"<normalized-original>|<lowercased-term>"` — the EXACT key shape
        /// `CorrectionStore.keyboardSuppressedPairs()` emits, produced by the SAME
        /// package helper (`CorrectionKey.pairKey`), so produce-side and
        /// check-side keys are byte-identical (locked by the package's
        /// `pair_key.json` fixture).
        var suppressionKey: String {
            CorrectionKey.pairKey(originalWord: from, term: term)
        }
    }

    /// The asks actually worth asking, in order. Drops any pair the owner has
    /// already rejected (kept the original ≥ `keyboardKeepSuppressThreshold`
    /// times on a BLOCKED pair, or tapped "Stop asking") and any merge-teach
    /// ask already spent; ranks weakest evidence first, then most-confirmed
    /// (mirrors `AskPolicy`); caps at 3 (anti-nag, §4); and drops merge-teach
    /// asks when a normal ask rides the same batch (WITHOUT spending them).
    private func askable(_ candidates: [AskItem]) async -> [AskItem] {
        let suppressed = await CorrectionStore.shared.keyboardSuppressedPairs()
        // The ask ranking prior (net per pair) — nothing learned auto-applies.
        let overrides = await CorrectionStore.shared.snapshot()
        let mergeAsked = await CorrectionStore.shared.mergeAskedPairs()
        let offered = candidates.filter { item in
            MacVocabGate.shouldOfferAsk(
                suppressionKey: item.suppressionKey,
                isMerge: item.isMerge,
                suppressed: suppressed,
                mergeAsked: mergeAsked)
        }
        func prior(_ item: AskItem) -> Int {
            overrides.first {
                $0.originalWord == CorrectionKey.normalize(item.from)
                    && $0.term.lowercased() == item.term.lowercased()
            }?.net ?? 0
        }
        let ranked = MacVocabGate.rankForAsk(offered, evidence: { $0.evidence }, prior: prior)
        return Array(MacVocabGate.applyMixedPayload(
            Array(ranked.prefix(3)), isMergeTeach: { $0.isMerge }, pairKey: { $0.suppressionKey }))
    }

    // MARK: - The ask sequence

    /// One dictation's asks, resolved one at a time against its saved row.
    private final class AskRun {
        let recordingID: UUID
        let originApp: NSRunningApplication?
        /// The row's text as this run last saw or wrote it. A row that no
        /// longer holds it was edited by someone else: the run stops asking.
        var expected: String
        var items: [AskItem] = []
        var index = 0

        init(recordingID: UUID, originApp: NSRunningApplication?, expected: String) {
            self.recordingID = recordingID
            self.originApp = originApp
            self.expected = expected
        }
    }

    /// Where an ask lands in the saved text: the review record it answers (when
    /// one resolves), the in-text word's range, and — for a 3-option ask — the
    /// wider slice the alternate replaces. Ranges are UTF-16, in the text the
    /// ask was shown for.
    private struct AskTarget {
        let record: CorrectionProvenance.Record?
        let anchor: NSRange
        /// The term is in the text (the gate applied it); else the original is.
        let applied: Bool
        let alternate: NSRange?
    }

    private enum Answer { case confirm, keepOriginal, alternate }

    /// Show the next ask, or — when the queue is drained, the row was edited
    /// under us, or it was deleted — paste once and end.
    private func askNext(_ run: AskRun) async {
        guard let row = RecordingStore.recording(id: run.recordingID, in: context) else {
            // Deleted mid-ask: paste what the user dictated (as last written).
            finish(run, text: run.expected)
            return
        }
        // Edited under us (e.g. a pick in an open detail view): stop asking and
        // paste the saved row — never write over someone else's edit.
        guard row.transcript == run.expected, run.index < run.items.count else {
            finish(run, text: row.transcript)
            return
        }
        let item = run.items[run.index]
        let text = row.transcript
        guard let target = await locate(item, recordingID: run.recordingID, in: text) else {
            // A prior answer removed this ask's word — moot, skip it.
            run.index += 1
            await askNext(run)
            return
        }
        // A new recording may have started while we awaited: it owns the pill
        // now, so this ask is abandoned exactly as `abandonPendingAsk` would.
        switch recorder.state {
        case .recording, .transcribing, .transforming: return
        case .idle, .error: break
        }
        guard RecordingStore.recording(id: run.recordingID, in: context)?.transcript == text else {
            await askNext(run)
            return
        }

        guard let anchor = Range(target.anchor, in: text) else {
            finish(run, text: text)
            return
        }
        let (contextBefore, contextAfter) = WholeWord.context(around: anchor, in: text)
        prompt.showAskCorrection(
            original: item.from,
            term: item.term,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            applied: target.applied,
            alternate: target.alternate != nil ? item.altTerm : nil,
            onConfirm: { [weak self] in self?.answer(.confirm, item: item, target: target, run: run) },
            onDismiss: { [weak self] in self?.answer(.keepOriginal, item: item, target: target, run: run) },
            onAccept: { [weak self] in
                // Timeout (10s) / outside-click → paste the saved text as it
                // stands IMMEDIATELY and end the sequence (one shot, not a
                // wait-through of the remaining asks). The gate's default is
                // already in the text, so no answer is recorded — an ignored
                // ask is neither a keep nor a confirm.
                guard let self else { return }
                let current = RecordingStore.recording(id: run.recordingID, in: self.context)?.transcript
                self.finish(run, text: current ?? run.expected)
            },
            onAlternate: target.alternate == nil ? nil : { [weak self] in
                self?.answer(.alternate, item: item, target: target, run: run)
            }
        )
        // Merge-teach one-shot SPEND (design §1 invariant — decide in the
        // filter, spend AFTER the ask is surfaced).
        if item.isMerge {
            Task { await CorrectionStore.shared.noteMergeAsked(originalWord: item.from, term: item.term) }
        }
    }

    /// Resolve where `item` lands in `text`: the pair's first open review
    /// record whose word is still exactly at its anchor — the same occurrence
    /// the review list shows — else (no record committed, or cleanup moved its
    /// word) the first whole-word occurrence.
    private func locate(_ item: AskItem, recordingID: UUID, in text: String) async -> AskTarget? {
        let payload = await CorrectionProvenance.shared.reconciledPayload(
            transcriptID: recordingID, currentText: text)
        let open = payload.openRecords(originalWord: item.from, term: item.term)
        var found: (CorrectionProvenance.Record?, Range<String.Index>, Bool)?
        for record in open {
            if let r = ReviewRecordEdit.anchoredRange(of: record.term, for: record, in: text) {
                found = (record, r, true); break
            }
            if let r = ReviewRecordEdit.anchoredRange(of: record.originalWord, for: record, in: text) {
                found = (record, r, false); break
            }
        }
        if found == nil {
            if let r = WholeWord.firstRange(of: item.term, in: text) {
                found = (open.first, r, true)
            } else if let r = WholeWord.firstRange(of: item.from, in: text) {
                found = (open.first, r, false)
            }
        }
        guard let (record, anchor, applied) = found else { return nil }
        // The alternate's wider slice: the occurrence covering this anchor.
        // None covers it → no alternate is offered (it would edit other words).
        var alternate: NSRange?
        if let altFind = item.altFind, item.altTerm != nil,
           let slice = WholeWord.ranges(of: altFind, in: text).first(where: { $0.contains(anchor.lowerBound) }) {
            alternate = NSRange(slice, in: text)
        }
        return AskTarget(record: record, anchor: NSRange(anchor, in: text), applied: applied,
                         alternate: alternate)
    }

    /// An explicit answer: teach it, write it back to the saved row, then ask
    /// the next one.
    private func answer(_ answer: Answer, item: AskItem, target: AskTarget, run: AskRun) {
        let original = target.record?.originalWord ?? item.from
        let term = target.record?.term ?? item.term
        Task { @MainActor in
            switch answer {
            case .confirm:
                // Ranks future asks (Q3); the correction adds the sounds-like
                // (the one learning path). Nothing learned auto-applies.
                await CorrectionStore.shared.confirm(originalWord: item.from, term: item.term)
                let receipt = await VocabularyLearning.shared.apply(.correct(heard: item.from, term: item.term))
                await writeBack(run, record: target.record, verdict: "term", receipt: receipt,
                                edit: target.applied ? nil : (target.anchor, term))
            case .keepOriginal:
                // An explicit keep is a rejection, persisted so the pair stops
                // re-asking: a BLOCKED pair counts toward suppression
                // (`noteBlockedKeep`); an APPLIED pair the owner reverted records
                // the negative signal (`revert`). It also pauses the decoder
                // pair (the one learning path).
                if target.applied {
                    await CorrectionStore.shared.revert(originalWord: item.from, term: item.term)
                } else {
                    await CorrectionStore.shared.noteBlockedKeep(originalWord: item.from, term: item.term)
                }
                let receipt = await VocabularyLearning.shared.apply(.keepOriginal(heard: item.from, term: item.term))
                await writeBack(run, record: target.record, verdict: "original", receipt: receipt,
                                edit: target.applied ? (target.anchor, original) : nil)
            case .alternate:
                // The wider-span alternate (design §2a/c): splice altFind →
                // altTerm and teach THAT mapping, exactly like a confirm.
                guard let altFind = item.altFind, let altTerm = item.altTerm,
                      let slice = target.alternate else { break }
                await CorrectionStore.shared.confirm(originalWord: altFind, term: altTerm)
                let receipt = await VocabularyLearning.shared.apply(.correct(heard: altFind, term: altTerm))
                await writeBack(run, record: target.record, verdict: "alt0", receipt: receipt,
                                edit: (slice, altTerm))
            }
            run.index += 1
            await askNext(run)
        }
    }

    /// Write one answer back to the saved row: its text edit (through
    /// `RecordingTextMutation`, anchored at the answered record) and the
    /// record's verdict with the answer's receipt, so the review list shows it
    /// answered and its Undo reverses exactly this. The verdict's store deltas
    /// are NOT applied — the answer already wrote the store.
    private func writeBack(
        _ run: AskRun,
        record: CorrectionProvenance.Record?,
        verdict: String,
        receipt: VocabularyLearning.Receipt,
        edit: (range: NSRange, replacement: String)?
    ) async {
        guard let row = RecordingStore.recording(id: run.recordingID, in: context),
              row.transcript == run.expected else { return }   // `askNext` settles it
        if let edit {
            await ReviewRecordEdit.replace(edit.range, with: edit.replacement, answering: record,
                                           in: row, context: context)
        }
        if let record {
            _ = await CorrectionProvenance.shared.setVerdict(
                transcriptID: run.recordingID, record: record, verdict: verdict, receipt: receipt)
        }
        guard let saved = RecordingStore.recording(id: run.recordingID, in: context)?.transcript else { return }
        run.expected = saved
        // Paste Last / Copy Last follow the saved text even if the sequence
        // is abandoned before it pastes.
        recorder.adoptDeliveredText(saved)
    }

    /// Paste the sequence's final text exactly once.
    private func finish(_ run: AskRun, text: String) {
        recorder.adoptDeliveredText(text)
        deliver(text, originApp: run.originApp)
    }

    private func deliver(_ text: String, originApp: NSRunningApplication?) {
        // Auto-Enter (if enabled) runs INSIDE deliver(), after the paste.
        Task { @MainActor in await delivery.deliver(text, originApp: originApp) }
    }
}
