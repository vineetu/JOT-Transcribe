import SwiftUI

/// Root content view for the unified Jot window — the single destination
/// the menu bar's "Open Jot…" item opens (design doc §1).
///
/// Shape:
///   • `NavigationSplitView(sidebar:detail:)`
///   • Sidebar: `AppSidebar` bound to `selection`.
///   • Detail: the pane for the current selection, rendered directly.
///     Each pane owns its own scroll behavior — `Form.grouped` for
///     settings panes, `List` for Library, `ScrollView` for Home and
///     Help — so the window can be freely resized by the user and the
///     content scrolls within when the window is smaller than its
///     natural size (`.windowResizability(.contentMinSize)` in
///     `JotApp.swift`).
///
/// Deep children (inline "Set up AI →" links, popover "Learn more →"
/// footers) change the selection by calling the
/// `\.setSidebarSelection` environment closure installed here — no
/// ad-hoc window lookups, no notifications-as-state.
struct JotAppWindow: View {
    /// Buffer written by the menu bar controller BEFORE opening the
    /// window on a cold-open. Read once as the initial `@State` value so
    /// the first render already has the correct sidebar selection — this
    /// avoids a race where a `.jotWindowSetSidebarSelection` notification
    /// posted before the SwiftUI scene materialized would be dropped
    /// (the `.onReceive` observer isn't registered yet). The
    /// notification path below remains authoritative for re-selections
    /// of an already-open window.
    @MainActor static var pendingSelection: AppSidebarSelection?

    @State private var selection: AppSidebarSelection

    init() {
        let initial = JotAppWindow.pendingSelection ?? .home
        JotAppWindow.pendingSelection = nil
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            detail
        }
        .environment(\.setSidebarSelection) { newValue in
            selection = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotWindowSetSidebarSelection)) { note in
            if let newSelection = note.userInfo?["selection"] as? AppSidebarSelection {
                selection = newSelection
            }
        }
    }

    // MARK: - Detail router

    /// Concrete pane for the current selection.
    ///
    /// Pane types are owned by sibling layers (Home, Library, Settings,
    /// Help) and are wired by the integration agent once every agent
    /// has landed its files. The switch is exhaustive so adding a case
    /// to `AppSidebarSelection` is a compiler-enforced TODO here.
    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomePane()
        case .library:
            LibraryPane()
        case .settings(let sub):
            switch sub {
            case .general:       GeneralPane()
            case .transcription: TranscriptionPane()
            case .sound:         SoundPane()
            case .ai:            ArticulatePane()
            case .shortcuts:     ShortcutsPane()
            }
        case .help:
            HelpPane()
        case .about:
            AboutPane()
        }
    }
}
