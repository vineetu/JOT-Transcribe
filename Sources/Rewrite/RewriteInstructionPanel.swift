import AppKit
import SwiftUI

/// A single canned instruction offered as a tappable "chip" in the typed
/// instruction panel. Tapping one submits its `instruction` immediately.
struct RewriteInstructionChip: Identifiable, Equatable {
    let id = UUID()
    /// Short button label shown to the user (e.g. "Formal").
    let label: String
    /// The full instruction handed to the rewrite pipeline (e.g. "Make it
    /// more formal"). Kept separate from `label` so the chip can read tersely
    /// while the LLM still gets an unambiguous instruction.
    let instruction: String
}

/// Feature flag + last-used translation language for the typed panel.
/// The flag defaults ON for every Rewrite-with-Voice path; flipping it off
/// restores the pure voice+timeout behavior (which stays fully functional
/// either way — the panel is additive, not a replacement).
enum RewriteTypedPanelSettings {
    static let enabledStorageKey = "jot.rewrite.typedPanelEnabled"
    static let lastTranslateLanguageKey = "jot.rewrite.lastTranslateLanguage"

    static var isEnabled: Bool {
        // Absent key ⇒ default ON. `object(forKey:)` distinguishes "never set"
        // (nil ⇒ true) from an explicit `false`.
        UserDefaults.standard.object(forKey: enabledStorageKey) as? Bool ?? true
    }

    static var lastTranslateLanguage: String {
        let stored = UserDefaults.standard.string(forKey: lastTranslateLanguageKey)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Spanish" : trimmed
    }
}

/// Abstraction over the typed-instruction panel so `RewriteController` can be
/// constructed without an AppKit panel in tests (the seam passes `nil`). The
/// live app injects `RewriteInstructionPanelController`.
@MainActor
protocol RewriteInstructionPresenting: AnyObject {
    /// Present the typed-instruction panel near the top-center of the active
    /// screen, taking key focus WITHOUT activating Jot (the target app stays
    /// active and keeps its selection). Returns `true` iff the panel actually
    /// became key — a `false` return is the caller's cue to degrade to the
    /// pure voice+timeout path (rare WindowServer states where a nonactivating
    /// panel can't take key).
    ///
    /// - `chips`: canned instructions. Empty when the run already has a system
    ///   prompt of its own (a picked prompt), since generic chips would fight it.
    /// - `placeholder`: what the field asks for. The caller varies this per run
    ///   — a free-form prompt on the plain path, the picked prompt's own
    ///   augment hint when it needs a specific detail.
    /// - `onFirstEdit`: fired once, on the first keystroke into the field, so
    ///   the caller can pause the mic + cancel the auto-finish timer.
    /// - `onTextChange`: fired on every edit with the field's current text, so
    ///   the caller can salvage typed text if the run resolves via a path other
    ///   than ⏎ (a second hotkey press, or the idle timeout).
    /// - `onSubmit`: the resolved instruction (typed text or a chip). Empty
    ///   string means "the user pressed ⏎ with an empty field".
    /// - `onCancel`: Esc — abort with no paste.
    @discardableResult
    func present(
        chips: [RewriteInstructionChip],
        placeholder: String,
        onFirstEdit: @escaping @MainActor () -> Void,
        onTextChange: @escaping @MainActor (String) -> Void,
        onSubmit: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> Bool

    /// Order the panel out. MUST be called BEFORE any synthetic paste so key
    /// focus returns to the target app first (focus discipline §3). Idempotent.
    func dismiss()
}

/// Key-capable, NON-activating floating panel that hosts the typed-instruction
/// SwiftUI content. Deliberately a SIBLING of `OverlayPanel` (the status pill),
/// not a modification of it: the pill is hard-built to never become key
/// (`canBecomeKey == false`) so it never steals the target app's selection,
/// whereas THIS panel's whole reason to exist is to accept keyboard input while
/// the target app stays active.
///
/// The critical AppKit contract (see `docs/plans/rewrite-instruction-ux.md`
/// §2/§3):
///   • `.nonactivatingPanel` is in the style mask AT INIT (toggling it
///     post-init is broken in AppKit).
///   • `canBecomeKey` is overridden to `true` (the pill's is `false`).
///   • `becomesKeyOnlyIfNeeded = false` so a text field inside actually gets
///     first-responder focus.
///   • The controller calls `makeKeyAndOrderFront` — NEVER `NSApp.activate` —
///     so the app that owns the user's selection is never deactivated.
final class RewriteInstructionPanel: NSPanel {
    /// Backstop Esc handler. The SwiftUI content also wires `.onExitCommand`,
    /// but focus can legitimately sit off the text field (e.g. right after a
    /// chip click), so the panel itself catches `cancelOperation` too.
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            // `.nonactivatingPanel` MUST be set here — AppKit ignores it if
            // toggled after init. `.borderless` keeps the chrome clean; the
            // SwiftUI content draws the rounded material card.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        // Window-server shadow traces the material card's alpha shape — this
        // panel floats away from the screen edge (unlike the notch pill), so
        // there's no clipping artifact and the native shadow reads correctly.
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        // The whole point: let a text field inside become first responder the
        // moment the panel is shown, without waiting for a click.
        self.becomesKeyOnlyIfNeeded = false
        self.worksWhenModal = true
        // Appear over full-screen spaces too, and don't get cycled by ⌘`.
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.animationBehavior = .utilityWindow
    }

