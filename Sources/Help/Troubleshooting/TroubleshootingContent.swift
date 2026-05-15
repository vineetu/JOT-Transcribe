import SwiftUI

enum TroubleshootingCardAction: Hashable {
    case openPrivacySettings
    case openSettingsGeneral
    case restartJot
    case openSettingsAI
    case viewLog
    case copyLog
}

/// Data model for Troubleshooting-tab cards (spec v1 §7).
///
/// Eleven cards total: 8 migrated from the old flat-grid Help pane, 3 new
/// AI-specific cards. Each card carries:
///   * `id` — slug matching `Feature.bySlug(_:)`.
///   * `title` — user-facing headline.
///   * `badge` — short monospaced category.
///   * `body` — problem description and fix, kept within a reasonable prose
///     budget (single sentence to a few sentences max — some migrated cards
///     from the old HelpPane carry longer diagnostic detail by design).
///   * `expansionProse` — optional longer-form guidance revealed on tap.
///   * `inlineActions` — optional action buttons rendered inside expansion prose.
///   * `illustration` — a `@ViewBuilder` closure producing the card's SF
///     Symbol composition.
///
/// Text is preserved verbatim from the old `HelpPane.swift` catalog for the
/// 8 migrated cards so we don't lose the carefully-worded diagnostic detail.
/// The 3 new AI cards use the exact body copy from spec §7.
struct TroubleshootingCardData: Identifiable, HelpSearchable {
    let id: String
    let title: String
    let badge: String
    let body: String
    let expansionProse: String
    let inlineActions: [TroubleshootingCardAction]
    let illustration: () -> AnyView

    init(
        id: String,
        title: String,
        badge: String,
        body: String,
        expansionProse: String,
        inlineActions: [TroubleshootingCardAction] = [],
        @ViewBuilder illustration: @escaping () -> some View
    ) {
        self.id = id
        self.title = title
        self.badge = badge
        self.body = body
        self.expansionProse = expansionProse
        self.inlineActions = inlineActions
        self.illustration = { AnyView(illustration()) }
    }

    /// `HelpSearchable` conformance.
    var slug: String { id }

    /// `HelpSearchable` conformance — title + badge + body + expansion prose.
    var searchableText: [String] { [title, badge, body, expansionProse] }
}

// MARK: - Catalog

enum TroubleshootingContent {

