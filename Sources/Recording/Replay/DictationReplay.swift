#if DEBUG
import Combine
import FluidAudio
import JotVocabCore
import Foundation

// DEBUG-only headless dictation replay harness.
//
// Feeds a recording file into the REAL dictation pipeline as if it were the
// microphone — `VoiceInputPipeline` + the live `TranscriberHolder` factory +
// streaming Nemotron + stop + streamed/one-shot final + the vocabulary pass —
// then writes what the owner would have got as JSON and exits.
//
//   Jot.app/Contents/MacOS/Jot --jot-replay <file> --jot-replay-out <result.json>
//       [--speed 1] [--scenario plain|cancel-then-new|cold|stop-without-paste
//                    |ask-confirm|ask-keep|ask-alternate|ask-timeout|edit-then-paste-last|self-tests]
//       [--jot-replay-second <file>] [--cancel-after <seconds>]
//       [--jot-replay-sandbox <dir>] [--no-reference]
//
// Isolation (safe next to the owner's running /Applications/Jot.app):
// - Launched from `JotApp.init` before any scene, AppDelegate launch work,
//   menu bar, hotkeys, Sparkle, or onboarding exists; no NSApplication runs.
// - Models are read in place; the CTC purge-on-load-failure is disabled.
// - Model/language/vocab-enabled are READ from the owner's defaults; the
//   holder gets a registration-only suite so it can never write them.
// - `Vocabulary/` (corrections, provenance, vocabulary.txt) is copied into the
//   sandbox and `MacVocabCore.containerRoot` points there.
// - Recording files, the capture marker, and jot.log go to the sandbox. The
//   delivery scenarios (see `DeliveryReplayScenarios`) save Recording rows to
//   an in-memory SwiftData store and paste to a private pasteboard.

/// Launch-argument parsing + the sandbox root every overridden path resolves
/// under. `sandboxRoot` is `nil` unless `--jot-replay` was passed, so normal
/// Debug launches are unaffected.
enum DictationReplayEnvironment {
    static let isActive: Bool = CommandLine.arguments.contains("--jot-replay")

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

    /// Created (and seeded with a copy of the owner's `Vocabulary/`) on first
    /// access, so every consumer sees the copy by construction.
    static let sandboxRoot: URL? = {
        guard isActive else { return nil }
        let fm = FileManager.default
        let root = argument("--jot-replay-sandbox").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("jot-replay-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let realVocab = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vocabulary", isDirectory: true)
        let copy = root.appendingPathComponent("Vocabulary", isDirectory: true)
        if !fm.fileExists(atPath: copy.path), fm.fileExists(atPath: realVocab.path) {
            try? fm.copyItem(at: realVocab, to: copy)
        }
        return root
    }()
}

/// Which path produced the Nemotron final, reported by
/// `DualPipelineTranscriber` in DEBUG builds.
enum DictationReplayProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var path: String?
    nonisolated(unsafe) private static var reason: String?
    nonisolated(unsafe) private static var finishFailure: String?

    static func reset() {
        lock.withLock { path = nil; reason = nil; finishFailure = nil }
    }

    static func noteFinalPath(_ path: String, reason: String?) {
        lock.withLock { Self.path = path; Self.reason = reason }
    }

    static func noteFinishFailure(_ reason: String) {
        lock.withLock { finishFailure = reason }
    }

    static func snapshot() -> (path: String?, reason: String?, finishFailure: String?) {
        lock.withLock { (path, reason, finishFailure) }
    }
}

@MainActor
private final class ReplayPermissions: PermissionsObserving {
    let statuses: [Capability: PermissionStatus] = Dictionary(
        uniqueKeysWithValues: Capability.allCases.map { ($0, .granted) })
    func status(for capability: Capability) -> PermissionStatus { .granted }
    func refreshAll() {}
    func request(_ capability: Capability) async {}
    var statusesPublisher: AnyPublisher<[Capability: PermissionStatus], Never> {
        Just(statuses).eraseToAnyPublisher()
    }
}

enum DictationReplay {
    /// Runs the requested scenario on the main actor and never returns.
    static func runAndExit() -> Never {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        Task { @MainActor in
            let code = await DictationReplayRunner().run()
            exit(code)
        }
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }
}

