import SwiftUI

// MARK: - Data model

/// Hero concept rendered at the top of each Basics section.
///
/// One per hero concept (Dictation, Cleanup, Rewrite). The `id` is the
/// canonical slug from redesign spec §14 — `"dictation"`, `"cleanup"`,
/// `"articulate"` (legacy slug preserved by rename migration to keep deep-
/// links stable) — so phase1c's Feature registry and the chatbot's
/// `ShowFeatureTool` land at the same anchor.
///
/// `subtitle` is hard-capped at 120 characters by `BasicsContent.validate()`.
/// Overflow surfaces visually in `#if DEBUG` via `BudgetOverflowModifier`.
struct Hero: Identifiable {
    /// Canonical slug. Must match `Feature.slug` in phase1c's registry.
    let id: String
    let title: String
    /// ≤120 chars. Two-line cap enforced in HeroCard via `.lineLimit(2)`.
    let subtitle: String
    let isOptional: Bool
    let illustrationKind: HeroIllustrationKind
    let subRows: [SubRow]
    let conditionalAction: ConditionalAction?
}

/// Row beneath a hero card — may or may not expand.
///
/// Plain rows (`isExpandable == false`) have no chevron, no tap handler, and
/// no hover highlight. They render visibly (per spec §10 smoke #5) but
/// the user never clicks them. Their `detail` is `nil` and rendered inert.
struct SubRow: Identifiable {
    /// Canonical slug matching phase1c's `Feature.slug`.
    let id: String
    /// ≤4 words.
    let name: String
    /// `nil` when the row has no associated keyboard shortcut.
    let shortcutChip: [String]?
    let isExpandable: Bool
    /// Non-nil iff `isExpandable == true`.
    let detail: SubRowDetailContent?
}

/// Body of an expanded sub-row. All four decoration slots are optional;
/// only `prose` is required. `customContent` is the escape hatch for the
/// multilingual language grid.
struct SubRowDetailContent {
    /// 1–2 sentences. Soft-budgeted at ≤400 chars for reasonableness.
    let prose: String
    let inlineTip: InlineTip?
    let warning: String?
    let settingsLink: SettingsLink?
    /// Caller-owned custom content (e.g. the 25-language grid). Using
    /// `AnyView` here is a deliberate spec-prescribed escape hatch
    /// (redesign §3 data model).
    let customContent: AnyView?

    init(
        prose: String,
        inlineTip: InlineTip? = nil,
        warning: String? = nil,
        settingsLink: SettingsLink? = nil,
        customContent: AnyView? = nil
    ) {
        self.prose = prose
        self.inlineTip = inlineTip
        self.warning = warning
        self.settingsLink = settingsLink
        self.customContent = customContent
    }
}

/// "Chip + text" decoration used inside an expanded sub-row detail.
struct InlineTip {
    /// Monospaced pill text (e.g. `⌥Space`, `voice`). Rendered via
    /// `ShortcutChip` so it matches the chip styling used elsewhere.
    let chip: [String]
    let description: String
}

/// "Open in Settings →" affordance inside an expanded sub-row detail.
struct SettingsLink {
    let label: String
    let pane: SettingsSubsection
    let anchor: String?
}

/// Button rendered at the bottom of a hero card when `shouldShow()` is
/// true. Used for conditional CTAs like "Set up AI →" that appear only
/// when the state is incomplete.
struct ConditionalAction {
    let label: String
    let shouldShow: () -> Bool
    let perform: () -> Void
}

enum HeroIllustrationKind {
    case dictation
    case cleanup
    case rewrite
    case prompts
}

// MARK: - HelpSearchable conformance

/// Hero surface — searchable text is title + subtitle. Sub-row matches are
/// handled by `HelpSearchState.shouldShowHero(_:subRows:)` in the tab view.
extension Hero: HelpSearchable {
    var slug: String { id }

    var searchableText: [String] {
        [title, subtitle]
    }
}

/// Sub-row surface — searchable text spans name + prose + inline tip
/// description + warning + settings-link label.
extension SubRow: HelpSearchable {
    var slug: String { id }

