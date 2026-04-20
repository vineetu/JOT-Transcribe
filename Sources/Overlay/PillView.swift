import AppKit
import SwiftUI

/// Dynamic Island-style pill. Four visual states (recording, transcribing,
/// success, error) plus a hidden state that collapses the surface entirely.
///
/// Visual target: pure-black pill that visually grows from the notch. No
/// material, no gradient — just black plus a subtle drop shadow for depth.
/// Corner radius matches the notch curvature (height / 2).
///
/// Motion philosophy:
///   * appearance: slide down from behind the notch (offset -20 → 0, fade in)
///     over 220 ms spring
///   * equalizer: periodic sin-based motion, calm and smooth
///   * width transitions: 200 ms interpolating spring (slight overshoot)
///   * content cross-fade: 140 ms ease-out
///
/// Reduce Motion: equalizer freezes at 50%, appearance becomes a 120 ms
/// ease-in-out fade with no spring.
struct PillView: View {
    @ObservedObject var model: PillViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pill surface geometry. Height is tight to the notch strip; corner
    /// radius equals height/2 so the bottom corners hug the notch curvature.
    static let pillHeight: CGFloat = 36
    static let pillWidth: CGFloat = 360
    private static var cornerRadius: CGFloat { pillHeight / 2 }

    var body: some View {
        ZStack {
            switch model.state {
            case .hidden:
                Color.clear.frame(width: 0, height: 0)
            case .recording(let elapsed):
                pillBody {
                    RecordingContent(elapsed: elapsed, reduceMotion: reduceMotion)
                }
            case .transcribing:
                pillBody {
                    TranscribingContent(reduceMotion: reduceMotion)
                }
            case .rewriting:
                pillBody {
                    ArticulatingContent(reduceMotion: reduceMotion)
                }
            case .transforming:
                pillBody {
                    TransformingContent(reduceMotion: reduceMotion)
                }
            case .success(let preview):
                pillBody {
                    SuccessContent(preview: preview) {
                        model.copyLastTranscript()
                    }
                }
            case .error(let message):
                pillBody {
                    ErrorContent(message: message)
                }
            }
        }
        // Pin to the top of the hosting window so the pill's top edge lines
        // up with the window/screen top. Extra vertical space in the window
        // (for shadow rendering) lives below the pill.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : pillSpring, value: model.state)
    }

    private var pillSpring: Animation {
        .interpolatingSpring(stiffness: 260, damping: 22)
    }

    @ViewBuilder
    private func pillBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.pillHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        )
        .transition(pillTransition)
    }

    private var pillTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: 0.12))
        }
        // Slide down from behind the notch — gives the "grows from notch" feel.
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Recording

private struct RecordingContent: View {
    let elapsed: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(color: Color(nsColor: .systemRed), reduceMotion: reduceMotion)
            AmplitudeTrail(reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 30)
            Text(PillViewModel.formatElapsed(elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .contentTransition(.numericText())
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

/// Small "Jot" tag, right-aligned during active states — mirrors the "oto"
/// label in the reference image.
private struct AppLabel: View {
    var body: some View {
        Text("Jot")
            .font(.system(size: 10, weight: .regular))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.5))
    }
}

private struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing && !reduceMotion ? 1.15 : 1.0)
            .animation(
                reduceMotion ? nil :
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

private struct AmplitudeTrail: View {
    @EnvironmentObject private var amp: AmplitudePublisher
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                    .opacity(0.3 + 0.7 * Double(amp.history.last ?? 0))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { _ in
                    Canvas { ctx, size in
                        guard amp.history.count > 1 else { return }
                        let stepX = size.width / CGFloat(amp.history.count - 1)
                        let midY = size.height / 2
                        // Push deflection to the full half-height so loud
                        // syllables hit the top/bottom edge. The sqrt power
                        // curve below lifts quiet phonemes so they don't
                        // collapse to a hairline at the midline.
                        let scale = (size.height / 2) * 0.98
                        var path = Path()
                        for (i, value) in amp.history.enumerated() {
                            let x = CGFloat(i) * stepX
                            // Sqrt power curve: maps 0.1→0.32, 0.3→0.55,
                            // 0.5→0.71, 0.8→0.89. Quiet sounds rise visibly
                            // while loud peaks still saturate near 1.0.
                            let boosted = sqrt(max(CGFloat(value), 0))
                            // Small deterministic phase jitter so silence
                            // still looks alive rather than flatlined.
                            let phase = CGFloat(sin(Double(i) * 0.9)) * 0.6
                            let y = midY - (boosted * scale + phase)
                            if i == 0 { path.move(to: .init(x: x, y: y)) }
                            else { path.addLine(to: .init(x: x, y: y)) }
                        }
                        ctx.stroke(
                            path,
                            with: .color(Color.accentColor),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.6), location: 0),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Transcribing

private struct TranscribingContent: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemBlue))
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Transcribing")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

private struct ThreeDotLoader: View {
    let reduceMotion: Bool
    @State private var phase = 0
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                DispatchQueue.main.async {
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func opacity(for i: Int) -> Double {
        if reduceMotion { return 0.7 }
        return i == phase ? 1.0 : 0.3
    }
}

// MARK: - Articulating

private struct ArticulatingContent: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Articulating")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(pulse && !reduceMotion ? 0.6 : 0.9))
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Transforming

private struct TransformingContent: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemPurple))
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Cleaning up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(pulse && !reduceMotion ? 0.6 : 0.9))
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Success

private struct SuccessContent: View {
    let preview: String
    let onCopy: () -> Void
    @State private var copyHover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemGreen))
                .frame(width: 7, height: 7)
            Text(preview)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copyHover ? .white : .white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .onHover { copyHover = $0 }
            .help("Copy transcript")
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Error

private struct ErrorContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(shortened)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .help(message)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }

    private var shortened: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 48)
        return String(trimmed[..<idx]) + "…"
    }
}