@MainActor
private final class DictationReplayRunner {
    private let ownerDefaults = UserDefaults.standard
    private let holderDefaultsSuite = "com.jot.Jot.replay.\(ProcessInfo.processInfo.processIdentifier)"
    private var partialCount = 0
    private var firstPartialAt: Date?
    private var firstPartialText: String?
    private var partialCancellable: AnyCancellable?
    private var errors: [String] = []

    func run() async -> Int32 {
        guard let input = DictationReplayEnvironment.argument("--jot-replay"),
              let out = DictationReplayEnvironment.argument("--jot-replay-out"),
              let sandbox = DictationReplayEnvironment.sandboxRoot
        else {
            FileHandle.standardError.write(Data("usage: --jot-replay <file> --jot-replay-out <json>\n".utf8))
            return 2
        }
        let launchedAt = Date()
        let scenario = DictationReplayEnvironment.argument("--scenario") ?? "plain"
        let speed = DictationReplayEnvironment.argument("--speed").flatMap(Double.init) ?? 1
        let inputURL = URL(fileURLWithPath: input)
        let secondURL = DictationReplayEnvironment.argument("--jot-replay-second").map(URL.init(fileURLWithPath:)) ?? inputURL
        let cancelAfter = DictationReplayEnvironment.argument("--cancel-after").flatMap(Double.init) ?? 3
        let wantReference = !DictationReplayEnvironment.flag("--no-reference")

        var report: [String: Any] = [
            "scenario": scenario,
            "input": inputURL.path,
            "speed": speed,
            "sandbox": sandbox.path,
            "startedAt": ISO8601DateFormatter().string(from: launchedAt),
        ]

        // Owner's selection, read-only. The holder gets a registration-only
        // suite so any write it might make never reaches the owner's domain.
        let modelRaw = ownerDefaults.string(forKey: TranscriberHolder.defaultsKey)
        let languageRaw = ownerDefaults.string(forKey: TranscriberHolder.languageKey)
        let vocabEnabled = ownerDefaults.bool(forKey: "jot.vocabulary.enabled")
        let holderDefaults = UserDefaults(suiteName: holderDefaultsSuite)!
        var registered: [String: Any] = [:]
        if let modelRaw { registered[TranscriberHolder.defaultsKey] = modelRaw }
        if let languageRaw { registered[TranscriberHolder.languageKey] = languageRaw }
        holderDefaults.register(defaults: registered)
        defer { UserDefaults.standard.removePersistentDomain(forName: holderDefaultsSuite) }

        let holder = TranscriberHolder(
            cache: .shared,
            defaults: holderDefaults,
            transcriberFactory: { JotComposition.liveTranscriber(modelID: $0, language: $1) }
        )
        report["model"] = holder.activeModelID.rawValue
        report["language"] = holder.activeLanguage.rawValue
        report["vocabularyEnabled"] = vocabEnabled

        let capture = FileAudioCapture(
            recordingsDirectory: sandbox.appendingPathComponent("Recordings", isDirectory: true),
            speed: speed
        )
        report["deviceRate"] = 48_000
        report["framesPerCallback"] = 512
        let pipeline = VoiceInputPipeline(capture: capture, transcriberHolder: holder, permissions: ReplayPermissions())
        partialCancellable = StreamingPartialStore.shared.$partial.sink { [weak self] partial in
            guard let self, let partial else { return }
            self.partialCount += 1
            if self.firstPartialAt == nil {
                self.firstPartialAt = Date()
                self.firstPartialText = partial
            }
        }

        let vocabURL = sandbox.appendingPathComponent("Vocabulary/vocabulary.txt")
        // `--jot-replay-teach heard=term`: make the one learning call every
        // correction surface makes (`VocabularyLearning.apply(.correct)`)
        // against the sandbox stores before the dictation, so the replay shows
        // what the next dictation writes after that correction.
        if let teach = DictationReplayEnvironment.argument("--jot-replay-teach"),
           let eq = teach.firstIndex(of: "=") {
            let heard = String(teach[..<eq]), term = String(teach[teach.index(after: eq)...])
            let receipt = await VocabularyLearning.shared.apply(
                .correct(heard: heard, term: term, userCasing: true))
            report["taught"] = "\(heard)→\(term)"
            report["teachOutcome"] = "\(receipt.outcome)"
            let paused = await CorrectionStore.shared.pausedPairKeys()
            report["decoderPairsAfterTeach"] = DecoderVocabulary.derive(
                from: VocabularyStore.shared.terms, pausedPairKeys: paused
            ).pairs.map { "\($0.original)→\($0.term)" }
        }
        func prepareVocabulary() async {
            guard vocabEnabled else { return }
            do {
                try await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: vocabURL)
            } catch {
                errors.append("vocabulary prepare: \(error)")
            }
        }

