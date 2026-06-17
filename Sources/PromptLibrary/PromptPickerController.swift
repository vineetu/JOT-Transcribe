import AppKit
import Combine
import SwiftUI
import os.log

/// Owns the Prompt Picker palette `NSPanel`, its lifecycle, and the
/// dispatch from "user picked row X" back into `RewriteController`.
///
/// Singleton instance per app graph — composition wires it up in
/// `JotComposition` after the `RewriteController` and `OverlayWindowController`
/// exist. The `HotkeyRouter` calls `open()` when the user holds the
/// `.rewrite` hotkey past the dispatcher threshold.
@MainActor
final class PromptPickerController {
    private let log = Logger(subsystem: "com.jot.Jot", category: "PromptPicker")
    private let store: PromptStore
    private let rewriteController: RewriteController?
    /// Read on every `open()` so a Settings → AI provider change between
    /// invocations is reflected in the picker's ranking. Wrapped in a
    /// closure so we don't capture a stale snapshot at construction.
    private let activeProviderProvider: @MainActor () -> String?

    private var panel: PromptPickerPanel?
    private var hostingView: NSHostingView<PromptPickerView>?
    private var viewModel: PromptPickerViewModel?
    /// Auto-close on click-outside / focus-loss is wired through this
    /// observer rather than via NSPanel's `delegate` so the controller
    /// stays decoupled from `NSWindowDelegate` plumbing.
    private var resignKeyObserver: NSObjectProtocol?
    /// AppKit-level keyDown monitor for the palette. SwiftUI's
    /// `.onKeyPress` modifier on a `TextField` doesn't see arrow keys
    /// (they're consumed by the field for cursor handling) and is
    /// unreliable for ⌥⏎ / ⌘P / ⌘W. The monitor intercepts at the panel
    /// level — letters / punctuation still flow through to the TextField
    /// for typing; navigation / apply / close / pin / preview are
    /// dispatched to the view model directly.
    private var keyMonitor: Any?

    init(
        store: PromptStore,
        rewriteController: RewriteController?,
        activeProvider: @escaping @MainActor () -> String?
    ) {
        self.store = store
        self.rewriteController = rewriteController
        self.activeProviderProvider = activeProvider
    }

    /// Show the palette. Idempotent — a second call while the picker is
    /// already open just refocuses it.
    func open() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let vm = PromptPickerViewModel(
            store: store,
            activeProvider: activeProviderProvider(),
            onApply: { [weak self] prompt in
                self?.apply(prompt)
            },
            onClose: { [weak self] in
                self?.close()
            },
            onTogglePin: { [weak self] promptID in
                self?.store.togglePin(promptID)
                self?.viewModel?.reload()
            },
            onToggleDefault: { [weak self] promptID in
                guard let self, let vm = self.viewModel else { return }
                // Preserve the focused row across the reload so the user
                // sees the "Default" marker land on the row they're on
                // rather than jumping focus back to the top of the list.
                let focused = vm.focusedPrompt?.id
                self.store.toggleDefault(promptID)
                vm.reload()
                if let focused { vm.setFocus(rowID: focused) }
            }
        )
        self.viewModel = vm

        let root = PromptPickerView(model: vm)
        let host = NSHostingView(rootView: root)
        self.hostingView = host

        let panel = PromptPickerPanel(contentView: host)
        self.panel = panel
        positionOnActiveScreen(panel)
        // Spotlight-style: panel is non-activating and just becomes
        // key. The host app stays the foreground app (its text
        // selection persists for the rewrite controller's later
        // synthetic ⌘C). Keyboard events flow to our `keyMonitor`
        // because it filters on `event.window === panel`, and a
        // non-activating panel still receives key events while it's
        // the key window.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)

