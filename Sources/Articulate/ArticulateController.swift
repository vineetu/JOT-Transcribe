import AppKit
import Combine
import Foundation
import os.log

/// Controller for Jot's selection-rewrite pipeline. Two public entry points:
///
///   * `toggle()` — the "Articulate (Custom)" flow (formerly "Rewrite"):
///     capture selection via synthetic ⌘C, record a voice instruction,
///     transcribe it, route it through the classifier, hand the selection +
///     instruction to the LLM, paste the result back.
///
///   * `articulate()` — the v1.5 "Articulate" fixed-prompt flow: capture
///     selection via synthetic ⌘C, hand it to the LLM with the literal
///     instruction `"Articulate this"`, paste the result back. No voice
///     step, no classifier.
///
/// Both flows share the same selection-capture + paste-back helpers below.
@MainActor
final class ArticulateController: ObservableObject {
    /// Published state for both articulate flows. Shared with the status pill.
    ///
    /// - `capturing`: synthetic ⌘C pending / selection being resolved.
    /// - `recording`: (Articulate Custom only) mic is live for the voice instruction.
    /// - `transcribing`: (Articulate Custom only) Parakeet is turning the voice into text.
    /// - `rewriting`: LLM call in flight.
    enum ArticulateState: Equatable, Sendable {
        case idle
        case capturing
        case recording(startedAt: Date)
        case transcribing
        case rewriting
        case error(String)

