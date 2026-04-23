import SwiftUI
import FluidAudio
import KeyboardShortcuts

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var firstRunState = FirstRunState.shared

    var body: some Scene {
        // Unified window — single destination for Home, Library, Settings,
        // and Help. Opened from the menu bar via "Open Jot…" (or "Settings…"
        // with forced `.settings(.general)` selection). The legacy
        // `Settings { … }` TabView scene has been retired.
        Window("Jot", id: "jot-main") {
            JotAppWindow()
                .environmentObject(firstRunState)
                .environmentObject(appDelegate.recorder)
                .environmentObject(appDelegate.delivery)
                .environmentObject(PermissionsService.shared)
                .environment(\.transcriber, appDelegate.pipeline.transcriber)
                .modelContainer(appDelegate.modelContainer)
        }
        .windowResizability(.contentMinSize)
        // Trim the default SwiftUI menu bar down to the essentials. Jot's
        // entry surface is the menu-bar extra + hotkeys — the top-of-
        // screen menu is a compliance requirement for a `.regular` app,
        // not a feature we want users navigating. What remains: Jot (About
        // + Quit), File (Close Window ⌘W), Edit (copy/paste/select-all,
        // needed inside text fields), Window (minimal, gone as much as
        // AppKit lets us). Help is dropped — the Help tab inside the main
        // window is the canonical help surface.
        .commands {
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