        // Click-outside / focus-loss closes the palette. We watch the
        // panel's resignKey event rather than installing a global mouse
        // monitor so we don't have to reason about hit-testing the
        // palette frame ourselves.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let vm = self.viewModel,
                  let panel = self.panel,
                  event.window === panel else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // virtual key codes — stable across keyboard layouts.
            // 125=down, 126=up, 36=return, 76=keypad-enter, 53=escape,
            // 35=P, 13=W, 2=D.
            switch event.keyCode {
            case 125:
                Task { @MainActor in vm.moveFocus(by: 1) }
                return nil
            case 126:
                Task { @MainActor in vm.moveFocus(by: -1) }
                return nil
            case 36, 76:
                Task { @MainActor in
                    if mods.contains(.option) {
                        vm.togglePreview()
                    } else {
                        vm.applyFocused()
                    }
                }
                return nil
            case 53:
                Task { @MainActor in vm.close() }
                return nil
            case 35 where mods.contains(.command):
                Task { @MainActor in vm.togglePinFocused() }
                return nil
            case 2 where mods.contains(.command):
                Task { @MainActor in vm.toggleDefaultFocused() }
                return nil
            case 13 where mods.contains(.command):
                Task { @MainActor in vm.close() }
                return nil
            default:
                // Typing keys (letters / digits / punctuation, plain
                // arrow-less navigation like Home/End, ⌫, etc.) flow
                // through to SwiftUI's TextField for the search field.
                return event
            }
        }

        log.info("PromptPicker opened (\(self.store.allPrompts.count, privacy: .public) prompts)")
    }

    /// Hide the palette. Safe to call when already closed.
    func close() {
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let panel { panel.orderOut(nil) }
        self.panel = nil
        self.hostingView = nil
        self.viewModel = nil
        // Host app was never deactivated — non-activating panel — so
        // no focus restoration needed. The host app's selection state
        // is intact for the rewrite controller's synthetic ⌘C.
    }

    // MARK: - Private

    private func apply(_ prompt: Prompt) {
        store.recordUse(of: prompt.id)
        close()
        guard let rc = rewriteController else {
            log.error("PromptPicker apply: rewriteController nil — drop")
            return
        }
        Task { @MainActor in
            await rc.rewrite(systemPromptOverride: prompt.body, pickedTitle: prompt.title)
        }
    }

    /// Center the panel on the screen containing the currently-focused
    /// window (host app, NOT Jot — Jot's overlay panel is `non-activating`
    /// and shouldn't drive placement). Avoids the notch by adding a
    /// 60px top inset on screens with a notch.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let screen = preferredScreen()
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let topInset: CGFloat = (screen.safeAreaInsets.top > 0) ? 60 : 0
        let originX = frame.midX - size.width / 2
        let originY = frame.midY - size.height / 2 - topInset / 2
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func preferredScreen() -> NSScreen {
        // Prefer the screen with the active key window (host app).
        if let keyWindow = NSApp.windows.first(where: { $0.isKeyWindow }), let screen = keyWindow.screen {
            return screen
        }
        return NSScreen.main ?? (NSScreen.screens.first ?? NSScreen())
    }
}

/// Borderless floating `NSPanel` host for the picker SwiftUI view.
/// Non-activating so the host app keeps focus (the user can still type
/// into it once the picker closes), but `becomesKey == true` so the
/// picker can receive keyboard events while it's open.
final class PromptPickerPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            // Spotlight-style: `.nonactivatingPanel` lets the panel
            // become the key window without making Jot the active app.
            // Host app stays foreground, its selection persists for the
            // rewrite controller's synthetic ⌘C, and our NSEvent local
            // monitor in `PromptPickerController` picks up keyDowns
            // because the panel is key.
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.contentView = contentView
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Roundness comes from the SwiftUI view's rounded-rect background.
        // Setting the panel's own corner radius would clip the shadow.
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Esc + Cmd+W close the picker. Wired via the SwiftUI view's
    // `.onKeyPress(.escape)` and `.onKeyPress("w", modifiers: .command)`
    // handlers; we keep `cancelOperation` as a belt-and-suspenders
    // path in case the SwiftUI binding ever misses.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
