import AppKit
import SwiftUI

/// SwiftUI wrapper around AppKit's `NSComboBox`. Pure SwiftUI can't
/// match NSComboBox's combination of:
///
///   - free-form text typing AND a populated dropdown,
///   - type-ahead filtering (set `completes = true`),
///   - arrow-key navigation through the dropdown,
///   - VoiceOver friendly out of the box.
///
/// `Picker` is dropdown-only; `TextField` is free-form-only. We need
/// both. Hence the `NSViewRepresentable`.
///
/// Binding semantics:
///   - When the user picks an item from the dropdown, the binding
///     updates immediately on `comboBoxSelectionDidChange(...)`.
///   - When the user types free-form text, the binding updates on
///     editing-end (focus leaves OR Return). This matches the
///     pattern other Jot text fields use — we don't churn AppStorage
///     on every keystroke.
struct ModelComboBox: NSViewRepresentable {
    @Binding var selection: String
    let suggestions: [String]
    let placeholder: String
    /// Disabled state mirrors the SwiftUI `.disabled(_)` modifier —
    /// when `true`, the combobox is greyed out and won't accept
    /// input. Used for the "auth failed / Ollama empty" status that
    /// the plan calls out.
    let isDisabled: Bool

    init(
        selection: Binding<String>,
        suggestions: [String],
        placeholder: String = "",
        isDisabled: Bool = false
    ) {
        self._selection = selection
        self.suggestions = suggestions
        self.placeholder = placeholder
        self.isDisabled = isDisabled
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = true
        box.completes = true
        box.numberOfVisibleItems = 8
        box.isEditable = true
        box.delegate = context.coordinator
        box.dataSource = context.coordinator
        box.placeholderString = placeholder
        box.stringValue = selection
        context.coordinator.suggestions = suggestions
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.suggestions = suggestions
        // Guard against a binding-loop: only push into the AppKit
        // control if the value actually differs. NSComboBox would
        // happily re-emit `controlTextDidChange` on every set, which
        // SwiftUI would then echo back through `selection` ad
        // infinitum.
        if box.stringValue != selection {
            box.stringValue = selection
        }
        box.placeholderString = placeholder
        box.isEnabled = !isDisabled
        box.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var parent: ModelComboBox
        var suggestions: [String] = []

        init(_ parent: ModelComboBox) {
            self.parent = parent
        }

        // MARK: - Data source

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            suggestions.count
        }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard suggestions.indices.contains(index) else { return nil }
            return suggestions[index]
        }

        func comboBox(
            _ comboBox: NSComboBox,
            completedString string: String
        ) -> String? {
            // Type-ahead completion: return the first suggestion that
            // begins with what the user typed (case-insensitive).
            // Mirrors NSComboBox's default behaviour but routed
            // through our backing list rather than NSComboBox's
            // internal-only completion table.
            suggestions.first { $0.lowercased().hasPrefix(string.lowercased()) }
        }

        func comboBox(
            _ comboBox: NSComboBox,
            indexOfItemWithStringValue string: String
        ) -> Int {
            suggestions.firstIndex(of: string) ?? NSNotFound
        }

        // MARK: - Delegate

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            // `indexOfSelectedItem` is the row the user clicked in
            // the dropdown — we look the string back up so the
            // binding gets the canonical id, not whatever was being
            // typed before the click.
            let index = box.indexOfSelectedItem
            guard suggestions.indices.contains(index) else { return }
            let picked = suggestions[index]
            if parent.selection != picked {
                parent.selection = picked
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Free-form path: commit whatever's in the field when
            // focus leaves OR the user hits Return. We don't push on
            // every keystroke to avoid AppStorage churn.
            guard let box = notification.object as? NSComboBox else { return }
            let typed = box.stringValue
            if parent.selection != typed {
                parent.selection = typed
            }
        }
    }
}
