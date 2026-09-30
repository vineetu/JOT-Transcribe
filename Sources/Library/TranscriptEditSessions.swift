import AppKit
import os.log

/// **Open transcript edit sessions** (docs/transcript-consistency) — the one
/// answer to "is this recording being edited?" and the durable home of each
/// open draft.
///
/// Rules every writer lives by:
///   - An open session is never discarded by another writer. A span change
///     (`RecordingTextMutation` `.replace` — an ask answer, a review pick) is
///     carried into the draft and becomes the new baseline; whole new machine
///     text (a late diarize pass) is saved, and the draft still wins on Done —
///     the baseline stays the text the user started from, so what is learned
///     is only the user's own edit.
///   - Re-transcribe is refused while a session is open
///     (`RecordingRetranscription`).
///   - Drafts are written to disk as the user types (debounced), so a hard
///     quit loses nothing: the session is resumed when the recording is next
///     shown. A session ends only when its draft is saved (Done / leaving the
///     recording) or the recording is deleted.
@MainActor
final class TranscriptEditSessions {

    struct Session: Codable, Equatable {
        /// The text the user's edit is measured against — the saved text when
        /// Edit was pressed, moved forward by span changes carried into the
        /// draft.
        var baseline: String
        /// The text in the editor.
        var draft: String
    }

    static let shared = TranscriptEditSessions(fileURL: defaultFileURL)

    /// `~/Library/Application Support/Jot/edit-drafts.json`.
    static var defaultFileURL: URL {
        RecordingStore.audioDirectory.deletingLastPathComponent()
            .appendingPathComponent("edit-drafts.json", isDirectory: false)
    }

    private static let log = Logger(subsystem: "com.jot.Jot", category: "TranscriptEditSessions")
    /// Typing → disk delay.
    private static let saveDelay: Duration = .milliseconds(500)

    private let fileURL: URL?
    private var sessions: [UUID: Session]
    private var pendingSave: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    /// `fileURL == nil` keeps sessions in memory only (self-tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([UUID: Session].self, from: data) {
            sessions = stored
        } else {
            sessions = [:]
        }
        guard fileURL != nil else { return }
        // Quitting writes a draft still inside the typing delay.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func isOpen(_ recordingID: UUID) -> Bool { sessions[recordingID] != nil }

    func session(for recordingID: UUID) -> Session? { sessions[recordingID] }

    /// Open a session on `recording`, or resume the one already open (kept
    /// after a failed save, or restored after a quit).
    @discardableResult
    func begin(_ recording: Recording) -> Session {
        if let open = sessions[recording.id] { return open }
        let session = Session(baseline: recording.transcript, draft: recording.transcript)
        sessions[recording.id] = session
        scheduleSave()
        return session
    }

    /// The user typed.
    func updateDraft(_ draft: String, for recordingID: UUID) {
        guard var session = sessions[recordingID], session.draft != draft else { return }
        session.draft = draft
        sessions[recordingID] = session
        scheduleSave()
    }

    /// The draft was saved, or the recording is gone.
    func end(_ recordingID: UUID) {
        guard sessions.removeValue(forKey: recordingID) != nil else { return }
        saveNow()
    }

    /// A recording's saved text changed (`RecordingTextMutation`, before it
    /// posts the change). See the type doc for the rule.
    func recordingTextChanged(_ change: RecordingTextMutation.Change) {
        guard var session = sessions[change.recordingID], change.span != nil else { return }
        session.draft = change.rebasing(draft: session.draft)
        session.baseline = change.newText
        sessions[change.recordingID] = session
        scheduleSave()
    }

    /// Write any debounced draft now (quitting).
    func flush() {
        guard pendingSave != nil else { return }
        saveNow()
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL else { return }
        do {
            if sessions.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try JSONEncoder().encode(sessions).write(to: fileURL, options: [.atomic])
            }
        } catch {
            Self.log.error("Saving edit drafts failed: \(String(describing: error))")
        }
    }
}