    var searchableText: [String] {
        var fields: [String] = [name]
        if let detail {
            fields.append(detail.prose)
            if let warning = detail.warning { fields.append(warning) }
            if let tip = detail.inlineTip {
                fields.append(tip.description)
                fields.append(contentsOf: tip.chip)
            }
            if let link = detail.settingsLink { fields.append(link.label) }
        }
        if let chip = shortcutChip {
            fields.append(contentsOf: chip)
        }
        return fields
    }
}

// MARK: - Budgets

/// Hard and soft character budgets, enforced by `BasicsContent.validate()`
/// at init and by the `BudgetOverflowModifier` in `#if DEBUG`.
enum BasicsBudget {
    /// Hero subtitle — hard cap from redesign §5.
    static let heroSubtitle: Int = 120
    /// Sub-row prose — soft cap (kept under this for readability).
    static let subRowProse: Int = 400
    /// Sub-row name — soft cap of 4 words.
    static let subRowNameWords: Int = 4
}

// MARK: - Static catalog

/// Single source of truth for the Basics-tab heroes and their sub-rows.
///
/// Keep this under the budgets in `BasicsBudget`. A `#if DEBUG` initializer
/// on `heroes` iterates the catalog and `assert`s budget compliance, so
/// any overflow trips during development rather than slipping into ship.
///
struct BasicsContent {

    // MARK: Catalog

