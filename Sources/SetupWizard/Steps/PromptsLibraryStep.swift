import SwiftUI

/// Step 12 — terminal teaching card introducing the curated prompt library.
///
/// Frames the *bundled* prompt set as the headline: Jot ships with a
/// hand-picked list (Fix grammar, Translate, Make it concise, …) so the
/// user doesn't have to write their own. Saving custom prompts is
/// mentioned as a footnote at the end.
///
/// The teaser strip reads live from `PromptStore.bundledPrompts` so the
/// step keeps reflecting whatever's actually shipped — no hard-coded copy
/// that goes stale when the bundled set changes.
struct PromptsLibraryStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    /// Live hotkey readout — same logic as the Prompts pane's "How to
    /// use" card. Mirrors the trigger-type + binding lookup so the
    /// wizard step shows the actual key the user has bound (or "your
    /// Rewrite hotkey" / a Shortcuts deep-link if unset).
    private struct HotkeyReadout {
        let verb: String   // "Press and hold" / "Press"
        let glyph: String? // "⌥/" / "Caps Lock" — nil when unset
    }

    private var hotkey: HotkeyReadout {
        let binding = SingleKeyMigration.effectiveBinding(for: .rewrite)
        switch binding.triggerType {
        case .chord:
            return HotkeyReadout(
                verb: "Press and hold",
                glyph: binding.chordDescription?.isEmpty == false ? binding.chordDescription : nil
            )
        case .singleKey:
            return HotkeyReadout(
                verb: "Press",
                glyph: binding.singleKey == .none ? nil : binding.singleKey.displayName
            )
        }
    }

    /// Up to 4 bundled prompt titles for the teaser strip. Reads live
    /// from the store so the strip never goes stale.
    private var teaserTitles: [String] {
        guard let store = coordinator.promptStore else { return [] }
        return Array(store.bundledPrompts.prefix(4).map(\.title))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A library of prompts, ready to use")
                    .font(.system(size: 22, weight: .semibold))
                Text("Jot ships with a curated set of prompts for the things you do most — fix grammar, translate, summarize, rewrite in a different tone. Pick one instead of speaking an instruction.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            stepsCard

            if !teaserTitles.isEmpty {
                teaserStrip
            }

            Text("Need your own? You can also save custom prompts anytime in Settings → Prompts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Finish",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: false
                )
            )
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(number: "1", body: { Text("Select the text you want to rewrite in any app.") })
            stepRow(number: "2", body: { hotkeyStepLine })
            stepRow(number: "3", body: { Text("Pick a prompt — Jot replaces the selection with the rewritten text.") })
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var hotkeyStepLine: some View {
        let readout = hotkey
        HStack(spacing: 6) {
            Text(readout.verb)
            if let glyph = readout.glyph {
                Text(glyph)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.18))
                    )
                Text("to open the prompt picker.")
            } else {
                Text("your Rewrite hotkey to open the prompt picker (set one in Settings → Shortcuts).")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stepRow<Body: View>(number: String, @ViewBuilder body: () -> Body) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
            body()
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var teaserStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Already included")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            HStack(spacing: 6) {
                ForEach(teaserTitles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
