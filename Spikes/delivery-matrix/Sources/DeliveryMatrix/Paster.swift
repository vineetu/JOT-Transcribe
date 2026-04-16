import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Clipboard sandwich: save → write → ⌘V → restore.
    /// Returns a human-readable status string for the log.
    static func paste(text: String, pressEnter: Bool) -> String {
        guard AXIsProcessTrusted() else {
            return "FAIL: Accessibility not granted — grant this binary in System Settings → Privacy → Accessibility."
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        guard wrote else {
            restore(pasteboard: pasteboard, items: savedItems)
            return "FAIL: setString returned false"
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            restore(pasteboard: pasteboard, items: savedItems)
            return "FAIL: could not create CGEventSource"
        }

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            restore(pasteboard: pasteboard, items: savedItems)
            return "FAIL: could not build key events"
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        let loc: CGEventTapLocation = .cghidEventTap
        down.post(tap: loc)
        up.post(tap: loc)

        if pressEnter {
            let returnKey = CGKeyCode(kVK_Return)
            if
                let rDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
                let rUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
            {
                // brief spacer so paste is processed before Return.
                usleep(40_000)
                rDown.post(tap: loc)
                rUp.post(tap: loc)
            }
        }

        // Restore the pasteboard after the target app has had time to consume it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restore(pasteboard: pasteboard, items: savedItems)
        }

        return "POSTED ⌘V (\(text.count) chars)\(pressEnter ? " + Return" : ""). Verify visually in the target app."
    }

    // MARK: - Pasteboard snapshot / restore

    private struct PasteItemSnapshot {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(pasteboard: NSPasteboard) -> [PasteItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteItemSnapshot(types: item.types, dataByType: dataByType)
        }
    }

    private static func restore(pasteboard: NSPasteboard, items: [PasteItemSnapshot]) {
        pasteboard.clearContents()
        let newItems: [NSPasteboardItem] = items.map { snap in
            let item = NSPasteboardItem()
            for type in snap.types {
                if let data = snap.dataByType[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        if !newItems.isEmpty {
            pasteboard.writeObjects(newItems)
        }
    }
}