        do {
            switch scenario {
            case "cold":
                // Mirror launch: prewarm + vocab prepare fire-and-forget, the
                // dictation starts at once while the model is still loading.
                try capture.prepareSource(inputURL)
                let probeStart = Date()
                let prewarm = Task.detached(priority: .utility) { [holder] in
                    let result = await holder.probeActiveModelOnLaunch()
                    return (result.allHealthy, Date())
                }
                let vocabTask = Task { await prepareVocabulary() }
                report["dictation"] = await dictate(pipeline: pipeline, capture: capture, holder: holder,
                                                    reference: wantReference)
                let (healthy, loadedAt) = await prewarm.value
                await vocabTask.value
                report["prewarm"] = ["healthy": healthy, "seconds": loadedAt.timeIntervalSince(probeStart)]

            case "cancel-then-new":
                try await warm(holder: holder, report: &report, prepareVocabulary: prepareVocabulary)
                try capture.prepareSource(inputURL)
                partialCount = 0
                let first = try await pipeline.startRecording(owner: .recorder)
                // Decode the second file while the first one is "talking" so
                // the new dictation can start the instant the cancel returns.
                try capture.prepareSource(secondURL)
                try await Task.sleep(for: .seconds(cancelAfter / speed))
                let cancelAt = Date()
                await pipeline.cancel(token: first)
                let cancelledAt = Date()
                report["cancel"] = [
                    "cancelAfterAudioSeconds": cancelAfter,
                    "cancelCallSeconds": cancelledAt.timeIntervalSince(cancelAt),
                    "partialsBeforeCancel": partialCount,
                    "secondInput": secondURL.path,
                ]
                report["dictation"] = await dictate(pipeline: pipeline, capture: capture, holder: holder,
                                                    reference: wantReference)

            case "ask-confirm", "ask-keep", "ask-alternate", "ask-timeout":
                let answer: ReplayPrompter.Answer = switch scenario {
                case "ask-confirm": .confirm
                case "ask-keep": .keepOriginal
                case "ask-alternate": .alternate
                default: .timeout
                }
                let stack = try DeliveryReplayScenarios.makeStack(
                    pipeline: pipeline, holder: holder, defaults: holderDefaults,
                    permissions: ReplayPermissions(), answer: answer)
                var failures: [String] = []
                report["delivery"] = await DeliveryReplayScenarios.ask(
                    answer, stack: stack, sandbox: sandbox, errors: &failures)
                errors += failures

            case "stop-without-paste":
                try await warm(holder: holder, report: &report, prepareVocabulary: prepareVocabulary)
                let stack = try DeliveryReplayScenarios.makeStack(
                    pipeline: pipeline, holder: holder, defaults: holderDefaults,
                    permissions: ReplayPermissions(), answer: .timeout)
                var failures: [String] = []
                report["delivery"] = try await DeliveryReplayScenarios.stopWithoutPasteThenDictate(
                    stack: stack, capture: capture, input: inputURL, speed: speed, errors: &failures)
                errors += failures

            case "edit-then-paste-last":
                try await warm(holder: holder, report: &report, prepareVocabulary: prepareVocabulary)
                let stack = try DeliveryReplayScenarios.makeStack(
                    pipeline: pipeline, holder: holder, defaults: holderDefaults,
                    permissions: ReplayPermissions(), answer: .timeout)
                var failures: [String] = []
                report["delivery"] = try await DeliveryReplayScenarios.editThenPasteLast(
                    stack: stack, capture: capture, input: inputURL, errors: &failures)
                errors += failures

            case "self-tests":
                report["selfTests"] = DeliveryReplayScenarios.selfTests()

            default:
                try await warm(holder: holder, report: &report, prepareVocabulary: prepareVocabulary)
                try capture.prepareSource(inputURL)
                report["dictation"] = await dictate(pipeline: pipeline, capture: capture, holder: holder,
                                                    reference: wantReference)
            }
        } catch {
            errors.append("scenario: \(error)")
        }

