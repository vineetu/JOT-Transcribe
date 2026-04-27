import SwiftUI
import FluidAudio
import KeyboardShortcuts

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var firstRunState = FirstRunState.shared
    @State private var navHistory = NavigationHistory()

    var body: some Scene {
        // Unified window — single destination for Home, Settings, and Help.
        // Opened from the menu bar via "Open Jot…" (or "Settings…"
        // with forced `.settings(.general)` selection). The legacy
        // `Settings { … }` TabView scene has been retired.
        Window("Jot", id: "jot-main") {
            // `services` is a Phase-0.2 IUO assigned in
            // `applicationDidFinishLaunching`. In normal user-launched
            // runs the scene body evaluates AFTER that callback fires,
            // so the unwrap is safe. Under `xctest`'s injected-bundle
            // launch (Phase 1 harness flow tests with `host = Jot.app`)
            // the SwiftUI scene tree starts evaluating BEFORE
            // `applicationDidFinishLaunching` runs — the explicit
            // `if let` absorbs that bootstrap race. The `else` branch
            // is unreachable outside test-host launch.
            if let services = appDelegate.services {
                JotAppWindow(
                    pipeline: services.pipeline,
                    recorder: services.recorder,
                    urlSession: services.urlSession,
                    appleIntelligence: services.appleIntelligence,
                    audioCapture: services.audioCapture,
                    llmConfiguration: services.llmConfiguration,
                    navigationHistory: navHistory
                )
                    .environmentObject(firstRunState)
                    .environmentObject(services.recorder)
                    .environmentObject(services.delivery)
                    .environmentObject(PermissionsService.shared)
                    .environmentObject(services.transcriberHolder)
                    .modelContainer(services.modelContainer)
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentMinSize)
        // Trim the default SwiftUI menu bar down to the essentials. Jot's
        // entry surface is the menu-bar extra + hotkeys — the top-of-
        // screen menu is a compliance requirement for a `.regular` app,
        // not a feature we want users navigating. What remains: Jot (About
        // + Check for Updates… + Quit), File (Close Window ⌘W), Edit
        // (copy/paste/select-all, needed inside text fields), Window
        // (minimal, gone as much as AppKit lets us). Help is dropped —
        // the Help tab inside the main window is the canonical help
        // surface.
        .commands {
            AppMenuCommands(appDelegate: appDelegate)
            NavigationHistoryCommands(navHistory: navHistory)
        }
    }
}

private struct AppMenuCommands: Commands {
    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                appDelegate.services.updaterController.checkForUpdates(nil)
            }
        }
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .windowSize) {}
        CommandGroup(replacing: .windowArrangement) {}
        CommandGroup(replacing: .help) {}
        CommandGroup(replacing: .systemServices) {}
    }
}

private struct NavigationHistoryCommands: Commands {
    @Bindable var navHistory: NavigationHistory

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Back") {
                navHistory.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!navHistory.canGoBack)

            Button("Forward") {
                navHistory.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!navHistory.canGoForward)
        }
    }
}

// MARK: - Cross-scene selection routing
//
// `JotAppWindow` owns its sidebar selection state internally. Call sites
// outside its view tree (menu bar actions, the retired `openSettings()`
// environment call, future deep-links) post this notification so the
// window can update its `@State var selection` in `.onReceive(...)`.
//
// `userInfo["selection"]` carries the target `AppSidebarSelection`. The
// integration layer wires the observer inside `JotAppWindow`.
extension Notification.Name {
    static let jotWindowSetSidebarSelection = Notification.Name("jot.window.setSidebarSelection")
}