    /// All Troubleshooting cards in display order — 8 existing followed by
    /// 3 new AI cards.
    static let cards: [TroubleshootingCardData] = [

        // -------- Existing (migrated from HelpPane) --------

        TroubleshootingCardData(
            id: "permissions",
            title: "Permissions",
            badge: "3+1",
            body: "Mic, Input Monitoring, Accessibility. Grant in System Settings → Privacy & Security.",
            expansionProse:
                "Jot needs three core permissions plus an optional Accessibility-trust promotion. "
                + "Deny any of them and the relevant features degrade gracefully — Jot never hard-"
                + "blocks a workflow. Revoke in System Settings to force the re-grant flow.",
            inlineActions: [.openPrivacySettings]
        ) {
            TSIllustration.composite(primary: "lock.shield", accent: "mic.fill")
        },

        TroubleshootingCardData(
            id: "input-monitoring-not-listed",
            title: "Jot missing from Input Monitoring?",
            badge: "manual add",
            body:
                "Symptom: you open System Settings → Privacy & Security → Input Monitoring and "
                + "Jot isn't in the list at all.",
            expansionProse:
                "Cause: macOS doesn't always auto-populate Jot in this pane on first launch — "
                + "and we can't reliably force it from the app.\n\n"
                + "Fix: in the Input Monitoring pane, click the + button below the list, choose "
                + "Applications, scroll to Jot, and add it. Then toggle the switch on. Jot will "
                + "ask you to restart so the new permission takes effect.",
            inlineActions: [.openPrivacySettings]
        ) {
            TSIllustration.composite(primary: "lock.shield", accent: "plus.circle")
        },

        TroubleshootingCardData(
            id: "modifier-required",
            title: "Chord modifiers",
            badge: "platform",
            body: "Chord shortcuts must include ⌘ ⌥ ⌃ ⇧ plus a key. Single-key triggers use Jot's separate Caps Lock/Fn/right-modifier path.",
            expansionProse:
                "This chord requirement is a macOS-level constraint, not a Jot policy. Jot's "
                + "single-key trigger type uses a separate event-monitoring path for Caps Lock, "
                + "Fn, and right-side modifier keys. Cancel (Esc) is scoped to in-flight operations "
                + "and only active while recording, transcribing, or rewriting."
        ) {
            TSIllustration.single("keyboard.badge.ellipsis")
        },

        TroubleshootingCardData(
            id: "bluetooth-redirect",
            title: "Bluetooth mic redirect",
            badge: "routing",
            body: "A connected BT headset may steal the mic route. Pick your device explicitly in Settings → General.",
            expansionProse:
                "When a Bluetooth headset connects mid-session, macOS sometimes silently reroutes "
                + "the mic to it. Jot detects the resulting zero-amplitude capture and surfaces a "
                + "specific error. Pinning your preferred input device avoids the race entirely."
        ) {
            TSIllustration.composite(primary: "airpodsmax", accent: "arrow.left.arrow.right")
        },

        TroubleshootingCardData(
            id: "shortcut-conflicts",
            title: "Shortcut conflicts",
            badge: "internal",
            body: "Jot warns when two of its hotkeys share a binding. It can't see collisions with other apps' global hotkeys.",
            expansionProse:
                "macOS doesn't expose a cross-app global hotkey registry, so Jot can only detect "
                + "conflicts within its own bindings. If a hotkey stops firing, suspect an app "
                + "you installed or updated recently — Raycast, Alfred, Keyboard Maestro, etc."
        ) {
            TSIllustration.composite(
                primary: "keyboard",
                accent: "exclamationmark.triangle.fill",
                accentColor: .orange
            )
        },

        TroubleshootingCardData(
            id: "recording-wont-start",
            title: "Recording won't start?",
            badge: "coreaudiod",
            body:
                "Symptom: you press the record hotkey and nothing happens — no pill, no audio. "
                + "After ~5 seconds Jot surfaces “Audio system isn't responding.”",
            expansionProse:
                "Cause: macOS's audio daemon (coreaudiod) can get stuck after starting the iOS "
                + "Simulator, a Bluetooth glitch, or a sleep/wake race. Jot can't unstick it "
                + "without admin rights.\n\n"
                + "Fix: open Terminal and run `sudo killall coreaudiod`. macOS will ask for your "
                + "admin password, restart the daemon in a second, and the next hotkey press will "
                + "work. Alternative: restart your Mac."
        ) {
            TSIllustration.single("waveform.slash")
        },

        TroubleshootingCardData(
            id: "hotkey-stopped-working",
            title: "Hotkey stopped working?",
            badge: "re-register",
            body:
                "Symptom: pressing ⌥, or ⌥/ produces a Unicode character (≤, ÷, …) instead of "
                + "triggering the action.",
            expansionProse:
                "Cause: another app may have grabbed the shortcut while Jot was off — macOS "
                + "silently prevents Jot from re-registering.\n\n"
                + "Fix: 1) Click “Restart Jot” in Settings → General to re-register cleanly. "
                + "2) Still broken? Settings → Shortcuts, clear the binding for that row and "
                + "reassign it. 3) Still broken? Identify the conflicting app (often Raycast, "
                + "Alfred, Keyboard Maestro, TextExpander, or something recently installed or "
                + "updated) — change the hotkey there or pick a different combo in Jot.",
            inlineActions: [.restartJot]
        ) {
            TSIllustration.single("arrow.clockwise.circle")
        },

        TroubleshootingCardData(
            id: "resetting-jot",
            title: "Resetting Jot",
            badge: "3 scopes",
            body:
                "Three ways to start over, from your settings feeling off to wiping every byte "
                + "Jot put on disk. Each relaunches Jot when you confirm.",
            expansionProse:
                "Settings & Shortcuts — clears preferences and hotkey bindings only. "
                + "Data & Recordings — wipes the entire Library plus any cached transcripts. "
                + "Permissions — revokes Jot's access and re-runs the setup wizard. All three "
                + "live under Settings → General → Reset.",
            inlineActions: [.openSettingsGeneral]
        ) {
            TSIllustration.single("arrow.counterclockwise.circle")
        },

        TroubleshootingCardData(
            id: "report-issue",
            title: "Report an issue",
            badge: "logs local",
            body:
                "Exports errors Jot has recorded on your Mac — never uploaded unless you share "
                + "the file. Find the controls in About → Troubleshooting.",
            expansionProse:
                "The log bundle includes recent errors, permission state, provider configuration "
                + "(with API keys redacted), and model download status. Review it before sending "
                + "— nothing leaves your Mac unless you attach it yourself.",
            inlineActions: [.viewLog, .copyLog]
        ) {
            TSIllustration.single("envelope")
        },

        // -------- New (AI-specific, spec §7) --------

        TroubleshootingCardData(
            id: "ai-unavailable",
            title: "AI unavailable",
            badge: "apple-intelligence",
            body:
                "Ask Jot and Cleanup require Apple Intelligence. Enable it in System Settings → "
                + "Apple Intelligence, or switch to a cloud provider in Settings → AI.",
            expansionProse:
                "Apple Intelligence is the default on macOS 26+, but it ships disabled by default "
                + "and requires a compatible Apple Silicon Mac. If you can't or don't want to "
                + "enable it, OpenAI / Anthropic / Gemini / Ollama are all drop-in alternatives.",
            inlineActions: [.openSettingsAI]
        ) {
            TSIllustration.composite(
                primary: "brain.head.profile",
                accent: "exclamationmark.triangle.fill",
                accentColor: .orange
            )
        },

        TroubleshootingCardData(
            id: "ai-connection-failed",
            title: "AI connection failed",
            badge: "cloud",
            body:
                "Your cloud provider isn't reachable. Check your API key in Settings → AI, "
                + "confirm the model name is current, and use Test Connection to diagnose. For "
                + "Ollama, make sure it's running locally.",
            expansionProse:
                "Test Connection reports the exact failure mode — DNS, auth (401), model not "
                + "found (404), or timeout. Recent breakages are usually model rename (OpenAI "
                + "retires older models) or a lapsed API key. For Ollama, check that the daemon "
                + "is running and the model has been pulled (`ollama list`)."
        ) {
            TSIllustration.composite(
                primary: "cloud",
                accent: "xmark.circle.fill",
                accentColor: .red
            )
        },

        TroubleshootingCardData(
            id: "articulate-bad-results",
            title: "Rewrite giving bad results?",
            badge: "prompt",
            body:
                "If Rewrite results feel off, the shared prompt may have been edited. Open "
                + "Settings → AI → Customize prompt and choose Reset to default. Still bad? Try "
                + "a different provider.",
            expansionProse:
                "Rewrite's branch prompts build on top of a small shared-invariants block. "
                + "Editing either can introduce regressions — Reset to default restores the "
                + "shipped text. If the defaults still misbehave, switching to a cloud provider "
                + "(OpenAI, Anthropic, Gemini) usually resolves structural-rewrite failures on "
                + "the on-device model.",
            inlineActions: [.openSettingsAI]
        ) {
            TSIllustration.composite(
                primary: "pencil.and.outline",
                accent: "arrow.uturn.backward.circle",
                accentColor: .accentColor
            )
        },
    ]
}

