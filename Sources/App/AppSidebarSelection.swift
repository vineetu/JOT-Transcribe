import SwiftUI

/// Single source of truth for which surface the unified Jot window is
/// showing. Sidebar rows bind to this, and deep children (inline
/// "Set up AI →" links, popover "Learn more →" actions) mutate it via
/// the `\.setSidebarSelection` environment key below so navigation is
/// always a single state write, never ad-hoc window wrangling.
public enum AppSidebarSelection: Hashable {
    case home
    /// Ask Jot — dedicated chatbot sidebar entry (macOS 26+ only; the
    /// row stays visible but disabled on older OS / Apple Silicon Macs
    /// without Apple Intelligence). Placed between Home and Settings.
    case askJot
    case settings(SettingsSubsection)
    case help
    case about
}

/// The panes inside the expanded Settings group. Order here matches the
/// order the sidebar renders (General → Transcription → Vocabulary →
/// Prompts → Sound → AI → Shortcuts).
public enum SettingsSubsection: Hashable {
    case general
    case transcription
    case vocabulary
    case prompts
    case sound
    case ai
    case shortcuts
    /// Speaker Labels piece A: identifies the device-owner voice and labels
    /// other speakers in meeting recordings. Placed between Transcription
    /// and Vocabulary in the sidebar.
    case speakerLabels
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