        // Gate verdicts / fallbacks land in the sandbox jot.log via detached
        // ErrorLog tasks; give them a beat, then attach them.
        try? await Task.sleep(for: .milliseconds(500))
        if let log = try? String(contentsOf: ErrorLog.logFileURL, encoding: .utf8) {
            report["log"] = log.split(separator: "\n").map(String.init)
        }
        report["errors"] = errors
        report["totalWallSeconds"] = Date().timeIntervalSince(launchedAt)
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
        } catch {
            FileHandle.standardError.write(Data("replay: could not write \(out): \(error)\n".utf8))
            return 1
        }
        return errors.isEmpty ? 0 : 3
    }

    private func warm(
        holder: TranscriberHolder,
        report: inout [String: Any],
        prepareVocabulary: () async -> Void
    ) async throws {
        let started = Date()
        let result = await holder.probeActiveModelOnLaunch()
        let loaded = Date()
        await prepareVocabulary()
        report["prewarm"] = [
            "healthy": result.allHealthy,
            "seconds": loaded.timeIntervalSince(started),
            "vocabularySeconds": Date().timeIntervalSince(loaded),
        ]
        if !result.allHealthy { throw ReplayError("model failed to load: \(result.failedSides)") }
    }

    /// One dictation of the prepared source: start → talk to end of file →
    /// stop → final. Then the one-shot reference over the SAME samples.
    private func dictate(
        pipeline: VoiceInputPipeline,
        capture: FileAudioCapture,
        holder: TranscriberHolder,
        reference: Bool
    ) async -> [String: Any] {
        var out: [String: Any] = [:]
        partialCount = 0
        firstPartialAt = nil
        firstPartialText = nil
        DictationReplayProbe.reset()

        let startCall = Date()
        let token: VoiceInputPipeline.Token
        do {
            token = try await pipeline.startRecording(owner: .recorder)
        } catch {
            errors.append("startRecording: \(error)")
            return out
        }
        let started = Date()
        out["startCallSeconds"] = started.timeIntervalSince(startCall)
        await capture.waitUntilExhausted()
        let stopAt = Date()
        out["talkSeconds"] = stopAt.timeIntervalSince(started)

        let result: VoiceInputPipeline.StopAndTranscribeResult
        do {
            result = try await pipeline.stopAndTranscribe(token)
        } catch {
            out["stopToFinalSeconds"] = Date().timeIntervalSince(stopAt)
            out["partialCount"] = partialCount
            let probe = DictationReplayProbe.snapshot()
            out["finalPath"] = probe.path ?? NSNull()
            out["finishFailure"] = probe.finishFailure ?? NSNull()
            errors.append("stopAndTranscribe: \(error)")
            return out
        }
        let finalAt = Date()
        let probe = DictationReplayProbe.snapshot()
        let stats = capture.stats

        out["stopToFinalSeconds"] = finalAt.timeIntervalSince(stopAt)
        out["finalText"] = result.text
        out["finalPath"] = probe.path ?? (holder.transcriber is DualPipelineTranscriber ? "unknown" : "batch")
        out["finalPathReason"] = probe.reason ?? NSNull()
        out["finishFailure"] = probe.finishFailure ?? NSNull()
        out["audioSeconds"] = result.recording.duration
        out["sampleCount"] = result.recording.samples.count
        out["watchdogBudgetSeconds"] = VoiceInputPipeline.transcribeWatchdogSeconds(forAudioDuration: result.recording.duration)
        out["partialCount"] = partialCount
        out["firstPartialAfterStartSeconds"] = firstPartialAt.map { $0.timeIntervalSince(started) } ?? NSNull()
        out["firstPartialHead"] = firstPartialText.map { Self.words($0).prefix(10).joined(separator: " ") } ?? NSNull()
        out["corrections"] = result.corrections.map(Self.json)
        out["asks"] = result.corrections.filter(\.askCandidate).map(Self.json)
        out["capture"] = [
            "callbacks": stats.callbacks,
            "droppedCallbacks": stats.droppedCallbacks,
            "deliveredSamples16k": stats.deliveredSamples16k,
            "sinkChunks": stats.sinkChunks,
            "minChunk": stats.minChunk == .max ? 0 : stats.minChunk,
            "maxChunk": stats.maxChunk,
        ]

        guard reference else { return out }
        let refStart = Date()
        do {
            let ref: TranscriptionResult
            if let dual = holder.transcriber as? DualPipelineTranscriber {
                ref = try await dual.transcribeDetachedSamples(result.recording.samples)
            } else {
                ref = try await holder.transcriber.transcribe(result.recording.samples, recordsProvenance: false)
            }
            out["referenceSeconds"] = Date().timeIntervalSince(refStart)
            out["referenceText"] = ref.text
            out["referenceCorrections"] = ref.corrections.map(Self.json)
            out["diffVsReference"] = Self.wordDiff(reference: ref.text, final: result.text)
            // Final's raw (pre-vocab, pre-cleanup) text isn't surfaced by the
            // pipeline; compare the raw one-shot against it indirectly via
            // the gated texts above.
            let head = 8
            let finalHead = Self.normalizedWords(result.text).prefix(head)
            let refHead = Self.normalizedWords(ref.text).prefix(head)
            out["headIntact"] = Array(finalHead) == Array(refHead)
            out["finalHead"] = Self.words(result.text).prefix(12).joined(separator: " ")
            out["referenceHead"] = Self.words(ref.text).prefix(12).joined(separator: " ")
        } catch {
            errors.append("reference: \(error)")
        }
        return out
    }

    // MARK: - Helpers

    private struct ReplayError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func json(_ c: VocabularyRescorerHolder.UXCorrection) -> [String: Any] {
        [
            "from": c.from,
            "to": c.to,
            "notable": c.notable,
            "askCandidate": c.askCandidate,
            "evidence": c.evidence ?? NSNull(),
            "isMerge": c.isMerge,
            "altTerm": c.altTerm ?? NSNull(),
        ]
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        words(text).map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
    }

    /// Word-level diff (exact tokens). Trims the common prefix/suffix, then
    /// an LCS over the middle; reports counts and up to 40 hunks.
    static func wordDiff(reference: String, final: String) -> [String: Any] {
        let a = words(reference), b = words(final)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let ma = Array(a[pre..<(a.count - suf)]), mb = Array(b[pre..<(b.count - suf)])
        var hunks: [[String: Any]] = []
        var deleted = 0, inserted = 0
        if !ma.isEmpty || !mb.isEmpty {
            let n = ma.count, m = mb.count
            var dp = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
            if n > 0, m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        dp[i][j] = ma[i] == mb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            var curRef: [String] = [], curFin: [String] = [], hunkAt = 0
            func flush() {
                guard !curRef.isEmpty || !curFin.isEmpty else { return }
                if hunks.count < 40 {
                    hunks.append(["refWordIndex": hunkAt, "reference": curRef.joined(separator: " "), "final": curFin.joined(separator: " ")])
                }
                curRef = []; curFin = []
            }
            while i < n || j < m {
                if i < n, j < m, ma[i] == mb[j] {
                    flush(); i += 1; j += 1
                } else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                    if curRef.isEmpty, curFin.isEmpty { hunkAt = pre + i }
                    curFin.append(mb[j]); inserted += 1; j += 1
                } else {
                    if curRef.isEmpty, curFin.isEmpty { hunkAt = pre + i }
                    curRef.append(ma[i]); deleted += 1; i += 1
                }
            }
            flush()
        }
        return [
            "identical": a == b,
            "referenceWords": a.count,
            "finalWords": b.count,
            "wordsOnlyInReference": deleted,
            "wordsOnlyInFinal": inserted,
            "hunks": hunks,
        ]
    }
}
#endif
