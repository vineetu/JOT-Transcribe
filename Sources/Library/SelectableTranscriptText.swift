import AppKit
import SwiftUI

/// Read-only, selectable transcript renderer that exposes the *selected
/// substring* to a custom context menu — the thing a plain SwiftUI
/// `Text` + `.textSelection(.enabled)` cannot do (SwiftUI never hands the
/// selected range to a `.contextMenu`).
///
/// Used only for the normal recording-detail transcript path (not the raw
/// or speaker-labeled paths, which keep the plain `Text`). It draws to
/// match the `Text` it replaces: 13 pt monospaced, 4 pt line spacing,
/// primary label color, full-width left-aligned. Copy and click-drag
/// selection work exactly like the native text view.
///
/// The "Add to Vocabulary" item is the Q2 recourse (docs/vocabulary-gate/
/// ask-ux.md §5): the user selects a name the gate never proposed and adds
/// it so future dictations boost it. The menu reads
/// `textView.selectedRange()` at click time and hands the substring to
/// `onAddToVocabulary` — it never edits the transcript.
struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    /// Invoked with the trimmed selected substring when the user picks
    /// "Add to Vocabulary". Empty/whitespace selections are filtered out
    /// before this fires (the menu item disables itself).
    let onAddToVocabulary: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAddToVocabulary: onAddToVocabulary)
    }

    func makeNSView(context: Context) -> SelectionMenuTextView {
        // We host the `NSTextView` *directly* (no wrapping `NSScrollView`) so
        // its measured content height flows back to SwiftUI through
        // `sizeThatFits`. The outer SwiftUI `ScrollView` (in the recording-
        // detail GroupBox) then owns scrolling — exactly like the plain
        // `Text` this view replaced. A wrapping `NSScrollView` would report
        // no intrinsic height, so a transcript taller than the GroupBox's
        // 320 pt cap would clip with no way to scroll.
        let textView = SelectionMenuTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Wrap to the proposed width; never grow horizontally.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.coordinator = context.coordinator

        context.coordinator.textView = textView
        apply(text: text, to: textView)
        return textView
    }

    func updateNSView(_ textView: SelectionMenuTextView, context: Context) {
        context.coordinator.onAddToVocabulary = onAddToVocabulary
        textView.coordinator = context.coordinator
        if textView.string != text {
            apply(text: text, to: textView)
            // Text changed → height changed; force SwiftUI to re-measure.
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// Report the height the text needs at the proposed width so the outer
    /// SwiftUI `ScrollView` grows this view to its full content height and
    /// scrolls when it exceeds the GroupBox's `maxHeight`. macOS 13+.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelectionMenuTextView,
        context: Context
    ) -> CGSize? {
        guard
            let textContainer = nsView.textContainer,
            let layoutManager = nsView.layoutManager
        else { return nil }

        // Width to lay out at: the SwiftUI-proposed width, falling back to
        // the view's current width when unspecified. Height is driven by
        // content, so we always propose the measured height back.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.bounds.width
        guard width > 0 else { return nil }

        // Lay the container out at the target width, then read the used rect.
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = nsView.textContainerInset
        let height = ceil(used.height + inset.height * 2)
        return CGSize(width: width, height: height)
    }

    private func apply(text: String, to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        // Matches SwiftUI `.lineSpacing(4)`.
        paragraph.lineSpacing = 4
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        textView.textStorage?.setAttributedString(attributed)
    }

    @MainActor
    final class Coordinator {
        var onAddToVocabulary: (String) -> Void
        weak var textView: NSTextView?

        init(onAddToVocabulary: @escaping (String) -> Void) {
            self.onAddToVocabulary = onAddToVocabulary
        }

        /// The current selection, trimmed. Empty when nothing meaningful
        /// is selected — the menu item gates on this.
        func trimmedSelection() -> String {
            guard let textView else { return "" }
            let range = textView.selectedRange()
            guard range.length > 0,
                  let ns = textView.string as NSString?,
                  range.location + range.length <= ns.length
            else { return "" }
            return ns.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @objc func addSelectionToVocabulary(_ sender: Any?) {
            let selection = trimmedSelection()
            guard !selection.isEmpty else { return }
            onAddToVocabulary(selection)
        }
    }
}

/// `NSTextView` subclass that prepends "Add to Vocabulary" to the standard
/// read-only context menu (Copy / Look Up / etc. stay intact). The item
/// targets the SwiftUI coordinator, which reads the live selection.
final class SelectionMenuTextView: NSTextView {
    weak var coordinator: SelectableTranscriptText.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator else { return menu }

        let selection = coordinator.trimmedSelection()
        // Only offer the item when there's a real selection to add. Keep
        // the title short; truncate a long selection so the menu doesn't
        // stretch. (Overlong selections are also rejected later by
        // VocabularyStore.addTerm, but trimming the title keeps the menu
        // tidy in the meantime.)
        let display = selection.count > 32
            ? String(selection.prefix(32)) + "\u{2026}"
            : selection
        let title = selection.isEmpty
            ? "Add to Vocabulary"
            : "Add \u{201C}\(display)\u{201D} to Vocabulary"
        let item = NSMenuItem(
            title: title,
            action: #selector(SelectableTranscriptText.Coordinator.addSelectionToVocabulary(_:)),
            keyEquivalent: ""
        )
        item.target = coordinator
        item.isEnabled = !selection.isEmpty

        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}
