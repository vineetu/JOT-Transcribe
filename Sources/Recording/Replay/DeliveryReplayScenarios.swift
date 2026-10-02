#if DEBUG
import AppKit
import Combine
import JotVocabCore
import SwiftData

// DEBUG replay scenarios for transcript consistency
// (docs/transcript-consistency): the pasted text must be the saved text.
// They run the REAL delivery path — `DictationDeliveryBridge` (save → row id →
// asks → one paste) over a `RecordingPersister`, `DeliveryService`, and an
// in-memory SwiftData store — with a private pasteboard and a scripted pill.
//
//   --scenario ask-confirm | ask-keep | ask-alternate | ask-timeout
//       A scripted dictation whose gate flagged the SECOND "kwerty" in
//       "Our kwerty bill: I asked kwerty code today." for a "Did you mean
//       Qwerti?" ask (with a wider "Qwerti Code" alternate). The pill answers
//       programmatically. No audio or model is used (`--jot-replay` still
//       needs a path; it isn't read).
//   --scenario stop-without-paste
//       Real audio + model through a real `RecorderController`: a dictation
//       stopped with stop-without-paste whose transcription fails (stopped
//       under 1 s → too short), then a normal dictation of the input file,
//       which must paste — the saved row's text.
//   --scenario edit-then-paste-last
//       Real audio + model: dictate the input file, then hand-edit the saved
//       row (Edit → Done's path, `RecordingTextMutation`), then Paste Last —
//       which must paste the edited text, not the first draft.
//   --scenario self-tests
//       The DEBUG unit self-tests for the text helper, speaker-segment
//       carrying, and the ask filters (they `assert`, so a failure crashes
//       the run with a non-zero exit).
//
// Every scenario writes `checks` (name → passed) into the report; a failed
// check is also an error, so the process exits 3.

/// Records every clipboard write on a private pasteboard; the synthetic key
/// events are no-ops. The developer's real clipboard is never touched.
@MainActor
final class ReplayPasteboard: Pasteboarding {
    private let pasteboard = NSPasteboard.withUniqueName()
    private(set) var writes: [String] = []

    func snapshot() -> PasteboardSnapshot { ClipboardSandwich.snapshot(pasteboard: pasteboard) }

    @discardableResult
    func write(_ string: String) -> Bool {
        writes.append(string)
        return ClipboardSandwich.writeString(string, pasteboard: pasteboard)
    }

    func restore(_ snapshot: PasteboardSnapshot) { ClipboardSandwich.restore(snapshot, pasteboard: pasteboard) }
    var changeCount: Int { pasteboard.changeCount }
    func readString() -> String? { pasteboard.string(forType: .string) }
    func postCommandC() throws {}
    func postCommandV() throws {}
    func postReturn() throws {}

    /// The first write, waiting up to `timeout` seconds for it.
    func firstWrite(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while writes.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return writes.first
    }
}

/// The pill, scripted: answers every ask the same way on the next turn.
@MainActor
final class ReplayPrompter: DictationPrompting {
    enum Answer: String { case confirm, keepOriginal, alternate, timeout }

    let answer: Answer
    private(set) var asks: [[String: Any]] = []
    private(set) var savedNotices: [String] = []

    init(answer: Answer) { self.answer = answer }

    func showAskCorrection(
        original: String, term: String, contextBefore: String, contextAfter: String,
        applied: Bool, alternate: String?,
        onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void,
        onAccept: @escaping () -> Void, onAlternate: (() -> Void)?
    ) {
        asks.append([
            "original": original, "term": term, "applied": applied,
            "context": "\(contextBefore)[\(applied ? term : original)]\(contextAfter)",
            "alternate": alternate ?? NSNull(),
        ])
        let pick: () -> Void
        switch answer {
        case .confirm: pick = onConfirm
        case .keepOriginal: pick = onDismiss
        case .alternate: pick = onAlternate ?? onDismiss
        case .timeout: pick = onAccept
        }
        Task { @MainActor in pick() }
    }

    func showSavedToRecents(preview: String, audioFileName: String?) {
        savedNotices.append(preview)
    }
}

private struct ReplayKeychain: KeychainStoring {
    func load(account: String) throws -> String? { nil }
    func save(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}

@MainActor
enum DeliveryReplayScenarios {

    /// The real delivery graph over an in-memory store.
    struct Stack {
        let container: ModelContainer
        let recorder: RecorderController
        let persister: RecordingPersister
        let pasteboard: ReplayPasteboard
        let delivery: DeliveryService
        let prompter: ReplayPrompter
        let bridge: DictationDeliveryBridge

