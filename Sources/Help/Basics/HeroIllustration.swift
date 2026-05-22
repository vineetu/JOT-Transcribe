import SwiftUI

// MARK: - HeroIllustration (shared-timeline animated art)

/// Native-SwiftUI illustration that animates over the Basics tab's shared
/// 6-second loop. Reads phase from `\.animationPhase` — HelpBasicsView
/// owns the TimelineView.
///
/// Three kinds, one per hero (redesign §4):
///   - `.dictation`: mic → 7-bar waveform → text bubble
///   - `.cleanup`:   messy strikethrough bubble → clean bubble slide-in
///   - `.rewrite`: before text + selection → instruction bubble → after
///
/// All three keyframe tables use the same easing and clamp to keep opacity
/// above 0.2 so labels stay legible. A "illustrative" caption sits
/// bottom-right at `.caption2`/tertiary per §4 tuning rules.
struct HeroIllustration: View {
    let kind: HeroIllustrationKind

    @Environment(\.animationPhase) private var phase

    var body: some View {
        ZStack {
            // Background — subtle tinted surface so the illustrations
            // read as art, not as regular card content.
            RoundedRectangle(cornerRadius: HelpSharedStyle.cardCornerRadius)
                .fill(Color.primary.opacity(0.035))

            // Main artwork
            Group {
                switch kind {
                case .dictation:   DictationArt(phase: phase)
                case .cleanup:     CleanupArt(phase: phase)
                case .rewrite:     RewriteArt(phase: phase)
                case .prompts:     PromptsArt(phase: phase)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // "illustrative" caption, bottom-right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("illustrative")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 10)
                        .padding(.bottom, 6)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(kind: kind))
    }

    private static func accessibilityLabel(kind: HeroIllustrationKind) -> String {
        switch kind {
        case .dictation:  return "Illustration: microphone to waveform to transcribed text."
        case .cleanup:    return "Illustration: messy transcript cleaned up into polished text."
        case .rewrite:    return "Illustration: selected text rewritten with a voice instruction."
        case .prompts:    return "Illustration: a prompt picker panel listing built-in and custom prompts; the user picks one and it applies to selected text."
        }
    }
}

// MARK: - Keyframe utility

/// Linearly interpolate between two values as `phase` sweeps through
/// `[start, end]`, clamped outside that window. `ease` applies a cosine
/// ease-in-out (`0.5 - 0.5·cos(π·t)`) so keyframes transition smoothly.
///
/// Never clamps opacity below a floor externally — callers that want the
/// "never below 0.2" rule from redesign §4 must apply their own floor via
/// `max(0.2, ...)`.
///
/// Module-internal (not `private`) so illustration siblings in
/// `Sources/Help/Basics/Illustrations/` can reuse the same easing curve.
func heroKeyframe(
    phase: Double,
    start: Double,
    end: Double,
    from: Double,
    to: Double,
    ease: Bool = true
) -> Double {
    let t: Double
    if phase <= start {
        t = 0
    } else if phase >= end {
        t = 1
    } else {
        t = (phase - start) / (end - start)
    }
    let eased = ease ? (0.5 - 0.5 * cos(.pi * t)) : t
    return from + (to - from) * eased
}

// MARK: - Dictation art

/// Phase 0.0–0.3: mic fades/fills in.
/// Phase 0.3–0.7: seven waveform bars animate with offset per-bar sines.
/// Phase 0.7–1.0: text bubble fades in with a blinking caret.
private struct DictationArt: View {
    let phase: Double

    var body: some View {
        HStack(alignment: .center, spacing: 14) {

            // Mic: grows & fills over [0.0, 0.3]; stays on afterward.
            let micOpacity = max(0.35, heroKeyframe(phase: phase, start: 0.0, end: 0.3, from: 0.35, to: 1.0))
            let micScale = heroKeyframe(phase: phase, start: 0.0, end: 0.3, from: 0.9, to: 1.0)
            Image(systemName: "mic.fill")
                .font(.system(size: 26))
                .foregroundStyle(phase < 0.3 ? Color.accentColor.opacity(micOpacity) : Color.accentColor)
                .scaleEffect(micScale)
                .frame(width: 40)
                .accessibilityHidden(true)

            // Waveform: visible during [0.25, 0.75] roughly.
            let waveVisibility = max(
                0.2,
                heroKeyframe(phase: phase, start: 0.2, end: 0.35, from: 0.2, to: 1.0)
                * heroKeyframe(phase: phase, start: 0.7, end: 0.85, from: 1.0, to: 0.2)
            )
            Waveform7Bar(phase: phase)
                .opacity(waveVisibility)
                .frame(width: 90)

            // Text bubble: fades in during [0.7, 1.0].
            let bubbleOpacity = max(0.2, heroKeyframe(phase: phase, start: 0.65, end: 0.95, from: 0.0, to: 1.0))
            TranscriptBubble(phase: phase, text: "Hello world")
                .opacity(bubbleOpacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Seven vertical bars whose heights are driven by `sin(phase · 2π + i·0.2)`.
/// Kept within a 50pt vertical box.
private struct Waveform7Bar: View {
    let phase: Double

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let raw = sin(phase * 2 * .pi + Double(i) * 0.4)
                let height = 12 + CGFloat(abs(raw)) * 36
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 5, height: height)
            }
        }
        .frame(height: 52)
    }
}

/// Faux-chat bubble with a growing typewriter-style character reveal and a
/// simple caret blink that ticks every ~0.5s inside the hold window.
private struct TranscriptBubble: View {
    let phase: Double
    let text: String

    private var revealedText: String {
        // Start revealing at phase 0.7, finish at 0.9.
        let progress = min(1, max(0, (phase - 0.7) / 0.2))
        let shown = Int(Double(text.count) * progress)
        return String(text.prefix(shown))
    }

    private var caretVisible: Bool {
        // Blink only after reveal completes. 2 Hz blink based on a slice of phase.
        guard phase > 0.9 else { return true }
        return (phase * 10).truncatingRemainder(dividingBy: 1) < 0.5
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(revealedText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Rectangle()
                .fill(.primary.opacity(caretVisible ? 0.8 : 0.0))
                .frame(width: 1.5, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - Cleanup art

/// Phase 0.0–0.4: messy bubble (with strikethrough fillers) visible.
/// Phase 0.4–0.7: clean bubble slides in from right, fades up; messy bubble
///                slides slightly left + dims.
/// Phase 0.7–1.0: hold on resolved state.
private struct CleanupArt: View {
    let phase: Double

    var body: some View {
        let messyOpacity = max(0.2, heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 1.0, to: 0.35))
        let messyOffsetX = heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 0.0, to: -10.0)
        let cleanOpacity = max(0.2, heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 0.2, to: 1.0))
        let cleanOffsetX = heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 24.0, to: 0.0)

        HStack(alignment: .center, spacing: 16) {
            // Messy bubble
            MessyBubble()
                .opacity(messyOpacity)
                .offset(x: messyOffsetX)

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // Clean bubble
            CleanBubble()
                .opacity(cleanOpacity)
                .offset(x: cleanOffsetX)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MessyBubble: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("um,")
                .strikethrough(true, color: .red.opacity(0.85))
                .foregroundStyle(.secondary)
            Text("so")
                .foregroundStyle(.primary)
            Text("like,")
                .strikethrough(true, color: .red.opacity(0.85))
                .foregroundStyle(.secondary)
            Text("ship it")
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct CleanBubble: View {
    var body: some View {
        Text("So ship it.")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.16))
            )
    }
}

// MARK: - Rewrite art

/// Phase 0.0–0.3: "before" text visible, selected fragment highlighted.
/// Phase 0.3–0.5: instruction bubble slides in from top ("make it formal").
/// Phase 0.5–0.8: "after" text fades in (rewritten selection).
/// Phase 0.8–1.0: hold.
private struct RewriteArt: View {
    let phase: Double

    var body: some View {
        let beforeOpacity = max(0.2, heroKeyframe(phase: phase, start: 0.5, end: 0.8, from: 1.0, to: 0.3))
        let instructionOpacity = max(
            0.0,
            heroKeyframe(phase: phase, start: 0.28, end: 0.45, from: 0.0, to: 1.0)
            * heroKeyframe(phase: phase, start: 0.7, end: 0.85, from: 1.0, to: 0.4)
        )
        let instructionOffsetY = heroKeyframe(phase: phase, start: 0.28, end: 0.45, from: -14.0, to: 0.0)
        let afterOpacity = max(0.0, heroKeyframe(phase: phase, start: 0.55, end: 0.85, from: 0.0, to: 1.0))

        VStack(alignment: .leading, spacing: 6) {
            // Instruction bubble (appears above the text pair)
            HStack {
                Spacer()
                InstructionBubble()
                    .opacity(instructionOpacity)
                    .offset(y: instructionOffsetY)
            }

            HStack(alignment: .center, spacing: 10) {
                // Before
                BeforeText()
                    .opacity(beforeOpacity)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                // After
                AfterText()
                    .opacity(afterOpacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BeforeText: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("hey can u")
                .foregroundStyle(.primary)
            Text("send it")
                .foregroundStyle(.primary)
                .padding(.horizontal, 3)
                .background(Color.accentColor.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct AfterText: View {
    var body: some View {
        Text("Please send it.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
            )
    }
}

private struct InstructionBubble: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
            Text("\"make it formal\"")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
