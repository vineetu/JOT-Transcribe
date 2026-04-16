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
            Equalizer(reduceMotion: reduceMotion)
                .frame(width: 24, height: 14)
            Spacer(minLength: 8)
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

/// Audio-level equalizer. Four thin bars with staggered sin-based motion —
/// calm and periodic, not jittery. Under Reduce Motion the bars freeze at
/// 50% height.
private struct Equalizer: View {
    let reduceMotion: Bool
    private let barCount = 4
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4

    // Per-bar frequency (Hz) + phase offset (radians). Chosen so the bars
    // drift in and out of sync without ever looking synchronized.
    private let frequencies: [Double] = [2.3, 3.1, 2.7, 3.5]
    private let phases: [Double] = [0.0, 1.2, 2.4, 3.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white.opacity(0.95))
                            .frame(width: barWidth, height: barHeight(i, available: geo.size.height, t: t))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func barHeight(_ index: Int, available: CGFloat, t: Double) -> CGFloat {
        if reduceMotion { return max(2, available * 0.5) }
        // sin ∈ [-1, 1]; remap to [0.2, 1.0] so bars never fully collapse.
        let raw = sin(t * frequencies[index] + phases[index])
        let normalized = 0.6 + 0.4 * raw  // → [0.2, 1.0]
        return max(2, available * CGFloat(normalized))
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
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                DispatchQueue.main.async {
                    phase = (phase + 1) % 3
                }
            }
        }
    }

    private func opacity(for i: Int) -> Double {
        if reduceMotion { return 0.7 }
        return i == phase ? 1.0 : 0.3
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
