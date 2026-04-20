import SwiftUI

// MARK: - KeyCap / KeyCombo

/// A single keyboard key rendering — rounded rect with a short label.
///
/// Used inside `KeyCombo` and standalone for modifier/escape/return glyphs.
/// Not a real input affordance; pure visual decoration. Sized as a
/// supporting element inside the feature-card visual strip — the actual
/// configured shortcut is rendered prominently as the card's tag below.
struct KeyCap: View {
    let label: String
    var width: CGFloat? = nil
    var emphasis: Bool = true

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: emphasis ? .semibold : .medium, design: .rounded))
            .foregroundStyle(emphasis ? .primary : .secondary)
            .frame(minWidth: width ?? 22, minHeight: 22)
            .padding(.horizontal, width == nil ? 5 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
            )
    }
}

struct KeyCombo: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys.indices, id: \.self) { KeyCap(label: keys[$0]) }
        }
    }
}

/// Muted "e.g." label used before a KeyCap / KeyCombo to signal that the
/// keys shown in an illustration are a documented example, not a mirror
/// of the user's actual binding (which they configure in Shortcuts).
struct ExampleTag: View {
    var body: some View {
        Text("e.g.")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .tracking(0.3)
    }
}

// MARK: - StatusPillPreview

/// Miniature rendering of the Dynamic Island overlay pill. Used to introduce
/// the five pipeline states as a row of labeled specimens.
struct StatusPillPreview: View {
    enum Kind { case idle, recording, transcribing, transforming, done, error }
    let kind: Kind

    private var accent: Color {
        switch kind {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing: return .blue
        case .transforming: return .purple
        case .done: return .green
        case .error: return .orange
        }
    }

    private var glyph: String {
        switch kind {
        case .idle: return "mic"
        case .recording: return "waveform"
        case .transcribing: return "waveform.badge.mic"
        case .transforming: return "wand.and.stars"
        case .done: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch kind {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .transforming: return "Cleaning up"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.45), lineWidth: 0.7)
        )
    }
}

// MARK: - MenuBarGlyph

/// The status-item glyph in one of five states.
struct MenuBarGlyph: View {
    enum Kind { case idle, recording, transcribing, success, error }
    let kind: Kind

    private var symbol: String {
        switch kind {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing: return .blue
        case .success: return .green
        case .error: return .orange
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }
}

// MARK: - WaveformStrip

/// Compact 7-bar stylized waveform. Sized to ~60x24.
struct WaveformStrip: View {
    var accent: Color = .accentColor
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                let heights: [CGFloat] = [6, 14, 22, 10, 18, 8, 12]
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: heights[i])
            }
        }
    }
}

// MARK: - FlowArrow

/// A short right-pointing arrow separator. Use between stages.
struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - MiniTranscript

/// Fake cursor line with a handwritten-ish tag — evokes "the transcript lands
/// where you were typing."
struct MiniTranscript: View {
    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.6))
                .frame(width: 36, height: 7)
            Rectangle()
                .fill(Color.primary.opacity(0.7))
                .frame(width: 1, height: 11)
        }
    }
}

// MARK: - ProviderBadges

/// A horizontal row of LLM-provider initial-letter badges.
struct ProviderBadges: View {
    static let providers: [(letter: String, tint: Color, title: String)] = [
        ("O", .primary, "OpenAI"),
        ("A", .orange, "Anthropic"),
        ("G", .blue, "Gemini"),
        ("V", .cyan, "Vertex"),
        ("L", .purple, "Ollama"),
    ]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Self.providers.indices, id: \.self) { i in
                let p = Self.providers[i]
                Text(p.letter)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(p.tint.opacity(0.12))
                    )
                    .overlay(
                        Circle()
                            .stroke(p.tint.opacity(0.5), lineWidth: 0.7)
                    )
            }
        }
    }
}

// MARK: - RetentionTimeline

/// A small timeline with markers at 7, 30, 90 days and a "forever" symbol.
struct RetentionTimeline: View {
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 3)
                GeometryReader { geo in
                    let stops: [(CGFloat, String)] = [
                        (0.12, "7d"),
                        (0.42, "30d"),
                        (0.75, "90d"),
                        (1.0, "∞"),
                    ]
                    ForEach(stops.indices, id: \.self) { i in
                        let pos = geo.size.width * stops[i].0
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text(stops[i].1)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .offset(x: pos - 3, y: -2)
                    }
                }
                .frame(height: 18)
            }
        }
    }
}

// MARK: - MiniToggle

/// Static rendering of macOS-style toggle in on/off state.
struct MiniToggle: View {
    var isOn: Bool
    var tint: Color = .accentColor

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? tint.opacity(0.9) : Color.primary.opacity(0.15))
                .frame(width: 26, height: 15)
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                .padding(.horizontal, 1.5)
        }
    }
}

