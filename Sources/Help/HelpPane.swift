import SwiftUI

/// Durable in-app help surface — visual-first specimen cards (design doc
/// §6 / §I4 / Frontend Directives §4, v2 2026-04-18).
///
/// Three sections (Basics / Advanced / Troubleshooting), each a grid of
/// `FeatureCard`s. Each card pairs a purpose-drawn SwiftUI diagram with a
/// one-sentence caption — replacing the prose-heavy v1 Help page.
///
/// A `HelpSearchField` at the top filters cards by title and caption.
/// When a filter is active, sections with zero matches are hidden
/// entirely (rather than leaving empty section headers).
///
/// Deep-link contract (plan §7) — preserved from v1: `HelpPane` observes
/// `jot.help.scrollToAnchor` posted by `InfoPopoverButton`. On receipt
/// the `ScrollViewReader` scrolls the card whose anchor matches.
struct HelpPane: View {
    @State private var searchText: String = ""

    private let cards: [CardSpec] = HelpPane.allCards

    // MARK: - Filter + grouping

    private var filtered: [CardSpec] {
        guard !searchText.isEmpty else { return cards }
        let q = searchText.lowercased()
        return cards.filter {
            $0.title.lowercased().contains(q)
                || $0.caption.lowercased().contains(q)
                || ($0.tag ?? "").lowercased().contains(q)
        }
    }

    private var bySection: [(Section, [CardSpec])] {
        let filtered = filtered
        return Section.allCases.compactMap { s in
            let cs = filtered.filter { $0.section == s }
            return cs.isEmpty ? nil : (s, cs)
        }
    }

