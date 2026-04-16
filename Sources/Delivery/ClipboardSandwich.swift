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

    /// Post a synthetic ⌘V at the HID event tap. Caller is responsible for
    /// having written the transcript to the pasteboard first.
    ///
    /// Uses `kVK_ANSI_V` (0x09) with `.maskCommand`. `CGEventSource(nil)`
    /// is fine — we do not need to impersonate a specific HID device.
    static func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw PostError.couldNotCreateEventSource
        }
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            throw PostError.couldNotBuildKeyEvent
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Post a synthetic Return (kVK_Return = 0x24) with no modifiers.
    /// Used when the "auto-press Enter" setting is on (chat apps).
    static func postReturn() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw PostError.couldNotCreateEventSource
        }
        let rKey = CGKeyCode(kVK_Return)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: rKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: rKey, keyDown: false)
        else {
            throw PostError.couldNotBuildKeyEvent
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
