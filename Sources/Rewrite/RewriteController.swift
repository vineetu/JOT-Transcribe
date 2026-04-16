import AppKit
import Combine
import Foundation
import os.log

@MainActor
final class RewriteController: ObservableObject {
    enum RewriteState: Equatable, Sendable {
        case idle
        case capturing
        case recording(startedAt: Date)
        case transcribing
        case rewriting
        case error(String)

        static func == (lhs: RewriteState, rhs: RewriteState) -> Bool {
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

    @Published private(set) var state: RewriteState = .idle {
        didSet { scheduleAutoRecoveryIfNeeded() }
    }
    @Published private(set) var lastRewrite: String?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Rewrite")
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

    func toggle() async {
        switch state {
        case .idle, .error:
            await startCapture()
        case .recording:
            await stopAndProcess()
        case .capturing, .transcribing, .rewriting:
            log.info("toggle() ignored — rewrite in progress (\(String(describing: self.state)))")
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

    // MARK: - Internals

    private func startCapture() async {
        permissions.refreshAll()

        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            state = .error("Grant Accessibility in System Settings for AI Rewrite.")
            return
        }

        guard permissions.statuses[.microphone] == .granted else {
            state = .error("Microphone permission is required.")
            return
        }

        state = .capturing
        let snapshot = ClipboardSandwich.snapshot()
        let changeCountBefore = NSPasteboard.general.changeCount

        do {
            try ClipboardSandwich.postCommandC()
        } catch {
            ClipboardSandwich.restore(snapshot)
            state = .error("Could not copy selection: \(error.localizedDescription)")
            return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        guard NSPasteboard.general.changeCount != changeCountBefore else {
            ClipboardSandwich.restore(snapshot)
            state = .error("No text was copied. Make sure text is selected.")
            return
        }

        let selectedText = NSPasteboard.general.string(forType: .string)
        ClipboardSandwich.restore(snapshot)

        guard let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("No text selected.")
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
            state = .error("Recording was too short.")
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
            rewritten = try await llm.rewrite(selectedText: selectedText, instruction: instruction)
        } catch {
            log.error("LLM rewrite failed: \(String(describing: error))")
            state = .error("Rewrite failed: \(error.localizedDescription)")
            return
        }

        // Deliver: write to clipboard + synthetic paste to replace the selection.
        let snapshot = ClipboardSandwich.snapshot()
        guard ClipboardSandwich.writeString(rewritten) else {
            ClipboardSandwich.restore(snapshot)
            state = .error("Clipboard write failed.")
            return
        }

        do {
            try ClipboardSandwich.postCommandV()
        } catch {
            ClipboardSandwich.restore(snapshot)
            state = .error("Could not paste rewritten text: \(error.localizedDescription)")
            return
        }

        // Restore clipboard after the target app has time to consume the paste.
        Task { @MainActor [snapshot] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            ClipboardSandwich.restore(snapshot)
        }

        lastRewrite = rewritten
        state = .idle
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