    private var railItems: [AnchorRail.Item] {
        bySection.map { section, _ in
            AnchorRail.Item(
                number: section.number,
                title: section.title,
                dek: section.dek,
                anchor: section.anchor
            )
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HelpSearchField(
                        text: $searchText,
                        resultCount: filtered.count,
                        totalCount: cards.count
                    )

                    if !railItems.isEmpty {
                        AnchorRail(items: railItems) { anchor in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                        }
                    }

                    ForEach(Array(bySection.enumerated()), id: \.offset) { idx, pair in
                        let (section, cards) = pair
                        if idx > 0 { SectionRule() }
                        sectionView(section, cards: cards)
                    }

                    if filtered.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: InfoPopoverButton.scrollToAnchorNotification
            )) { note in
                guard let anchor = note.userInfo?["anchor"] as? String else { return }
                // Clear any active filter so the target card is visible.
                if !searchText.isEmpty { searchText = "" }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Section rendering

    @ViewBuilder
    private func sectionView(_ section: Section, cards: [CardSpec]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpSection(
                number: section.number,
                title: section.title,
                dek: section.dek,
                anchor: section.anchor
            ) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(cards) { spec in
                        FeatureCard(
                            spec.title,
                            caption: spec.caption,
                            anchor: spec.anchor,
                            tag: spec.tag,
                            visual: spec.visual
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No features match “\(searchText)”")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Clear search") { searchText = "" }
                .buttonStyle(.link)
                .focusable(false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Section metadata

extension HelpPane {
    enum Section: Int, CaseIterable {
        case basics, advanced, troubleshooting

        var number: String {
            switch self {
            case .basics: return "01"
            case .advanced: return "02"
            case .troubleshooting: return "03"
            }
        }

        var title: String {
            switch self {
            case .basics: return "Basics"
            case .advanced: return "Advanced"
            case .troubleshooting: return "Troubleshooting"
            }
        }

        var dek: String {
            switch self {
            case .basics: return "What Jot does and the surfaces you live in every day."
            case .advanced: return "Optional paths, preferences, and power-user knobs."
            case .troubleshooting: return "macOS constraints and common symptoms."
            }
        }

        var anchor: String {
            switch self {
            case .basics: return "help.basics"
            case .advanced: return "help.advanced"
            case .troubleshooting: return "help.troubleshooting"
            }
        }
    }
}

// MARK: - Card spec

extension HelpPane {
    struct CardSpec: Identifiable {
        let id = UUID()
        let section: Section
        let title: String
        let caption: String
        let anchor: String?
        let tag: String?
        let visual: () -> AnyView

        init(
            section: Section,
            title: String,
            caption: String,
            anchor: String? = nil,
            tag: String? = nil,
            @ViewBuilder visual: @escaping () -> some View
        ) {
            self.section = section
            self.title = title
            self.caption = caption
            self.anchor = anchor
            self.tag = tag
            self.visual = { AnyView(visual()) }
        }
    }
}

// MARK: - All cards

extension HelpPane {
    static let allCards: [CardSpec] = [

        // ---------------- Basics ----------------

        CardSpec(
            section: .basics,
            title: "Toggle recording",
            caption: "Press to start, press again to stop and transcribe. The primary dictation hotkey.",
            anchor: "help.dictation.basics",
            tag: "⌥Space"
        ) {
            HStack(spacing: 10) {
                ExampleTag()
                KeyCombo(keys: ["⌥", "Space"])
                FlowArrow()
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                FlowArrow()
                MiniTranscript()
            }
        },

        CardSpec(
            section: .basics,
            title: "Push to talk",
            caption: "Hold to record, release to transcribe. Use when you want precise control over the capture window.",
            anchor: "help.shortcuts.basics",
            tag: "hold"
        ) {
            HStack(spacing: 8) {
                ExampleTag()
                KeyCap(label: "fn")
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("HOLD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .tracking(1)
                FlowArrow()
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            }
        },

        CardSpec(
            section: .basics,
            title: "Paste last transcription",
            caption: "Pastes your most recent transcript again at the cursor.",
            tag: "⌥."
        ) {
            HStack(spacing: 8) {
                ExampleTag()
                KeyCombo(keys: ["⌥", "."])
                FlowArrow()
                ClipboardGlyph(withContent: true)
                    .scaleEffect(0.6)
                    .frame(width: 34, height: 40)
                FlowArrow()
                MiniTranscript()
            }
        },

        CardSpec(
            section: .basics,
            title: "Rewrite selection",
            caption: "Select text, press the shortcut, speak an instruction. Jot understands structural changes (\u{201C}make it a list\u{201D}), translations, code edits, and tone shifts.",
            anchor: "help.rewrite.overview",
            tag: "voice"
        ) {
            RewriteFlow()
        },

        CardSpec(
            section: .basics,
            title: "Cancel",
            caption: "Drops the current recording or rewrite without transcribing. Hardcoded — not configurable.",
            tag: "esc"
        ) {
            HStack(spacing: 10) {
                ZStack {
                    KeyCap(label: "esc", width: 40)
                    Rectangle()
                        .fill(.red.opacity(0.8))
                        .frame(width: 48, height: 1.4)
                        .rotationEffect(.degrees(-14))
                }
                FlowArrow()
                WaveformStrip(accent: .red)
                    .opacity(0.5)
            }
        },

        CardSpec(
            section: .basics,
            title: "On-device transcription",
            caption: "Parakeet runs on the Apple Neural Engine. Audio never leaves your Mac.",
            anchor: "help.dictation.model",
            tag: "ANE"
        ) {
            ParakeetPipeline()
        },

        CardSpec(
            section: .basics,
            title: "Auto-correct",
            caption: "Optional AI cleanup pass — removes fillers, fixes grammar, preserves your voice.",
            anchor: "help.transform.overview",
            tag: "off by default"
        ) {
            TransformArrow()
        },

        CardSpec(
            section: .basics,
            title: "Status pill",
            caption: "A small overlay under the notch tracks the pipeline: recording, transcribing, cleaning up, done.",
            anchor: "help.pill.states",
            tag: "overlay"
        ) {
            StatesRow()
        },

        CardSpec(
            section: .basics,
            title: "Menu bar",
            caption: "The tray icon glyph changes per state. Click for Open Jot, Settings, Copy last, and Check for Updates.",
            anchor: "help.menubar.overview",
            tag: "tray"
        ) {
            MenuBarStatesRow()
        },

        CardSpec(
            section: .basics,
            title: "Recording library",
            caption: "Every recording is stored locally with its transcript. Search by text or date, play back, rename, re-transcribe, reveal in Finder.",
            anchor: "help.library.overview",
            tag: "local"
        ) {
            LibraryRowMini()
        },

        CardSpec(
            section: .basics,
            title: "Copy last transcription",
            caption: "A menu-bar command to copy your most recent transcript to the clipboard.",
            anchor: "help.copy.last",
            tag: "menu bar"
        ) {
            HStack(spacing: 8) {
                MiniTranscript()
                FlowArrow()
                ClipboardGlyph(withContent: true)
                    .scaleEffect(0.7)
                    .frame(width: 40, height: 46)
            }
        },

        CardSpec(
            section: .basics,
            title: "Auto-Enter",
            caption: "When on, Jot presses Return after pasting — so chat apps and terminals auto-submit.",
            anchor: "help.autoenter",
            tag: "optional"
        ) {
            HStack(spacing: 10) {
                MiniTranscript()
                FlowArrow()
                KeyCap(label: "⏎", width: 32)
                FlowArrow()
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
        },

        CardSpec(
            section: .basics,
            title: "Keep clipboard",
            caption: "When off, Jot restores whatever you had on the clipboard before the transcription.",
            anchor: "help.clipboard.keep",
            tag: "sandwich"
        ) {
            ClipboardRestore()
        },

        // ---------------- Advanced ----------------

        CardSpec(
            section: .advanced,
            title: "LLM providers",
            caption: "Five providers for Auto-correct and Rewrite: OpenAI, Anthropic, Gemini, Vertex Gemini, Ollama.",
            anchor: "help.ai.providers",
            tag: "5"
        ) {
            ProviderBadges()
        },

        CardSpec(
            section: .advanced,
            title: "Ollama (fully local)",
            caption: "Run a model locally; Jot talks to http://localhost:11434. No API key, no cloud traffic.",
            anchor: "help.ai.ollama",
            tag: "offline"
        ) {
            OllamaGlyph()
        },

        CardSpec(
            section: .advanced,
            title: "Endpoint and API key",
            caption: "Configure in Settings → AI. Keys live in Keychain, never on disk.",
            anchor: "help.ai.endpoint",
            tag: "Keychain"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("api.openai.com/v1")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("sk-••••••••••••••")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        },

        CardSpec(
            section: .advanced,
            title: "Test Connection",
            caption: "Manual diagnostic — it tells you if the provider is reachable. It does not gate the toggle.",
            anchor: "help.ai.verify",
            tag: "diagnostic"
        ) {
            TestConnectionGlyph()
        },

        CardSpec(
            section: .advanced,
            title: "Customize prompt",
            caption: "Edit the cleanup prompt, or the shared invariants behind Rewrite. Reset to default restores the shipped text.",
            anchor: "help.ai.customPrompt",
            tag: "editable"
        ) {
            PromptEditorMini()
        },

        CardSpec(
            section: .advanced,
            title: "Sparkle updates",
            caption: "Jot checks for signed updates once a day. Only traffic: the appcast and the DMG.",
            anchor: "help.advanced.updates",
            tag: "daily"
        ) {
            AppUpdate()
        },

        CardSpec(
            section: .advanced,
            title: "Launch at login",
            caption: "Register Jot as a login item so it starts with your Mac.",
            anchor: "help.general.launch-at-login",
            tag: "login item"
        ) {
            LoginItemGlyph()
        },

        CardSpec(
            section: .advanced,
            title: "Retention",
            caption: "Auto-delete recordings after 7, 30, or 90 days. Forever keeps them until you delete manually.",
            anchor: "help.general.retention",
            tag: "purge"
        ) {
            RetentionTimeline()
                .padding(.horizontal, 16)
        },

        CardSpec(
            section: .advanced,
            title: "Setup Wizard",
            caption: "Five steps: permissions, model download, microphone, shortcut, test. Re-run any time.",
            anchor: "help.general.setup-wizard",
            tag: "5 steps"
        ) {
            StepDots(count: 5)
        },

        CardSpec(
            section: .advanced,
            title: "Sound feedback",
            caption: "Five chimes — start, stop, cancel, done, error — all individually toggleable with one shared volume.",
            anchor: "help.sound.chimes",
            tag: "5 events"
        ) {
            ChimeRow()
        },

        CardSpec(
            section: .advanced,
            title: "Input device",
            caption: "Pick a specific mic in Settings → General, or let Jot follow your macOS default.",
            anchor: "help.general.input-device",
            tag: "mic"
        ) {
            MicDropdown()
        },

        CardSpec(
            section: .advanced,
            title: "Re-transcribe",
            caption: "Right-click any recording in Library to run it through Parakeet again — useful after swapping models.",
            anchor: "help.library.retranscribe",
            tag: "rerun"
        ) {
            HStack(spacing: 8) {
                LibraryRowMini()
                    .scaleEffect(0.7, anchor: .center)
                    .frame(width: 100, height: 50)
                FlowArrow()
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }
        },

        // ---------------- Troubleshooting ----------------

        CardSpec(
            section: .troubleshooting,
            title: "Permissions",
            caption: "Mic, Input Monitoring, Accessibility. Grant in System Settings → Privacy & Security.",
            anchor: "help.permissions",
            tag: "3+1"
        ) {
            PermissionTiles()
        },

        CardSpec(
            section: .troubleshooting,
            title: "Modifier required",
            caption: "macOS rejects single-key global shortcuts. Every binding must include ⌘ ⌥ ⌃ ⇧ or Fn.",
            anchor: "help.shortcuts.mac-limits",
            tag: "platform"
        ) {
            ModifierRequired()
        },

        CardSpec(
            section: .troubleshooting,
            title: "Bluetooth mic redirect",
            caption: "A connected BT headset may steal the mic route. Pick your device explicitly in Settings → General.",
            anchor: "help.bt-redirect",
            tag: "routing"
        ) {
            BTRedirect()
        },

        CardSpec(
            section: .troubleshooting,
            title: "Shortcut conflicts",
            caption: "Jot warns when two of its hotkeys share a binding. It can't see collisions with other apps' global hotkeys.",
            anchor: "help.shortcuts.conflicts",
            tag: "internal"
        ) {
            ConflictRings()
        },
    ]
}