    // The pill panel returns `false` here; this one returns `true`. That single
    // override — plus `.nonactivatingPanel` in the mask — is what lets the panel
    // take key focus without activating Jot.
    override var canBecomeKey: Bool { true }
    // Still never main: we don't want Jot to be treated as the active app.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Owns the `RewriteInstructionPanel` lifecycle and bridges its SwiftUI content
/// callbacks back to `RewriteController`. One instance is created in
/// composition and injected into `RewriteController`.
@MainActor
final class RewriteInstructionPanelController: RewriteInstructionPresenting {
    private var panel: RewriteInstructionPanel?

    init() {}

    @discardableResult
    func present(
        chips: [RewriteInstructionChip],
        placeholder: String,
        onFirstEdit: @escaping @MainActor () -> Void,
        onTextChange: @escaping @MainActor (String) -> Void,
        onSubmit: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> Bool {
        // Reuse a single panel instance across invocations; rebuild its content
        // each time so the per-run callbacks are fresh.
        let panel = self.panel ?? RewriteInstructionPanel()
        self.panel = panel
        panel.onCancel = onCancel

        let root = RewriteInstructionPanelView(
            chips: chips,
            placeholder: placeholder,
            onFirstEdit: onFirstEdit,
            onTextChange: onTextChange,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        let fitting = hosting.fittingSize
        let size = NSSize(width: 400, height: max(fitting.height, 96))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.contentView = hosting

        positionPanel(panel, size: size)

        // Key WITHOUT activation: the target app stays frontmost and keeps its
        // text selection. `orderFrontRegardless` first so a nonactivating panel
        // reliably reaches the screen even while another app is active, THEN
        // `makeKey` to route keyboard input to it.
        panel.orderFrontRegardless()
        panel.makeKey()

        // Fallback detection (§3 item 4): if the panel could not become key
        // (rare WindowServer states), report it so the caller degrades to the
        // pure voice+timeout flow. `makeKey` sets `isKeyWindow` synchronously
        // for a panel that CAN become key, so this read is reliable.
        return panel.isKeyWindow
    }

    func dismiss() {
        // Ordering out resigns key; AppKit restores key to the previously key
        // window — which, because we never activated Jot, is the target app's
        // window. Only after that does the caller fire the synthetic ⌘V.
        panel?.onCancel = nil
        panel?.orderOut(nil)
    }

    private func positionPanel(_ panel: RewriteInstructionPanel, size: NSSize) {
        let screen = NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - size.width / 2
        // Sit in the upper third — un-obtrusive, near where the pill lives, but
        // clear of the very top so the material card + shadow read cleanly.
        let y = frame.maxY - size.height - 140
        panel.setFrameOrigin(NSPoint(x: x, y: max(frame.minY + 12, y)))
    }
}