        @MainActor func rows() -> [Recording] {
            (try? container.mainContext.fetch(
                FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        }
    }

    static func makeStack(
        pipeline: VoiceInputPipeline,
        holder: TranscriberHolder,
        defaults: UserDefaults,
        permissions: any PermissionsObserving,
        answer: ReplayPrompter.Answer
    ) throws -> Stack {
        let container = try ModelContainer(
            for: Recording.self, RecordingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let recorder = RecorderController(
            pipeline: pipeline,
            urlSession: .shared,
            appleIntelligence: AppleIntelligenceClient(),
            // AI cleanup off: the suite never has it enabled.
            llmConfiguration: LLMConfiguration(keychain: ReplayKeychain(), defaults: defaults))
        let persister = RecordingPersister(
            recorder: recorder, context: container.mainContext, transcriberHolder: holder)
        persister.start()
        let pasteboard = ReplayPasteboard()
        let delivery = DeliveryService(pasteboard: pasteboard, logSink: ErrorLog.shared, permissions: permissions)
        delivery.bind(library: container.mainContext)
        let prompter = ReplayPrompter(answer: answer)
        let bridge = DictationDeliveryBridge(
            recorder: recorder, persister: persister, delivery: delivery,
            prompt: prompter, context: container.mainContext)
        return Stack(container: container, recorder: recorder, persister: persister,
                     pasteboard: pasteboard, delivery: delivery, prompter: prompter, bridge: bridge)
    }

    // MARK: - Ask scenarios

    /// A scripted ask answered with `answer`. Asserts saved == pasted ==
    /// the expected text, the review record's verdict, and Paste Last.
    static func ask(_ answer: ReplayPrompter.Answer, stack: Stack, sandbox: URL,
                    errors: inout [String]) async -> [String: Any] {
        // Keep is only an edit when the gate APPLIED the term; the others
        // answer a BLOCKED near-miss. Either way the ask anchors on the
        // SECOND occurrence — the first must never be touched.
        let applied = answer == .keepOriginal
        let spoken = "Our kwerty bill: I asked kwerty code today."
        let text = applied ? "Our kwerty bill: I asked Qwerti code today." : spoken
        let anchor = (spoken as NSString).range(of: "kwerty", options: .backwards).location
        let altFind = applied ? "Qwerti code" : "kwerty code"
        let proposal = VocabularyGate.Proposal(
            originalWord: "kwerty", term: "Qwerti",
            decision: applied ? "APPLY" : "BLOCK", outcome: applied ? "applied" : "kept",
            confidence: 0.5, margin: 1, unsure: true, askCandidate: true, occurrenceIndex: 1,
            originalStart: anchor, originalLength: 6, publishedStart: anchor, publishedLength: 6,
            alternates: [VocabularyGate.Alternate(term: "Qwerti Code", find: altFind)], shape: nil,
            evidence: "acoustic")
        await CorrectionProvenance.shared.record([proposal], gatedText: text)
        let correction = VocabularyRescorerHolder.UXCorrection(
            from: "kwerty", to: "Qwerti", notable: true, askCandidate: true,
            altTerm: "Qwerti Code", altFind: altFind, isMerge: false, evidence: "acoustic")
        let audio = AudioRecording(
            samples: [], fileURL: sandbox.appendingPathComponent("Recordings/ask-\(answer.rawValue).wav"),
            duration: 2, createdAt: .now)
        stack.bridge.handle(FinishedDictation(
            result: TranscriptionResult(text: text, rawText: text, duration: 2, processingTime: 0,
                                        confidence: 0, corrections: [correction]),
            text: text, audio: audio, originApp: nil, skipsPaste: false))

        let pasted = await stack.pasteboard.firstWrite(timeout: 20)
        let row = stack.rows().last
        let saved = row?.transcript
        var verdicts: [String] = []
        if let row {
            let payload = await CorrectionProvenance.shared.payload(transcriptID: row.id)
            verdicts = payload.records.compactMap { payload.verdicts[$0.key] }
        }
        let expectedText: String
        let expectedVerdicts: [String]
        switch answer {
        case .confirm:
            expectedText = "Our kwerty bill: I asked Qwerti code today."; expectedVerdicts = ["term"]
        case .keepOriginal:
            expectedText = spoken; expectedVerdicts = ["original"]
        case .alternate:
            expectedText = "Our kwerty bill: I asked Qwerti Code today."; expectedVerdicts = ["alt0"]
        case .timeout:
            expectedText = text; expectedVerdicts = []
        }
        let checks: [String: Bool] = [
            "askShown": stack.prompter.asks.count == 1,
            "pastedOnce": stack.pasteboard.writes.count == 1,
            "savedEqualsPasted": pasted != nil && saved == pasted,
            "savedIsExpected": saved == expectedText,
            "verdict": verdicts == expectedVerdicts,
            "pasteLastIsPasted": RecordingStore.latest(in: stack.container.mainContext)?.transcript == pasted,
        ]
        record(checks, scenario: "ask-\(answer.rawValue)", into: &errors)
        return [
            "answer": answer.rawValue,
            "asks": stack.prompter.asks,
            "pasted": pasted ?? NSNull(),
            "saved": saved ?? NSNull(),
            "expected": expectedText,
            "verdicts": verdicts,
            "pasteLastText": RecordingStore.latest(in: stack.container.mainContext)?.transcript ?? NSNull(),
            "checks": checks,
        ]
    }

    // MARK: - Stop without paste, then a failure, then a normal dictation

    static func stopWithoutPasteThenDictate(
        stack: Stack, capture: FileAudioCapture, input: URL, speed: Double,
        errors: inout [String]
    ) async throws -> [String: Any] {
        let recorder = stack.recorder
        stack.bridge.start()

        // 1. Stop-without-paste after a fraction of a second: the transcription
        //    fails (too short), so this session never publishes a result.
        try capture.prepareSource(input)
        await recorder.toggle()
        guard await wait(timeout: 30, until: { if case .recording = recorder.state { true } else { false } }) else {
            throw ReplayScenarioError("first dictation never started recording")
        }
        try await Task.sleep(for: .seconds(0.3 / speed))
        await recorder.stopWithoutPaste()
        _ = await wait(timeout: 60, until: {
            switch recorder.state {
            case .idle, .error: true
            default: false
            }
        })
        let firstState = String(describing: recorder.state)
        let firstRows = stack.rows().count
        let firstWrites = stack.pasteboard.writes.count
        recorder.clearError()

        // 2. A normal dictation of the whole file: must paste the saved text.
        try capture.prepareSource(input)
        await recorder.toggle()
        guard await wait(timeout: 30, until: { if case .recording = recorder.state { true } else { false } }) else {
            throw ReplayScenarioError("second dictation never started recording")
        }
        await capture.waitUntilExhausted()
        await recorder.toggle()
        let pasted = await stack.pasteboard.firstWrite(timeout: 180)
        let saved = stack.rows().last?.transcript

        let checks: [String: Bool] = [
            "firstPastedNothing": firstWrites == 0,
            "secondPasted": pasted != nil,
            "savedEqualsPasted": pasted != nil && saved == pasted,
            "pasteLastIsPasted": RecordingStore.latest(in: stack.container.mainContext)?.transcript == pasted,
        ]
        record(checks, scenario: "stop-without-paste", into: &errors)
        return [
            "first": ["state": firstState, "rows": firstRows, "pastes": firstWrites,
                      "savedNotices": stack.prompter.savedNotices.count],
            "pasted": pasted ?? NSNull(),
            "saved": saved ?? NSNull(),
            "rows": stack.rows().count,
            "checks": checks,
        ]
    }

    // MARK: - Edit, then Paste Last

    static func editThenPasteLast(
        stack: Stack, capture: FileAudioCapture, input: URL, errors: inout [String]
    ) async throws -> [String: Any] {
        let recorder = stack.recorder
        stack.bridge.start()

        try capture.prepareSource(input)
        await recorder.toggle()
        guard await wait(timeout: 30, until: { if case .recording = recorder.state { true } else { false } }) else {
            throw ReplayScenarioError("dictation never started recording")
        }
        await capture.waitUntilExhausted()
        await recorder.toggle()
        let pasted = await stack.pasteboard.firstWrite(timeout: 180)
        guard let row = stack.rows().last else { throw ReplayScenarioError("dictation was not saved") }

        let edited = row.transcript + " Edited after paste."
        try RecordingTextMutation.apply(.handEdit(edited), to: row, in: stack.container.mainContext)
        await stack.delivery.pasteLast()
        _ = await wait(timeout: 20, until: { stack.pasteboard.writes.count >= 2 })
        let replayed = stack.pasteboard.writes.count >= 2 ? stack.pasteboard.writes[1] : nil

        let checks: [String: Bool] = [
            "pasted": pasted != nil,
            "pasteLastPastesEdit": replayed == edited,
        ]
        record(checks, scenario: "edit-then-paste-last", into: &errors)
        return [
            "pasted": pasted ?? NSNull(),
            "edited": edited,
            "pasteLast": replayed ?? NSNull(),
            "checks": checks,
        ]
    }

    // MARK: - Self-tests

    static func selfTests() -> [String: Any] {
        RecordingTextMutationTests.runAll()
        SpeakerTimelineTextEditTests.runAll()
        VocabAskFilterTests.runAll()
        return ["ran": ["RecordingTextMutationTests", "SpeakerTimelineTextEditTests", "VocabAskFilterTests"],
                "passed": true]
    }

    // MARK: - Helpers

    private static func record(_ checks: [String: Bool], scenario: String, into errors: inout [String]) {
        for (name, passed) in checks.sorted(by: { $0.key < $1.key }) where !passed {
            errors.append("\(scenario): check failed — \(name)")
        }
    }

    private static func wait(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    struct ReplayScenarioError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
#endif