// MARK: - SelectionCaret

/// Evokes "a block of text is selected."
struct SelectionCaret: View {
    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 40, height: 10)
            Rectangle()
                .fill(Color.primary.opacity(0.7))
                .frame(width: 1, height: 12)
        }
    }
}

// MARK: - VoiceBubble

/// A chat-bubble-style shape with a mic icon — "speak an instruction."
struct VoiceBubble: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("articulate this")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - StepDots

/// N filled dots with tick marks — the Setup Wizard's five steps.
struct StepDots: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: 12, height: 12)
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
                if i < count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 6, height: 0.8)
                }
            }
        }
    }
}

// MARK: - ChimeRow

/// Five tiny speaker glyphs labeled with the five chime events.
struct ChimeRow: View {
    static let events: [(symbol: String, label: String)] = [
        ("play.fill", "start"),
        ("stop.fill", "stop"),
        ("xmark", "cancel"),
        ("checkmark", "done"),
        ("exclamationmark.triangle", "error"),
    ]
    var body: some View {
        HStack(spacing: 9) {
            ForEach(Self.events.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    Image(systemName: Self.events[i].symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.05))
                        )
                    Text(Self.events[i].label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - PermissionTiles

/// Three permission tiles laid out horizontally.
struct PermissionTiles: View {
    static let tiles: [(symbol: String, label: String)] = [
        ("mic.fill", "Microphone"),
        ("keyboard", "Input Monitoring"),
        ("figure.wave", "Accessibility"),
    ]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.tiles.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Image(systemName: Self.tiles[i].symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                    Text(Self.tiles[i].label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

// MARK: - ModifierRequired

/// Crossed-out bare letter + labeled modifiers. "Needs a modifier."
struct ModifierRequired: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                KeyCap(label: "F5", width: 70)
                Rectangle()
                    .fill(.red.opacity(0.8))
                    .frame(width: 80, height: 3)
                    .rotationEffect(.degrees(-18))
            }

            FlowArrow()

            HStack(spacing: 7) {
                KeyCap(label: "⌘")
                KeyCap(label: "⌥")
                KeyCap(label: "⌃")
                KeyCap(label: "⇧")
            }
        }
    }
}

// MARK: - BTRedirect

/// Bluetooth symbol + mic + redirect arrow to a computer.
struct BTRedirect: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blue)
            FlowArrow()
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            FlowArrow()
            Image(systemName: "laptopcomputer")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - ConflictRings

/// Two overlapping hotkey rings — shortcuts colliding.
struct ConflictRings: View {
    var body: some View {
        ZStack {
            KeyCombo(keys: ["⌥", "Space"])
                .offset(x: -40)
                .opacity(0.8)
            KeyCombo(keys: ["⌥", "Space"])
                .offset(x: 40)
                .opacity(0.8)
            Ellipse()
                .stroke(.red.opacity(0.8), lineWidth: 2.4)
                .frame(width: 200, height: 90)
                .offset(x: -40, y: 0)
            Ellipse()
                .stroke(.red.opacity(0.8), lineWidth: 2.4)
                .frame(width: 200, height: 90)
                .offset(x: 40, y: 0)
        }
    }
}

// MARK: - PromptEditorMini

/// A small monospace "code-editor" block with a reset pill.
struct PromptEditorMini: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("You are a dictation post-")
            Text("processor. Apply rules in")
            Text("order: 1. strip filler …")
        }
        .font(.system(size: 8, weight: .regular, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(minWidth: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - LibraryRowMini

/// Stacked tiny recording rows — the Library surface.
struct LibraryRowMini: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) {
                    WaveformStrip(accent: .accentColor.opacity(0.7))
                        .scaleEffect(0.55, anchor: .leading)
                        .frame(width: 34, height: 12)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(i == 0 ? 0.5 : 0.3))
                        .frame(height: 6)
                    Text(["0:34", "1:12", "0:08"][i])
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(i == 0 ? 0.08 : 0.03))
                )
            }
        }
        .frame(width: 160)
    }
}

// MARK: - LoginItemGlyph

/// Desktop-login-window glyph + arrow + menu bar slot.
struct LoginItemGlyph: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            FlowArrow()
            HStack(spacing: 2) {
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: 48, height: 3)
                Image(systemName: "mic")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - AppUpdate

