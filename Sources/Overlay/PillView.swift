import AppKit
import SwiftUI

/// Dynamic Island-style pill. Four visual states (recording, transcribing,
/// success, error) plus a hidden state that collapses the surface entirely.
///
/// Motion philosophy — short and decisive, per the design requirements:
///   * width transitions:  200 ms interpolating spring (slight overshoot)
///   * content cross-fade: 140 ms ease-out
///   * breathing pulse (record dot): 1.2 s ease-in-out, infinite
///   * equalizer bar retargets: 180–260 ms randomized per bar
///
/// Reduce Motion: pulse + equalizer freeze, width transitions become instant.
/// Content cross-fades are preserved (they're information, not ornament).
struct PillView: View {
    @ObservedObject var model: PillViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of the pill body. The hosting window is sized slightly larger
    /// to leave room for drop shadow.
    private static let pillHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 19

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(.horizontal, 16)
        .frame(height: Self.pillHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
        )
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.92)),
                removal: .opacity.combined(with: .offset(y: -8))
            )
        )
    }
}

// MARK: - Recording

private struct RecordingContent: View {
    let elapsed: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                PulsingDot(color: Color(nsColor: .systemRed), reduceMotion: reduceMotion)
                Equalizer(reduceMotion: reduceMotion)
                    .frame(width: 24, height: 16)
            }
            Spacer(minLength: 8)
            Text(PillViewModel.formatElapsed(elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

private struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && !reduceMotion ? 1.15 : 1.0)
            .animation(
                reduceMotion ? nil :
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

private struct Equalizer: View {
    let reduceMotion: Bool
    private let barCount = 4
    @State private var heights: [CGFloat]
    @State private var durations: [Double]

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        _heights = State(initialValue: (0..<4).map { _ in CGFloat.random(in: 0.2...1.0) })
        _durations = State(initialValue: (0..<4).map { _ in Double.random(in: 0.18...0.26) })
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 3, height: barHeight(for: i, in: geo.size.height))
                        .animation(
                            reduceMotion ? nil :
                                .easeInOut(duration: durations[i]),
                            value: heights[i]
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            guard !reduceMotion else { return }
            scheduleRandomize()
        }
    }

    private func barHeight(for index: Int, in available: CGFloat) -> CGFloat {
        if reduceMotion { return available * 0.5 }
        return max(2, available * heights[index])
    }

    private func scheduleRandomize() {
        for i in 0..<barCount {
            Timer.scheduledTimer(withTimeInterval: durations[i], repeats: true) { _ in
                DispatchQueue.main.async {
                    heights[i] = CGFloat.random(in: 0.15...1.0)
                    durations[i] = Double.random(in: 0.18...0.26)
                }
            }
        }
    }
}

// MARK: - Transcribing

private struct TranscribingContent: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemBlue))
                .frame(width: 8, height: 8)
            Spacer(minLength: 4)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Transcribing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
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
                    .frame(width: 5, height: 5)
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
                .frame(width: 8, height: 8)
            Text(preview)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(shortened)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
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
