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
            // `appDelegate.services` is assigned in
            // `applicationDidFinishLaunching` and `@Published` (see
            // AppDelegate). Critically, `@NSApplicationDelegateAdaptor`
            // does NOT subscribe `App.body` to the delegate's
            // `objectWillChange` even when the delegate is
            // `ObservableObject` — the App body only reads the delegate
            // once at scene init. The gate therefore lives one level
            // down inside `JotMainContent`, which holds the delegate
            // via `@ObservedObject` and re-renders when services
            // arrive. Until then the child shows a loading spinner.
            //
            // Proper-fix proposal (per-pane progressive hydration) is
            // in `docs/plans/progressive-ui-hydration.md`, scheduled
            // for review on 2026-05-16.
            JotMainContent(
                appDelegate: appDelegate,
                firstRunState: firstRunState,
                navHistory: navHistory
            )
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

private struct JotMainContent: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var firstRunState: FirstRunState
    let navHistory: NavigationHistory

    var body: some View {
        if let services = appDelegate.services {
            JotAppWindow(
                pipeline: services.pipeline,
                recorder: services.recorder,
                urlSession: services.urlSession,
                appleIntelligence: services.appleIntelligence,
                audioCapture: services.audioCapture,
                keychain: services.keychain,
                llmConfiguration: services.llmConfiguration,
                hotkeyRouter: services.hotkeyRouter,
                navigationHistory: navHistory
            )
                .environmentObject(firstRunState)
                .environmentObject(services.recorder)
                .environmentObject(services.delivery)
                .environmentObject(PermissionsService.shared)
                .environmentObject(services.transcriberHolder)
                .modelContainer(services.modelContainer)
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
