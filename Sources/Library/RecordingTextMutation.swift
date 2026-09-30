import Foundation
import SwiftData
import os.log

/// **The one way a saved recording's text changes** (docs/transcript-consistency).
///
/// Every writer — the live "Did you mean…?" ask, a review pick or undo, Add to
/// Vocabulary, Edit → Done, re-transcribe, a diarized import's sliced text —
/// goes through `apply`, so the pasted, saved, reviewed, searched, and
/// labeled text can never disagree. One call:
///   1. sets `transcript` (refusing a span edit whose words have moved);
///   2. carries the speaker segments across the edit (or clears / replaces
///      them when the caller says so);
///   3. recomputes the title when it is still the auto-title of the old text
///      (a user rename is never touched);
///   4. marks an existing AI summary stale;
///   5. saves (a failed save restores this recording's fields and throws,
///      leaving every other unsaved change alone), re-indexes semantic
///      search, carries the change into an open edit session
///      (`TranscriptEditSessions`), and posts `didChangeNotification` so an
///      open detail view reloads its review list and editor.
///
/// `Recording.init` (a fresh insert) is the only other place a transcript is
/// written.
@MainActor
enum RecordingTextMutation {

    enum Edit {
        /// `range` (UTF-16, in the current transcript) becomes `replacement`.
        /// Refused unless the text at `range` is still exactly `expecting` —
        /// the caller's view of those words may be stale.
        case replace(NSRange, with: String, expecting: String)
        /// The user's own edit (Edit → Done): the whole new text.
        case handEdit(String)
        /// Fresh machine text for the same audio (re-transcribe, a diarized
        /// import's sliced text). `raw`, when given, replaces `rawTranscript`.
        case machineText(String, raw: String?)
    }

    /// What happens to the stored speaker segments.
    enum Timeline {
        /// Carry them across the edit (the default).
        case sync
        /// The caller already knows the new segments.
        case replace([SpeakerTimelineSegment])
        /// Drop them — they describe text that no longer exists.
        case clear
    }

    /// What changed, posted with `didChangeNotification` under `changeKey`.
    struct Change {
        struct Span {
            /// UTF-16 range in `oldText` that was replaced.
            let range: NSRange
            let replacement: String
        }

        let recordingID: UUID
        let oldText: String
        let newText: String
        /// Set for a `.replace` edit.
        let span: Span?
        let isMachineText: Bool

        /// An open edit draft of the same recording (written against
        /// `oldText`), carried across this change: the replaced words are
        /// replaced in the draft too when the user hasn't touched them there,
        /// so neither the user's typing nor this change is lost. Whole-text
        /// changes aren't carried (the draft IS the user's whole text).
        func rebasing(draft: String) -> String {
            guard let span else { return draft }
            let removed = (oldText as NSString).substring(with: span.range)
            let map = TextOffsetMap(old: oldText, new: draft)
            let start = map.map(span.range.location, .start)
            let end = map.map(NSMaxRange(span.range), .end)
            let draftNS = draft as NSString
            guard end >= start, end <= draftNS.length else { return draft }
            let target = NSRange(location: start, length: end - start)
            guard draftNS.substring(with: target) == removed else { return draft }
            return draftNS.replacingCharacters(in: target, with: span.replacement)
        }
    }

    static let didChangeNotification = Notification.Name("jot.recordingTextDidChange")
    static let changeKey = "change"

    private static let log = Logger(subsystem: "com.jot.Jot", category: "RecordingTextMutation")

