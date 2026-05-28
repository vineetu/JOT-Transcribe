import Foundation
import SwiftUI

/// Presentation-layer model for one row in the redesigned Shortcuts pane.
///
/// The five user-bindable actions (`SingleKey.Action.allCases`) and the
/// hard-coded Cancel row both flow through this struct so search,
/// section grouping, and badge rendering can treat them uniformly.
///
/// Why a separate model when `SingleKey.Action` already exists:
///   • `SingleKey.Action` is a storage-shape enum — what `@AppStorage` /
///     `KeyboardShortcuts` keys map to which Swift symbol. It deliberately
///     knows nothing about UI grouping, badges, search keywords, or the
///     Cancel pseudo-row.
///   • `ShortcutsRow` is a view-model — group ordering, the "When this
///     fires" badge, copy strings, and the keywords the search field
///     matches against all live here. Keeping these out of the storage
///     enum keeps the data model honest about what the user can change.
///
/// The model is pure value-type Sendable so the search filter is trivially
/// testable without spinning up SwiftUI.
struct ShortcutsRow: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A user-bindable action. Carries the underlying `SingleKey.Action`
        /// for chord-recorder + single-key-menu plumbing.
        case bindable(SingleKey.Action)
        /// The hard-coded Esc cancel row. Display-only; no user binding.
        case cancel
    }

    enum Group: String, CaseIterable, Hashable {
        case recording
        case rewrite
        case captureCancel

        var displayName: String {
            switch self {
            case .recording:     return "Recording"
            case .rewrite:       return "Rewrite"
            case .captureCancel: return "Capture & Cancel"
            }
        }
    }

    /// "When this fires" semantics — surfaces the gating contract baked
    /// into `HotkeyRouter` so users can tell at a glance which keys are
    /// claimed globally vs only while Jot is mid-pipeline.
    enum FiringContext: Hashable {
        /// Always claimed when the app is running (toggle, push-to-talk,
        /// paste last). Green dot.
        case alwaysActive
        /// Requires a non-empty text selection in the foreground app.
        /// Purple dot. Both Rewrite hotkeys.
        case needsSelection
        /// Only listened to while a cancellable pipeline is running.
        /// Gray dot. Esc.
        case duringCapture

        var label: String {
            switch self {
            case .alwaysActive:   return "Always active"
            case .needsSelection: return "Needs text selection"
            case .duringCapture:  return "During recording"
            }
        }

        var dotColor: Color {
            switch self {
            case .alwaysActive:   return .green
            case .needsSelection: return .purple
            case .duringCapture:  return .secondary
            }
        }
    }

    var id: String {
        switch kind {
        case .bindable(let action): return "bindable.\(action.rawValue)"
        case .cancel:               return "cancel"
        }
    }

    let kind: Kind
    let group: Group
    let title: String
    /// One-sentence behavior summary shown under the title. Stays short —
    /// the long-form explanation lives in the Help tab + popover.
    let subtitle: String
    let firing: FiringContext
    /// Help-tab slug the row's info-popover deep-links to. Reused from
    /// the existing anchor catalog so this redesign doesn't churn help
    /// content / chatbot grounding slugs.
    let helpAnchor: String
    /// Extra search keywords beyond the title. e.g. "caps lock", "esc",
    /// the action's existing display name so legacy muscle-memory still
    /// hits the row.
    let searchKeywords: [String]
    /// v1.13: when `true`, this row is hidden in `ShortcutsPane` while
    /// the Advanced toggle is off. Existing bindings stay registered
    /// with `KeyboardShortcuts` — Decision #2: a row hidden in Settings
    /// does NOT deactivate the user's deliberate hotkey choice.
    var isAdvanced: Bool = false

    /// Convenience: convert a `SingleKey.Action` into its row.
    static func forAction(_ action: SingleKey.Action) -> ShortcutsRow {
        switch action {
        case .toggleRecording:
            return ShortcutsRow(
                kind: .bindable(action),
                group: .recording,
                title: "Toggle Recording",
                subtitle: "Tap to start, tap again to stop.",
                firing: .alwaysActive,
                helpAnchor: "toggle-recording",
                searchKeywords: ["caps lock", "fn", "globe", "start", "stop"]
            )
        case .pushToTalk:
            return ShortcutsRow(
                kind: .bindable(action),
                group: .recording,
                title: "Push to Talk",
                subtitle: "Hold to record, release to stop and transcribe.",
                firing: .alwaysActive,
                helpAnchor: "push-to-talk",
                searchKeywords: ["hold", "ptt", "walkie"],
                isAdvanced: true
            )
        case .pasteLastTranscription:
            return ShortcutsRow(
                kind: .bindable(action),
                group: .recording,
                title: "Paste Last Result",
                subtitle: "Re-paste the most recent transcript or rewrite at the cursor.",
                firing: .alwaysActive,
                helpAnchor: "dictation",
                searchKeywords: ["paste", "last", "repeat", "transcript"],
                isAdvanced: true
            )
        case .rewriteWithVoice:
            return ShortcutsRow(
                kind: .bindable(action),
                group: .rewrite,
                title: "Rewrite with Voice",
                subtitle: "Select text, speak an instruction, paste the result back.",
                firing: .needsSelection,
                helpAnchor: "articulate-custom",
                searchKeywords: ["articulate", "voice", "rewrite", "selection"]
            )
        case .rewrite:
            return ShortcutsRow(
                kind: .bindable(action),
                group: .rewrite,
                title: "Rewrite",
                subtitle: "Tap to apply the default Rewrite prompt to selected text. Hold to open the prompt picker and choose a different one.",
                firing: .needsSelection,
                helpAnchor: "articulate-fixed",
                searchKeywords: ["articulate", "rewrite", "fix", "selection", "prompt", "picker"]
            )
        }
    }

    static let cancelRow = ShortcutsRow(
        kind: .cancel,
        group: .captureCancel,
        title: "Cancel",
        subtitle: "Stops an in-flight recording or rewrite. Not configurable.",
        firing: .duringCapture,
        helpAnchor: "cancel-recording",
        searchKeywords: ["escape", "esc", "cancel", "stop"]
    )

    /// All rows in display order: bindable rows in `SingleKey.Action`
    /// declaration order, then the Cancel pseudo-row.
    static let all: [ShortcutsRow] = SingleKey.Action.allCases.map(ShortcutsRow.forAction) + [.cancelRow]

    /// Lowercased haystack used by `ShortcutsSearchState`. Keeping this
    /// computed once per row instead of on every keystroke keeps the
    /// filter trivially fast and lets unit tests assert exact match
    /// strings.
    var searchHaystack: String {
        ([title, subtitle, firing.label, group.displayName] + searchKeywords)
            .joined(separator: " ")
            .lowercased()
    }
}
