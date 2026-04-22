import KeyboardShortcuts
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

                    aboutFooter
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
                            tag: HelpPane.resolvedTag(spec),
                            visual: spec.visual
                        )
                    }
                }
            }
        }
    }

    private var aboutFooter: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("Jot v\(Self.appVersion) (build \(Self.appBuild))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Link(
                "Buy me a coffee ☕",
                destination: URL(string: "https://ko-fi.com/vineetsriram")!
            )
            .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
        /// When set, the card's tag is resolved at render time to the
        /// user's current binding for this shortcut (e.g. "⌥Space"). Falls
        /// back to the static `tag` when no binding is set — so cards like
        /// Push to talk still show "hold" while unbound.
        let shortcutName: KeyboardShortcuts.Name?
        let visual: () -> AnyView

        init(
            section: Section,
            title: String,
            caption: String,
            anchor: String? = nil,
            tag: String? = nil,
            shortcutName: KeyboardShortcuts.Name? = nil,
            @ViewBuilder visual: @escaping () -> some View
        ) {
            self.section = section
            self.title = title
            self.caption = caption
            self.anchor = anchor
            self.tag = tag
            self.shortcutName = shortcutName
            self.visual = { AnyView(visual()) }
        }
    }

    /// Resolve the tag for a card. Dynamic bindings win over the static
    /// `tag` string — so if the user has customized their Toggle
    /// recording hotkey, the help card reflects that, not the default.
    static func resolvedTag(_ spec: CardSpec) -> String? {
        if let name = spec.shortcutName,
           let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            return shortcut.description
        }
        return spec.tag
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
            shortcutName: .toggleRecording
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
            tag: "hold",
            shortcutName: .pushToTalk
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
            shortcutName: .pasteLastTranscription
        ) {
            HStack(spacing: 8) {
                ExampleTag()
                KeyCombo(keys: ["⌥", ","])
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
            title: "Articulate (Custom)",
            caption: "Select any text, press the shortcut, speak an instruction. Useful for translations, reshaping structure (bullets, lists, summaries), tone shifts, code edits, and speaker splits. Cloud providers handle the harder prompts best.",
            anchor: "help.articulate.overview",
            shortcutName: .articulateCustom
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ExampleTag()
                    KeyCombo(keys: ["⌥", "."])
                }
                ArticulateRecipes()
            }
        },

        CardSpec(
            section: .basics,
            title: "Articulate",
            caption: "Select text and press the shortcut. Jot sends the selection to your AI provider with a built-in \u{201C}Articulate this\u{201D} instruction — no dictation step. Use when you just want quick cleanup without speaking an instruction.",
            anchor: "help.basics.articulate",
            shortcutName: .articulate
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ExampleTag()
                    KeyCombo(keys: ["⌥", "/"])
                }
                HStack(spacing: 8) {
                    SelectionCaret()
                    FlowArrow()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    FlowArrow()
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.green.opacity(0.8))
                            .frame(width: 44, height: 10)
                        Rectangle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 1, height: 12)
                    }
                }
            }
        },

        CardSpec(
            section: .basics,
            title: "Cancel",
            caption: "Drops the current recording or articulate without transcribing. Hardcoded — not configurable.",
            tag: "esc"
        ) {
            HStack(spacing: 10) {
                ZStack {
                    KeyCap(label: "esc", width: 100)
                    Rectangle()
                        .fill(.red.opacity(0.8))
                        .frame(width: 112, height: 3)
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
            title: "Multilingual dictation",
            caption: "Parakeet auto-detects 25 European languages — English, French, German, Spanish, Italian, Polish, Russian, and 18 more. Just speak in whatever language works for you. No setup, no switching. Pair with Articulate to translate into any other language on the way out.",
            anchor: "help.basics.multilingual",
            tag: "25 langs"
        ) {
            LanguageChips()
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
                KeyCap(label: "⏎", width: 80)
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
            caption: "Five providers for Auto-correct and Articulate: Apple Intelligence (on-device), OpenAI, Anthropic, Gemini, Ollama.",
            anchor: "help.ai.providers",
            tag: "6"
        ) {
            ProviderBadges()
        },

        CardSpec(
            section: .advanced,
            title: "Custom vocabulary",
            caption: "A short list of words Jot should prefer — product names, company names, technical jargon. Add them in Settings → Vocabulary; Jot scans each recording for matches and replaces common misfires (\"you jet\" → \"UJET\") with your canonical spelling. Entirely on-device via an extra ≈100 MB model you download once. Master toggle lets you turn boosting on and off without losing the list. Keep the list under 100 terms, and avoid common English words — they cause false replacements.",
            anchor: "help.dictation.vocabulary",
            tag: "on-device"
        ) {
            VStack(spacing: 6) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("UJET")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        },

        CardSpec(
            section: .advanced,
            title: "Apple Intelligence",
            caption: "Jot's default cleanup and articulate run entirely on your Mac via Apple's on-device model — no API key, no network, free. For long-form dictations (several paragraphs or more), the on-device model may produce less polished results than cloud providers. Switch to Anthropic or Gemini in Settings → AI for higher quality on long content.",
            anchor: "help.advanced.apple-intelligence",
            tag: "on-device"
        ) {
            VStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("on-device")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
            caption: "Edit the cleanup prompt, or the shared invariants behind Articulate. Reset to default restores the shipped text.",
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

        CardSpec(
            section: .troubleshooting,
            title: "Recording won't start?",
            caption: "Symptom: you press the record hotkey and nothing happens — no pill, no audio captured. After ~5 seconds Jot surfaces \u{201C}Audio system isn\u{2019}t responding.\u{201D} Cause: macOS\u{2019}s audio daemon (coreaudiod) can get stuck after starting the iOS Simulator, a Bluetooth glitch, or a sleep/wake race. Jot can\u{2019}t unstick it without admin rights. Fix: open Terminal and run the command below. macOS will ask for your admin password, restart the daemon in a second, and the next hotkey press will work. Alternative: restart your Mac.",
            anchor: "help.troubleshooting.audio-stuck",
            tag: "coreaudiod"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("audio daemon stuck")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                InlineCode("sudo killall coreaudiod")
            }
        },

        CardSpec(
            section: .troubleshooting,
            title: "Hotkey stopped working?",
            caption: "Symptom: pressing ⌥, or ⌥/ produces a Unicode character (≤, ÷, …) instead of triggering the action. Cause: another app may have grabbed the shortcut while Jot was off — macOS silently prevents Jot from re-registering. Fix: 1) Click \u{201C}Restart Jot\u{201D} in Settings → General to re-register cleanly. 2) Still broken? Settings → Shortcuts, clear the binding for that row and reassign it. 3) Still broken? Identify the conflicting app (often Raycast, Alfred, Keyboard Maestro, TextExpander, or something recently installed/updated) — change the hotkey there or pick a different combo in Jot.",
            anchor: "help.troubleshooting.hotkey-stuck",
            tag: "re-register"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ShortcutChip(["⌥", ","])
                    FlowArrow()
                    Text("≤")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    Text("Restart Jot")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        },

        CardSpec(
            section: .troubleshooting,
            title: "Resetting Jot",
            caption: "Three ways to start over, from your settings feeling off to wiping every byte Jot put on disk. Each relaunches Jot when you confirm.",
            tag: "3 scopes"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                LabeledContent("Settings") { Text("Reset preferences and shortcuts") }
                LabeledContent("Data") { Text("Clear recordings and transcripts") }
                LabeledContent("Permissions") { Text("Re-run access setup from scratch") }
            }
            .font(.system(size: 11))
        },

        CardSpec(
            section: .troubleshooting,
            title: "Report an issue",
            caption: "Exports errors Jot has recorded on your Mac — never uploaded unless you share the file. Find the controls in About → Troubleshooting.",
            tag: "logs local"
        ) {
            VStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("local logs")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        },
    ]
}
