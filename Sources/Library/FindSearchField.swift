import AppKit
import SwiftUI

/// A native macOS `NSSearchField` bridged for the transcript find bar — authentic
/// rounded shape, embedded magnifier glyph, and the built-in clear-x, which
/// SwiftUI's `TextField` can't give us. Live-updates the bound query as the user
/// types; Enter runs `onSubmit` (next match), Esc runs `onCancel` (dismiss). Set
/// `focusTrigger` to move first-responder into the field when the bar appears;
/// the field flips it back to false.
struct FindSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusTrigger: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find in Transcript"
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .regular
        // The clear-button (and Return) fire the field's action — keep the binding
        // in sync (clearing sets an empty string, which recomputes matches).
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focusTrigger {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                focusTrigger = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FindSearchField
        init(_ parent: FindSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func fieldAction(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()   // Enter → next match
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()   // Esc → dismiss the whole bar (not just clear)
                return true
            default:
                return false
            }
        }
    }
}