        static func == (lhs: ArticulateState, rhs: ArticulateState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.capturing, .capturing),
                 (.transcribing, .transcribing), (.rewriting, .rewriting):
                true
            case (.recording(let a), .recording(let b)):
                a == b
            case (.error(let a), .error(let b)):
                a == b
            default:
                false
            }
        }
    }

    /// Hardcoded instruction for the fixed-prompt Articulate flow. Intentional
    /// verbatim wording per product choice — do not paraphrase.
    static let fixedInstruction = "Articulate this"

    @Published private(set) var state: ArticulateState = .idle {
        didSet { scheduleAutoRecoveryIfNeeded() }
    }
    @Published private(set) var lastArticulation: String?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Articulate")
    private var autoRecoveryTask: Task<Void, Never>?
    private var runningTask: Task<Void, Never>?

    private let capture: AudioCapture
    private let transcriber: Transcriber
    private let llm: LLMClient
    private let permissions: PermissionsService

    init(
        capture: AudioCapture = AudioCapture(),
        transcriber: Transcriber = Transcriber(),
        llm: LLMClient = LLMClient(),
        permissions: PermissionsService? = nil
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.permissions = permissions ?? PermissionsService.shared
    }

    // MARK: - Articulate (Custom) — voice-driven flow

    /// Articulate (Custom). Capture selection, then record a voice instruction;
    /// on the second toggle press, stop + transcribe + LLM + paste.
    func toggle() async {
        switch state {
        case .idle, .error:
            await startCapture()
        case .recording:
            await stopAndProcess()
        case .capturing, .transcribing, .rewriting:
            log.info("toggle() ignored — articulate in progress (\(String(describing: self.state)))")
        }
    }

    func cancel() async {
        runningTask?.cancel()
        runningTask = nil
        capturedSelectedText = nil
        switch state {
        case .recording:
            await capture.cancel()
            state = .idle
        case .capturing, .transcribing, .rewriting:
            state = .idle
        case .idle, .error:
            break
        }
    }

    // MARK: - Articulate — fixed-prompt flow

    /// Articulate (fixed). One-shot: grab the selection, send it to the
    /// configured LLM with the literal instruction `"Articulate this"` — no
    /// voice capture, no classifier step — and paste the result back.
    /// Reuses `captureSelection()` and `pasteReplacement(_:)` so the
    /// clipboard sandwich + synthetic paste contract stays in one place.
    func articulate() async {
        // Ignore re-entry while any articulate flow is already live.
        switch state {
        case .capturing, .recording, .transcribing, .rewriting:
            log.info("articulate() ignored — articulate in progress (\(String(describing: self.state)))")
            return
        case .idle, .error:
            break
        }

        permissions.refreshAll()

        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            state = .error("Grant Accessibility in System Settings for Articulate.")
            return
        }

        state = .capturing
        let selectedText: String
        do {
            selectedText = try await captureSelection()
        } catch let error as ArticulateError {
            state = .error(error.message)
            return
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        state = .rewriting
        let rewritten: String
        do {
            // Runs the same classifier as Articulate (Custom); "Articulate this" falls into the voice-preserving branch, which is what we want.
            rewritten = try await llm.articulate(
                selectedText: selectedText,
                instruction: Self.fixedInstruction
            )
        } catch {
            log.error("LLM articulate (fixed) failed: \(String(describing: error))")
            state = .error("Articulate failed: \(error.localizedDescription)")
            return
        }

        if !pasteReplacement(rewritten) { return }

        lastArticulation = rewritten
        state = .idle
    }

    // MARK: - Articulate (Custom) internals

    private func startCapture() async {
        permissions.refreshAll()

        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            state = .error("Grant Accessibility in System Settings for Articulate.")
            return
        }

        guard permissions.statuses[.microphone] == .granted else {
            state = .error("Microphone permission is required.")
            return
        }

        state = .capturing
        let selectedText: String
        do {
            selectedText = try await captureSelection()
        } catch let error as ArticulateError {
            state = .error(error.message)
            return
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        do {
            try await capture.start()
            state = .recording(startedAt: Date())
            runningTask = Task { @MainActor [weak self] in
                await self?.waitForToggle(selectedText: selectedText)
            }
        } catch {
            log.error("AudioCapture.start failed: \(String(describing: error))")
            state = .error("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func waitForToggle(selectedText: String) async {
        // This task lives until the user toggles again or cancels.
        // The actual processing happens in stopAndProcess() when
        // toggle() is called in .recording state. We store the
        // selected text so stopAndProcess can use it.
        self.capturedSelectedText = selectedText
    }

    private var capturedSelectedText: String?

    private func stopAndProcess() async {
        guard let selectedText = capturedSelectedText else {
            state = .error("No captured text available.")
            return
        }
        capturedSelectedText = nil
        runningTask?.cancel()
        runningTask = nil

        let recording: AudioRecording
        do {
            recording = try await capture.stop()
        } catch {
            log.error("AudioCapture.stop failed: \(String(describing: error))")
            state = .error("Recording stop failed: \(error.localizedDescription)")
            return
        }

        state = .transcribing
        let instruction: String
        do {
            try await transcriber.ensureLoaded()
            let result = try await transcriber.transcribe(recording.samples)
            instruction = result.text
        } catch TranscriberError.audioTooShort {
            state = .error(shortRecordingMessage(for: recording))
            return
        } catch TranscriberError.busy {
            state = .error("Another transcription is already running.")
            return
        } catch {
            log.error("Transcription failed: \(String(describing: error))")
            state = .error("Transcription failed: \(error.localizedDescription)")
            return
        }

        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("Could not understand the instruction.")
            return
        }

        state = .rewriting
        let rewritten: String
        do {
            rewritten = try await llm.articulate(selectedText: selectedText, instruction: instruction)
        } catch {
            log.error("LLM articulate failed: \(String(describing: error))")
            state = .error("Articulate failed: \(error.localizedDescription)")
            return
        }

        if !pasteReplacement(rewritten) { return }

        lastArticulation = rewritten
        state = .idle
    }

    // MARK: - Shared selection-capture + paste-back

    /// Small typed error so the fixed-prompt flow can translate capture
    /// failures into user-facing pill messages without leaking sandwich
    /// internals.
    private struct ArticulateError: Error { let message: String }

    /// Synthetic ⌘C → read selection → restore clipboard. Shared by both
    /// Articulate (Custom) and Articulate (fixed). Throws a human-readable
    /// `ArticulateError.message` that callers drop straight into
    /// `state = .error(...)`.
    private func captureSelection() async throws -> String {
        let snapshot = ClipboardSandwich.snapshot()
        let changeCountBefore = NSPasteboard.general.changeCount

        do {
            try ClipboardSandwich.postCommandC()
        } catch {
            ClipboardSandwich.restore(snapshot)
            throw ArticulateError(message: "Could not copy selection: \(error.localizedDescription)")
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        guard NSPasteboard.general.changeCount != changeCountBefore else {
            ClipboardSandwich.restore(snapshot)
            throw ArticulateError(message: "No text was copied. Make sure text is selected.")
        }

        let selectedText = NSPasteboard.general.string(forType: .string)
        ClipboardSandwich.restore(snapshot)

        guard let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArticulateError(message: "No text selected.")
        }
        return selectedText
    }

    /// Write `rewritten` to the clipboard, synthesize a ⌘V to paste-replace
    /// the live selection, then restore the clipboard after the target app
    /// has had a chance to consume the paste. Returns false and sets
    /// `state = .error(...)` on failure; caller returns immediately.
    @discardableResult
    private func pasteReplacement(_ rewritten: String) -> Bool {
        let snapshot = ClipboardSandwich.snapshot()
        guard ClipboardSandwich.writeString(rewritten) else {
            ClipboardSandwich.restore(snapshot)
            state = .error("Clipboard write failed.")
            return false
        }

        do {
            try ClipboardSandwich.postCommandV()
        } catch {
            ClipboardSandwich.restore(snapshot)
            state = .error("Could not paste articulated text: \(error.localizedDescription)")
            return false
        }

        // Restore clipboard after the target app has time to consume the paste.
        Task { @MainActor [snapshot] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            ClipboardSandwich.restore(snapshot)
        }
        return true
    }

    private func scheduleAutoRecoveryIfNeeded() {
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        guard case .error = state else { return }
        autoRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}