    static let heroes: [Hero] = [

        // ---------------- Dictation ----------------

        Hero(
            id: "dictation",
            title: "Dictation",
            subtitle: "Press the hotkey, speak, and text appears where your cursor is. Works in any app, fully on-device.",
            isOptional: false,
            illustrationKind: .dictation,
            subRows: [
                SubRow(
                    id: "toggle-recording",
                    name: "Toggle recording",
                    shortcutChip: ["Caps Lock"],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Press once to start, press again to stop and transcribe. Works in any app, in any field with focus.",
                        inlineTip: InlineTip(
                            chip: ["Caps Lock"],
                            description: "Default single-key trigger — rebind in Settings → Shortcuts"
                        ),
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .shortcuts,
                            anchor: "toggle-recording"
                        )
                    )
                ),
                SubRow(
                    id: "push-to-talk",
                    name: "Push to talk",
                    shortcutChip: ["hold"],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Hold the shortcut to record, release to transcribe. Useful when you want precise control over when Jot is listening.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .shortcuts,
                            anchor: "push-to-talk"
                        )
                    )
                ),
                SubRow(
                    id: "cancel-recording",
                    name: "Cancel recording",
                    shortcutChip: ["esc"],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Press Esc to discard without transcribing. Active only while recording so it doesn't steal Esc from other apps when you're not dictating.",
                        warning: "Esc is hardcoded, not configurable. Chord shortcuts must include a modifier; single-key triggers use Jot's separate Caps Lock / Fn / right-modifier / function-key (F1–F20) path. Heads up: F1–F12 only reach Jot when “Use F1, F2, etc. as standard function keys” is on in System Settings → Keyboard — otherwise hold Fn. F13–F20 always work but aren't on every keyboard."
                    )
                ),
                SubRow(
                    id: "any-length",
                    name: "Any-length recordings",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "No hard time limit — dictate for as long as you need. Quality gradually diminishes for recordings longer than about an hour, so shorter sessions work best."
                    )
                ),
                SubRow(
                    id: "on-device-transcription",
                    name: "On-device transcription",
                    shortcutChip: ["ANE"],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Jot's local transcription models run on the Apple Neural Engine via FluidAudio. Audio never leaves the Mac. The default multilingual + live-preview bundle downloads on first use, about 1.85 GB."
                    )
                ),
                SubRow(
                    id: "multilingual",
                    name: "Multilingual (25 langs)",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Parakeet auto-detects the language on each recording. Supported today:",
                        customContent: AnyView(MultilingualGrid())
                    )
                ),
                SubRow(
                    id: "languages",
                    name: "Languages",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "You pick a language, not a model — Jot loads the right transcription model for you (Settings → Transcription, or during setup). English uses an English-optimized model for best accuracy; the European languages share Jot's multilingual model; Japanese is a separate download. Only the active model is kept hot in memory.",
                        warning: "Custom Vocabulary applies only to European-language transcription. The Japanese model uses a different tokenizer, so vocabulary boosts are not applied when Japanese is selected.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .transcription,
                            anchor: "transcription-language"
                        )
                    )
                ),
                SubRow(
                    id: "transcription-language",
                    name: "Transcription language",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Pick the language you speak in Settings → Transcription; Jot downloads and loads the right on-device model automatically. English uses Parakeet v2; 25 European languages share Parakeet v3 with a script hint; Japanese is a separate model. You never choose a model directly — the exact model in use is shown in About → Acknowledgements.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .transcription,
                            anchor: "transcription-language"
                        )
                    )
                ),
                SubRow(
                    id: "custom-vocabulary",
                    name: "Custom vocabulary (experimental)",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "A short list of names, acronyms, or jargon Jot should prefer during transcription. Useful when 'Leena' keeps getting transcribed as 'Lena', or 'kubectl' becomes 'cube cuddle'. Marked experimental because the rescoring pipeline only applies to certain transcription models; saved terms persist and re-engage when you switch to a supported model.",
                        warning: "Vocabulary entries override similar-sounding words. Adding many entries that sound alike causes unpredictable preference among them. Keep the list focused.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .vocabulary,
                            anchor: "custom-vocabulary"
                        )
                    )
                ),
            ],
            conditionalAction: nil
        ),

        // ---------------- Cleanup ----------------

        Hero(
            id: "cleanup",
            title: "Cleanup",
            subtitle: "Optional AI pass that removes fillers, fixes grammar, and preserves your voice. Runs after transcription.",
            isOptional: true,
            illustrationKind: .cleanup,
            subRows: [
                SubRow(
                    id: "cleanup-providers",
                    name: "Choose a provider",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Pick who does the AI work — the setup wizard asks you to choose, with no default pre-selected. Apple Intelligence is on-device, private, and free (no API key). Cloud providers (OpenAI, Anthropic, Gemini) deliver strong results with your own key. Ollama runs locally.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .ai,
                            anchor: "ai-provider"
                        )
                    )
                ),
                SubRow(
                    id: "cleanup-prompt",
                    name: "Editable prompt",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "The default cleanup prompt removes fillers, fixes grammar and punctuation, and preserves your voice. Power users can rewrite it; a reset-to-default restores the shipped version.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .ai,
                            anchor: "cleanup-prompt"
                        )
                    )
                ),
                SubRow(
                    id: "cleanup-fallback",
                    name: "Graceful fallback on failure",
                    shortcutChip: nil,
                    isExpandable: false,
                    detail: nil
                ),
                SubRow(
                    id: "cleanup-raw-preserved",
                    name: "Raw + cleaned both saved",
                    shortcutChip: nil,
                    isExpandable: false,
                    detail: nil
                ),
            ],
            conditionalAction: nil
        ),

        // ---------------- Rewrite ----------------

        Hero(
            id: "prompts",
            title: "Prompts",
            subtitle: "Optional. Pick a prompt from a library of 30+ instructions, apply it to selected text. Rewrite is the default prompt.",
            isOptional: true,
            illustrationKind: .prompts,
            subRows: [
                SubRow(
                    id: "prompt-library",
                    name: "Browse the library",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "30+ bundled prompts ship with Jot, grouped into Essentials, Convert, Email, Rewrite, Code, and Translate. Tap a row to read the full prompt, see sample input/output, and check provider compatibility. Bundled prompts are read-only; the library lives in Settings → Prompts.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .prompts,
                            anchor: "prompt-library"
                        )
                    )
                ),
                SubRow(
                    id: "prompt-picker",
                    name: "Use a prompt",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Select text, then open the prompt picker via the Rewrite hotkey path that's configured for picker mode. Pinned and recently-used prompts float to the top; search by title or category. Picking a row applies that prompt's instructions to your selection instead of the default Rewrite behavior."
                    )
                ),
                SubRow(
                    id: "articulate-fixed",
                    name: "Default Rewrite",
                    shortcutChip: ["⌥", "/"],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "The default prompt: select text, press ⌥/, and Jot applies a fixed 'Rewrite this' instruction. No voice step, no picker — useful when you just want a quick polish pass without choosing anything.",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .shortcuts,
                            anchor: "articulate-fixed"
                        )
                    )
                ),
                SubRow(
                    id: "articulate-custom",
                    name: "Rewrite with Voice",
                    shortcutChip: ["⌥", "."],
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Select text, press ⌥., speak an instruction like 'make this formal' or 'translate to Japanese'. A deterministic intent classifier routes your instruction into one of four branches (voice-preserving, structural, translation, code) and picks a minimal tendency on top of the shared prompt — your spoken instruction stays the primary signal.",
                        inlineTip: InlineTip(
                            chip: ["⌥", "."],
                            description: "Default chord — rebind in Settings → Shortcuts"
                        ),
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .shortcuts,
                            anchor: "articulate-custom"
                        )
                    )
                ),
                SubRow(
                    id: "prompt-author",
                    name: "Author your own",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Add your own prompts under Settings → Prompts → 'My prompts'. Title and body are required; sample input/output are optional. ✨ Generate sample asks your configured AI provider to fill the samples — first a plausible input, then run the prompt against it for the output. User prompts stay local (SwiftData on this Mac).",
                        settingsLink: SettingsLink(
                            label: "Open in Settings",
                            pane: .prompts,
                            anchor: "user-prompts"
                        )
                    )
                ),
                SubRow(
                    id: "prompt-pin",
                    name: "Pin to picker",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Pin any prompt — bundled or user-authored — and it floats to the top of the picker plus a Pinned section in Settings → Prompts. Pin/unpin is available on every row and inside each prompt's detail sheet."
                    )
                ),
                SubRow(
                    id: "articulate-intent-classifier",
                    name: "Intent classifier",
                    shortcutChip: nil,
                    isExpandable: true,
                    detail: SubRowDetailContent(
                        prose: "Used only by Rewrite with Voice. A deterministic regex classifier routes each spoken instruction into voice-preserving, structural, translation, or code branches and picks a minimal tendency for the model. Your instruction stays the primary signal — the classifier just nudges the default."
                    )
                ),
            ],
            conditionalAction: nil
        ),
    ]

    // MARK: Validation

    /// Runtime assertions run on every `BasicsContent` access in DEBUG. Keeps
    /// the main target free of an XCTest target while still catching budget
    /// regressions during `xcodebuild`/run cycles.
    ///
    /// Called from the type's empty `init()` below (so the first reference
    /// from SwiftUI triggers it). Safe to call repeatedly — it's idempotent.
    static func validate() {
        #if DEBUG
        // Full suite (hero slugs, sub-row slugs, plain-row semantics,
        // expandable-row semantics, multilingual grid presence).
        runTestSuite()
        for hero in heroes {
            assert(
                hero.subtitle.count <= BasicsBudget.heroSubtitle,
                "Hero '\(hero.id)' subtitle is \(hero.subtitle.count) chars (budget \(BasicsBudget.heroSubtitle))"
            )
            for row in hero.subRows {
                let wordCount = row.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                assert(
                    wordCount <= BasicsBudget.subRowNameWords + 1,
                    "SubRow '\(row.id)' name is \(wordCount) words (budget \(BasicsBudget.subRowNameWords))"
                )
                if row.isExpandable {
                    assert(row.detail != nil,
                           "Expandable sub-row '\(row.id)' must have a detail")
                    if let prose = row.detail?.prose {
                        assert(
                            prose.count <= BasicsBudget.subRowProse,
                            "SubRow '\(row.id)' prose is \(prose.count) chars (budget \(BasicsBudget.subRowProse))"
                        )
                    }
                } else {
                    assert(row.detail == nil,
                           "Plain sub-row '\(row.id)' must not have a detail")
                }
            }
        }
        #endif
    }

    init() { BasicsContent.validate() }
}

// MARK: - Multilingual grid

/// 25-code language grid rendered inside the `multilingual` sub-row's
/// expansion. Uses a `LazyVGrid` of monospaced chips followed by the
/// closing line from redesign §5.
struct MultilingualGrid: View {
    private let codes: [String] = [
        "EN", "FR", "DE", "ES", "IT",
        "PT", "NL", "PL", "RU", "UK",
        "SV", "DA", "FI", "EL", "CS",
        "HU", "RO", "BG", "HR", "SK",
        "SL", "ET", "LV", "LT", "MT",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6),
                    count: 5
                ),
                spacing: 6
            ) {
                ForEach(codes, id: \.self) { code in
                    Text(code)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .accessibilityLabel(code)
                }
            }
            Text("More languages will be added as Parakeet improves.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
