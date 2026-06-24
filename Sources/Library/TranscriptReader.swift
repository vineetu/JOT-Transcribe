import AppKit
import SwiftUI

/// Selectable serif transcript reader with a right-click **"Add to
/// Vocabulary…"** that opens an editable mapping popover ("when Jot hears
/// <selection> → spell it as <term>"). Saving stores the selection as an alias
/// of the term, so future dictations boost it.
///
/// Why `NSTextView` (not SwiftUI `Text`): on macOS, SwiftUI's read-only `Text`
/// cannot expose its selection to a custom menu item — the right-click action
/// the user asked for requires AppKit text.
///
/// Sizing contract (the thing that bit us before): **width is an input,
/// height is an output.** The parent measures the real reading width and hands
/// it in explicitly; the view lays out at exactly that width and reports its
/// computed height back via a binding. No `sizeThatFits` / intrinsic-size
/// negotiation with SwiftUI — that negotiation was unreliable across layout
/// contexts (fine in an isolated frame, broken inside a live NavigationStack →
/// ~80pt mid-word wrapping).
struct TranscriptReader: View {
    let text: String
    /// Explicit reading-column width, measured by the parent.
    let width: CGFloat
    /// Called after a vocabulary mapping is successfully added, with the
    /// selection's character range (in the displayed transcript) and the
    /// canonical term to substitute in. The owner (which holds the SwiftData
    /// `Recording`) performs the edit + persistence; the reader stays
    /// decoupled from the model. Defaults to a no-op for contexts that don't
    /// want inline edits.
    var onReplaceSelection: (NSRange, String) -> Void = { _, _ in }
    @State private var height: CGFloat = 1

    var body: some View {
        SelectableTranscriptText(
            text: text,
            width: width,
            height: $height,
            onReplaceSelection: onReplaceSelection
        )
        .frame(width: width, height: max(height, 1), alignment: .topLeading)
    }
}

/// New York serif body font for transcript reading (falls back to system).
private func transcriptSerifFont(size: CGFloat = 15.5) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    if let desc = base.fontDescriptor.withDesign(.serif),
       let f = NSFont(descriptor: desc, size: size) {
        return f
    }
    return base
}

private struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    let width: CGFloat
    @Binding var height: CGFloat
    let onReplaceSelection: (NSRange, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> VocabSelectableTextView {
        // Use NSTextView's OWN text stack (storage/layoutManager/container) so
        // the text system is retained correctly — a hand-rolled stack whose
        // NSTextStorage is only a local would deallocate (storage is the strong
        // root). The view is width-tracking + vertically resizable; SwiftUI
        // sets the width via `.frame`, we report the height.
        let tv = VocabSelectableTextView(frame: NSRect(x: 0, y: 0, width: max(width, 1), height: 10))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = .zero
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true

        tv.onReplaceSelection = onReplaceSelection
        apply(text: text, to: tv)
        context.coordinator.textView = tv
        context.coordinator.recomputeHeight(width: width)
        return tv
    }

    func updateNSView(_ tv: VocabSelectableTextView, context: Context) {
        // Refresh the captured closure each pass: the owner's closure can close
        // over a value type (the @Bindable recording) that SwiftUI re-creates
        // across body evaluations, so a stale closure could write to an old
        // recording after sidebar navigation.
        tv.onReplaceSelection = onReplaceSelection
        context.coordinator.textView = tv
        var changed = false
        if tv.string != text {
            apply(text: text, to: tv)
            changed = true
        }
        if abs(tv.frame.width - max(width, 1)) > 0.5 {
            tv.setFrameSize(NSSize(width: max(width, 1), height: tv.frame.height))
            changed = true
        }
        if changed { context.coordinator.recomputeHeight(width: width) }
    }

    private func apply(text: String, to tv: NSTextView) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: transcriptSerifFont(),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
            ]
        )
        tv.textStorage?.setAttributedString(attr)
    }

    @MainActor
    final class Coordinator {
        let heightBinding: Binding<CGFloat>
        weak var textView: NSTextView?

        init(height: Binding<CGFloat>) { self.heightBinding = height }

        /// Lay out at the given width and publish the content height. Pushed
        /// async so we never mutate SwiftUI state inside an update pass; guarded
        /// so it can't loop.
        func recomputeHeight(width: CGFloat) {
            // Accessing `.layoutManager` opts this NSTextView into TextKit 1
            // compatibility (deterministic `usedRect`), which is what we want.
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            // Pin the width before measuring so the used height matches the
            // column we'll display at (width-tracking container follows it).
            tv.setFrameSize(NSSize(width: max(width, 1), height: tv.frame.height))
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            DispatchQueue.main.async { [weak self] in
                // Skip stale writes after this view was discarded (fast sidebar
                // navigation): the weak text view nils out when the NSView is
                // gone, so we never write into a binding whose @State backs a
                // recording we're no longer showing.
                guard let self, self.textView != nil else { return }
                if abs(self.heightBinding.wrappedValue - h) > 0.5 {
                    self.heightBinding.wrappedValue = h
                }
            }
        }
    }
}

/// `NSTextView` that adds "Add to Vocabulary…" to the read-only right-click
/// menu (only when there's a selection) and presents the mapping editor in a
/// transient popover anchored at the selection.
final class VocabSelectableTextView: NSTextView {
    /// Set by the representable. Called with the selected character range and
    /// the canonical term after a vocab mapping is successfully added, so the
    /// owner can edit + persist the transcript. The NSTextView never touches
    /// SwiftData itself.
    var onReplaceSelection: (NSRange, String) -> Void = { _, _ in }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let selection = selectedSubstring()
        guard !selection.isEmpty else { return menu }

