import SwiftUI

/// Single source of truth for which surface the unified Jot window is
/// showing. Sidebar rows bind to this, and deep children (inline
/// "Set up AI →" links, popover "Learn more →" actions) mutate it via
/// the `\.setSidebarSelection` environment key below so navigation is
/// always a single state write, never ad-hoc window wrangling.
public enum AppSidebarSelection: Hashable {
    case home
    case library
    case settings(SettingsSubsection)
    case help
    case about
}

/// The five panes inside the expanded Settings group. Order here matches
/// the order the sidebar renders (General → Transcription → Sound → AI
/// → Shortcuts).
public enum SettingsSubsection: Hashable {
    case general
    case transcription
    case sound
    case ai
    case shortcuts
}

// MARK: - Environment key for programmatic selection changes

/// Closure children can call to change the unified window's selected
/// sidebar row. Installed by `JotAppWindow` at the split-view root so
/// any descendant view — a `.link`-styled button inside a pane, a
/// popover footer — can navigate without knowing the window topology.
private struct SetSidebarSelectionKey: EnvironmentKey {
    static let defaultValue: (AppSidebarSelection) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Programmatically change the unified window's sidebar selection.
    ///
    /// Default is a no-op so views hosted outside the unified window
    /// (previews, the Setup Wizard, tests) stay harmless when they call
    /// it. `JotAppWindow` overrides this with a real setter.
    public var setSidebarSelection: (AppSidebarSelection) -> Void {
        get { self[SetSidebarSelectionKey.self] }
        set { self[SetSidebarSelectionKey.self] = newValue }
    }
}