// MARK: - Illustrations

/// Lightweight SF Symbol compositions for Troubleshooting cards. Every
/// card renders inside a fixed 24×24 leading column (per the redesigned
/// Help spec): one primary symbol, optionally with a small secondary
/// symbol as a bottom-right overlay badge. No illustration is allowed to
/// exceed the 24pt frame — `TroubleshootingCard` clips defensively, but
/// the shape here guarantees there's nothing to clip.
enum TSIllustration {

    /// Single SF Symbol, centered in the 24pt frame.
    static func single(_ name: String) -> AnyView {
        AnyView(
            Image(systemName: name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        )
    }

    /// Primary SF Symbol with a smaller accented badge in the bottom-right.
    /// Both symbols are constrained to the same 24×24 frame; the accent is
    /// positioned inside via offset so it never bleeds past the boundary.
    static func composite(
        primary: String,
        accent: String,
        accentColor: Color = .secondary
    ) -> AnyView {
        AnyView(
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: primary)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: accent)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .offset(x: 1, y: 1)
            }
            .frame(width: 24, height: 24)
        )
    }

    // Legacy convenience — collapses a multi-symbol call site down to the
    // new single/composite contract. Kept so any remaining call site that
    // passes an array keeps compiling; prefer `single` or `composite`
    // directly for new entries.
    static func symbols(_ names: [String]) -> AnyView {
        switch names.count {
        case 0:  return single("questionmark.circle")
        case 1:  return single(names[0])
        default: return composite(primary: names[0], accent: names[1])
        }
    }
}
