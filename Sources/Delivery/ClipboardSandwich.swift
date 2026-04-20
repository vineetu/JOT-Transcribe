import AppKit
import Carbon.HIToolbox
import Foundation

/// The synthetic-paste mechanism, isolated from policy so it stays
/// unit-level testable and so the clipboard-only fallback can reuse
/// `snapshot` / `write` without pulling in the CGEvent path.
///
/// Threading: CGEvent posting has thread affinity. Every function here is
/// main-actor-isolated; callers in other actors must hop to `MainActor`
/// before invoking.
@MainActor
enum ClipboardSandwich {
    /// A structural copy of the pasteboard contents at a moment in time.
    /// We use full `NSPasteboardItem` data-per-type snapshots rather than
    /// `pasteboardItems` references because NSPasteboard reclaims those
    /// once `clearContents()` is called.
    struct Snapshot: Sendable {
        fileprivate let items: [ItemSnapshot]
        fileprivate let changeCount: Int

        fileprivate struct ItemSnapshot: Sendable {
            let types: [NSPasteboard.PasteboardType]
            let dataByType: [NSPasteboard.PasteboardType: Data]
        }
    }

    enum PostError: Error {
        case couldNotCreateEventSource
        case couldNotBuildKeyEvent
        case pasteboardWriteFailed
    }

    // MARK: - Snapshot / write / restore

    static func snapshot(pasteboard: NSPasteboard = .general) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> Snapshot.ItemSnapshot in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return Snapshot.ItemSnapshot(types: item.types, dataByType: dataByType)
        }
        return Snapshot(items: items, changeCount: pasteboard.changeCount)
    }

    @discardableResult
    static func writeString(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func restore(_ snapshot: Snapshot, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { snap in
            let item = NSPasteboardItem()
            for type in snap.types {
                if let data = snap.dataByType[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Synthetic paste

    /// Post a synthetic ⌘V to the user's session event tap. Caller is
    /// responsible for having written the transcript to the pasteboard
    /// first.
    ///
    /// Why `.cgSessionEventTap` + local-event suppression: when this path
    /// is triggered by a global hotkey (e.g. Paste Last Transcription
    /// bound to ⌥V), the user's physical modifier keys are usually still
    /// held down at the moment we fire the synthetic ⌘V. Posting at
    /// `.cghidEventTap` without suppression lets those physical modifiers
    /// merge with our event — the target app sees ⌘⌥V (not a paste) and
    /// silently ignores the keystroke. Filtering local keyboard events
    /// for the suppression interval while we post keeps the synthetic
    /// ⌘V intact even if keys are still physically down.
    static func postCommandV() throws {
        try postShortcut(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    /// Post a synthetic ⌘C. Used by ArticulateController to grab the
    /// current selection before recording the instruction. Same
    /// hold-down-modifier hazard applies as `postCommandV`.
    static func postCommandC() throws {
        try postShortcut(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    /// Post a synthetic Return with no modifiers. Used when the
    /// "auto-press Enter" setting is on (chat apps).
    static func postReturn() throws {
        try postShortcut(virtualKey: CGKeyCode(kVK_Return), flags: [])
    }

    private static func postShortcut(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw PostError.couldNotCreateEventSource
        }
        // Suppress user-originated keyboard events for the brief window
        // in which we post the synthetic keystroke. Mouse + system
        // events keep flowing normally.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            throw PostError.couldNotBuildKeyEvent
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