/// App icon + version arrow + next version.
struct AppUpdate: View {
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("J")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("v1.3")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .strikethrough()
                Text("v1.4")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            FlowArrow()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - ClipboardGlyph

/// Clipboard with ghost text — Copy Last Transcription.
struct ClipboardGlyph: View {
    var withContent: Bool = true
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 48, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.6)
                )
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.3))
                .frame(width: 22, height: 6)
                .offset(y: -3)
            if withContent {
                VStack(alignment: .leading, spacing: 3) {
                    Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 34, height: 2)
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 28, height: 2)
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 32, height: 2)
                }
                .offset(y: 16)
            }
        }
    }
}

// MARK: - ReturnFlow

/// Paste caret + Return key — Auto-Enter toggle.
struct ReturnFlow: View {
    var body: some View {
        HStack(spacing: 6) {
            MiniTranscript()
            FlowArrow()
            KeyCap(label: "⏎", width: 70)
        }
    }
}

// MARK: - MicDropdown

/// Mic icon + a chevron menu affordance.
struct MicDropdown: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            HStack(spacing: 4) {
                Text("Built-in Microphone")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - ParakeetPipeline

/// Waveform → Parakeet badge → transcript line. The main pipeline diagram.
struct ParakeetPipeline: View {
    var body: some View {
        HStack(spacing: 8) {
            WaveformStrip()
            FlowArrow()
            Text("Parakeet")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                )
            FlowArrow()
            MiniTranscript()
        }
    }
}

// MARK: - TransformArrow

/// raw → "AI cleanup" → cleaned.
struct TransformArrow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("um, so like")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .strikethrough(color: .red.opacity(0.5))
            FlowArrow()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
            FlowArrow()
            Text("So like.")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - ArticulateFlow

/// Selection → mic → rewritten selection.
struct ArticulateFlow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectionCaret()
            HStack(spacing: 6) {
                FlowArrow()
                    .rotationEffect(.degrees(90))
                VoiceBubble()
            }
            .padding(.leading, 4)
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
}

// MARK: - ArticulateRecipes

/// Grid of example spoken instructions the user can give to Articulate
/// (Custom). Replaces the earlier `ArticulateFlow` visual in Help when the
/// card's goal shifted from "what happens" to "what can I say."
struct ArticulateRecipes: View {
    private let recipes = [
        "translate to Japanese",
        "make this a numbered list",
        "rewrite more formally",
        "shorten to two sentences",
        "split by speaker",
        "fix typos only"
    ]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(recipes, id: \.self) { r in
                Text("\u{201C}\(r)\u{201D}")
                    .font(.system(size: 9.5, weight: .regular))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
    }
}

// MARK: - LanguageChips

/// 5×5 grid of ISO 639-1 codes for the 25 European languages Parakeet
/// TDT 0.6B v3 supports. Auto-detected at dictation time — no user
/// configuration required. Order roughly by speaker population so the
/// most familiar codes hit the user first.
struct LanguageChips: View {
    private let codes: [String] = [
        "EN", "FR", "DE", "ES", "IT",
        "PT", "NL", "PL", "RU", "UK",
        "SV", "DA", "FI", "EL", "CS",
        "HU", "RO", "BG", "HR", "SK",
        "SL", "ET", "LV", "LT", "MT"
    ]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 5),
            alignment: .center,
            spacing: 3
        ) {
            ForEach(codes, id: \.self) { code in
                Text(code)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 13)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
    }
}

// MARK: - TestConnectionGlyph

/// Button + check + optional cross — the manual diagnostic.
struct TestConnectionGlyph: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Test Connection")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor)
                )
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("ok")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("err")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - OllamaGlyph

/// Small server/laptop shape with "localhost" label.
struct OllamaGlyph: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.purple)
            Text("localhost:11434")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ClipboardRestore

/// Two clipboards: before, after. Arrow between.
struct ClipboardRestore: View {
    var body: some View {
        HStack(spacing: 6) {
            ClipboardGlyph(withContent: true)
                .scaleEffect(0.7)
            FlowArrow()
            ClipboardGlyph(withContent: false)
                .scaleEffect(0.7)
        }
        .frame(height: 50)
    }
}

// MARK: - StatesRow

/// The five PillPreview states laid out in a single row. Used for the
/// "Status pill" overview card.
struct StatesRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusPillPreview(kind: .recording)
                StatusPillPreview(kind: .transcribing)
            }
            HStack(spacing: 6) {
                StatusPillPreview(kind: .transforming)
                StatusPillPreview(kind: .done)
            }
        }
    }
}

// MARK: - MenuBarStatesRow

struct MenuBarStatesRow: View {
    var body: some View {
        HStack(spacing: 6) {
            MenuBarGlyph(kind: .idle)
            MenuBarGlyph(kind: .recording)
            MenuBarGlyph(kind: .transcribing)
            MenuBarGlyph(kind: .success)
            MenuBarGlyph(kind: .error)
        }
    }
}