        let item = NSMenuItem(
            title: "Add to Vocabulary…",
            action: #selector(addSelectionToVocabulary(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    /// The trimmed selected substring, or "" when nothing meaningful is selected.
    private func selectedSubstring() -> String {
        let range = selectedRange()
        guard range.length > 0,
              let ns = string as NSString?,
              range.location + range.length <= ns.length
        else { return "" }
        return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The selected range tightened to the trimmed substring — i.e. the range
    /// that exactly covers `selectedSubstring()`, with leading/trailing
    /// whitespace dropped. This is the range we replace so the substitution
    /// lands on the words, not the surrounding spaces. Returns `nil` when the
    /// selection is empty or all-whitespace.
    private func trimmedSelectedRange() -> NSRange? {
        let range = selectedRange()
        guard range.length > 0,
              let ns = string as NSString?,
              range.location + range.length <= ns.length
        else { return nil }
        // Work in UTF-16 units throughout — `selectedRange()` is UTF-16, so
        // trimming via `NSString.character(at:)` keeps the offsets consistent
        // even for non-BMP characters (a Swift `Character` count would not).
        let ws = CharacterSet.whitespacesAndNewlines
        let start = range.location
        let end = range.location + range.length
        var lead = start
        while lead < end, let scalar = Unicode.Scalar(ns.character(at: lead)), ws.contains(scalar) {
            lead += 1
        }
        var tail = end
        while tail > lead, let scalar = Unicode.Scalar(ns.character(at: tail - 1)), ws.contains(scalar) {
            tail -= 1
        }
        let length = tail - lead
        guard length > 0 else { return nil }
        return NSRange(location: lead, length: length)
    }

    /// Bounding rect of the current selection in this view's coordinates —
    /// the anchor for the popover.
    private func selectionRectInView() -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return bounds }
        let glyphRange = lm.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        return r
    }

    @objc private func addSelectionToVocabulary(_ sender: Any?) {
        let heard = selectedSubstring()
        guard !heard.isEmpty else { return }
        let anchor = selectionRectInView()
        // Capture the selection's range NOW, before the popover steals focus and
        // before the user can edit the popover's "heard" field. This frozen
        // range is the specific instance we replace on a successful add.
        let replaceRange = trimmedSelectedRange()
        let onReplace = onReplaceSelection

        let popover = NSPopover()
        popover.behavior = .transient
        let editor = VocabMappingEditor(
            heard: heard,
            onAdded: { term in
                if let replaceRange { onReplace(replaceRange, term) }
            },
            onClose: { popover.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: editor)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }
}

/// The editable "heard → spell-as" mapping form shown in the right-click
/// popover. Pre-fills the selection on the "heard" side; the user types the
/// canonical spelling. Owns the save so it can react to the store's result
/// (keep open + show why on rejection; close on success).
struct VocabMappingEditor: View {
    let heard: String
    /// Called on a successful add (`.added` or `.duplicate`) with the
    /// canonical (sanitized) term, so the host can replace the selected text
    /// in the transcript. Fires before `onClose`.
    let onAdded: (String) -> Void
    /// Dismisses the popover. Called only after a successful add.
    let onClose: () -> Void

    @State private var heardText: String
    @State private var termText: String = ""
    @State private var errorText: String?
    @FocusState private var termFocused: Bool

    /// Read once: whether boosting is on, so we can warn that a saved mapping
    /// won't take effect until it's enabled.
    private let boostingEnabled = VocabularyStore.shared.isEnabled

    init(heard: String, onAdded: @escaping (String) -> Void = { _ in }, onClose: @escaping () -> Void) {
        self.heard = heard
        self.onAdded = onAdded
        self.onClose = onClose
        _heardText = State(initialValue: heard)
    }

    /// Mirror the store's acceptance rule so the Add button can't trigger a
    /// silent rejection: non-empty term, at most `maxTermWords` words after
    /// sanitization. (The `heard` side is an arbitrary phrase — not word-capped.)
    private var canAdd: Bool {
        let term = VocabularyStore.sanitizeTerm(termText)
        guard !term.isEmpty else { return false }
        return term.split(whereSeparator: { $0 == " " }).count <= VocabularyStore.maxTermWords
    }

    private func add() {
        switch VocabularyStore.shared.addMapping(heard: heardText, term: termText) {
        case .added, .duplicate:
            // Replace the originally-selected text with the canonical spelling.
            // Use the sanitized term (what the store actually stored) so the
            // transcript matches the saved mapping.
            onAdded(VocabularyStore.sanitizeTerm(termText))
            onClose()
        case .rejected:
            errorText = "Use a single word or short phrase (max \(VocabularyStore.maxTermWords) words)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Vocabulary")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("When Jot hears")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("", text: $heardText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Spell it as")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("e.g. Vineet", text: $termText)
                    .textFieldStyle(.roundedBorder)
                    .focused($termFocused)
                    .onSubmit { if canAdd { add() } }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            } else if !boostingEnabled {
                Text("Vocabulary boosting is off — enable it in Settings → Vocabulary to apply this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else {
                Text("Future dictations will prefer this spelling.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { termFocused = true }
    }
}