    /// Apply `edit` to `recording` and do everything that follows from it
    /// (see the type doc). Returns `nil` — having changed nothing — when the
    /// edit is refused or changes nothing; throws — having changed nothing —
    /// when the save fails.
    @discardableResult
    static func apply(
        _ edit: Edit,
        to recording: Recording,
        in context: ModelContext,
        timeline: Timeline = .sync
    ) throws -> Change? {
        let old = recording.transcript
        let new: String
        var span: Change.Span?
        var isMachineText = false
        switch edit {
        case let .replace(range, replacement, expecting):
            let ns = old as NSString
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= ns.length,
                  ns.substring(with: range) == expecting
            else {
                log.info("span edit refused — the words at the range changed")
                return nil
            }
            new = ns.replacingCharacters(in: range, with: replacement)
            span = Change.Span(range: range, replacement: replacement)
        case .handEdit(let text):
            new = text
        case .machineText(let text, _):
            new = text
            isMachineText = true
        }
        let timelineIsSync: Bool
        if case .sync = timeline { timelineIsSync = true } else { timelineIsSync = false }
        guard new != old || isMachineText || !timelineIsSync else { return nil }

        let saved = SavedFields(recording)
        if recording.title == Recording.defaultTitle(from: old) {
            recording.title = Recording.defaultTitle(from: new)
        }
        recording.transcript = new
        switch edit {
        case .replace:
            break
        case .handEdit:
            if new != old, recording.editedAt == nil { recording.editedAt = .now }
        case .machineText(_, let raw):
            if let raw { recording.rawTranscript = raw }
            // Fresh machine output: not a hand-edited transcript, and no
            // longer pending ("Never lose audio" rows are filled here).
            recording.editedAt = nil
            recording.pendingSince = nil
        }
        switch timeline {
        case .sync:
            if new != old { carryTimeline(of: recording, from: old, to: new, span: span) }
        case .replace(let segments):
            recording.speakerTimeline = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: segments))
        case .clear:
            recording.speakerTimeline = nil
        }
        if new != old, recording.summaryText != nil { recording.summaryIsStale = true }

        do {
            try context.save()
        } catch {
            // Undo only this change: a context-wide rollback would also throw
            // away unrelated unsaved edits.
            saved.restore(to: recording)
            log.error("Saving a text change failed: \(String(describing: error))")
            Task { await ErrorLog.shared.error(component: "RecordingTextMutation", message: "SwiftData save failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            throw error
        }

        RecordingIndexer.shared?.index(recordingID: recording.id, text: new)
        let change = Change(recordingID: recording.id, oldText: old, newText: new,
                            span: span, isMachineText: isMachineText)
        TranscriptEditSessions.shared.recordingTextChanged(change)
        NotificationCenter.default.post(name: didChangeNotification, object: nil,
                                        userInfo: [changeKey: change])
        return change
    }

    /// The `Change` a `didChangeNotification` carries.
    static func change(in notification: Notification) -> Change? {
        notification.userInfo?[changeKey] as? Change
    }

    /// The fields `apply` writes, as they were before it.
    private struct SavedFields {
        let transcript: String
        let title: String
        let rawTranscript: String
        let editedAt: Date?
        let pendingSince: Date?
        let speakerTimeline: Data?
        let summaryIsStale: Bool?

        init(_ r: Recording) {
            transcript = r.transcript
            title = r.title
            rawTranscript = r.rawTranscript
            editedAt = r.editedAt
            pendingSince = r.pendingSince
            speakerTimeline = r.speakerTimeline
            summaryIsStale = r.summaryIsStale
        }

        func restore(to r: Recording) {
            r.transcript = transcript
            r.title = title
            r.rawTranscript = rawTranscript
            r.editedAt = editedAt
            r.pendingSince = pendingSince
            r.speakerTimeline = speakerTimeline
            r.summaryIsStale = summaryIsStale
        }
    }

    /// Carry the stored segments across `old` → `new`. Segments that had
    /// already diverged from the transcript are left as they are.
    private static func carryTimeline(of recording: Recording, from old: String, to new: String,
                                      span: Change.Span?) {
        guard let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data)
        else { return }
        let map = span.map { TextOffsetMap(old: old, replacing: $0.range, with: $0.replacement) }
            ?? TextOffsetMap(old: old, new: new)
        guard let segments = SpeakerTimelineTextEdit.projected(payload.segments, from: old, to: new, map: map),
              let encoded = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: segments))
        else { return }
        recording.speakerTimeline = encoded
    }
}
