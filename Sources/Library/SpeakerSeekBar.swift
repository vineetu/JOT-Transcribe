import SwiftUI

/// Seek bar whose track IS the speaker timeline: one coloured block per
/// speaker run, neutral track in the gaps, a knob at the playhead. Click to
/// seek, drag to scrub. Shown in `RecordingDetailView.playbackBlock` only for
/// recordings with ≥2 speakers; everything else keeps the plain `Slider`.
///
/// Performance: the detail view re-renders at the 10 Hz playback tick. The
/// blocks live in `SpeakerSeekTrack`, an `Equatable` view keyed on the runs +
/// duration, so the Canvas redraws only when the timeline or colours change;
/// each tick moves only the knob.
struct SpeakerSeekBar: View {
    /// A contiguous span attributed to one speaker, already coloured.
    struct Run: Equatable {
        let label: String
        let start: TimeInterval
        let end: TimeInterval
        let color: Color
    }

    let runs: [Run]
    /// Speakers in first-appearance order with their colour (the legend).
    let legend: [(label: String, color: Color)]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isEnabled: Bool
    let onSeek: (TimeInterval) -> Void

    /// Local playhead while dragging, so the knob tracks the pointer even
    /// between controller ticks.
    @State private var dragTime: TimeInterval?
    @State private var hoverTime: TimeInterval?

    private static let trackHeight: CGFloat = 8
    private static let knobSize: CGFloat = 12

    /// Build runs + legend from stored segments using the transcript's own
    /// `label → Color` map, so bar, legend, and speaker headings always match.
    init(
        segments: [SpeakerTimelineSegment],
        colorMap: [String: Color],
        currentTime: TimeInterval,
        duration: TimeInterval,
        isEnabled: Bool,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        // Raw stored segments (not display-coalesced) so pauses inside one
        // speaker's turn still show as neutral gaps.
        let runs = segments.map {
            Run(label: $0.speakerLabel, start: $0.startSec, end: $0.endSec,
                color: colorMap[$0.speakerLabel] ?? .secondary)
        }
        var seen: [String] = []
        for run in runs where !seen.contains(run.label) { seen.append(run.label) }
        self.runs = runs
        self.legend = seen.map { ($0, colorMap[$0] ?? .secondary) }
        self.currentTime = currentTime
        self.duration = duration
        self.isEnabled = isEnabled
        self.onSeek = onSeek
    }

    private var span: TimeInterval { max(duration, 0.001) }
    private var shownTime: TimeInterval { dragTime ?? currentTime }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            legendRow
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inset = Self.knobSize / 2
            let usable = max(width - Self.knobSize, 1)
            let fraction = min(max(shownTime / span, 0), 1)

            ZStack(alignment: .leading) {
                SpeakerSeekTrack(runs: runs, duration: span)
                    .equatable()
                    .frame(height: Self.trackHeight)
                    .padding(.horizontal, inset)
                    .opacity(isEnabled ? 1 : 0.5)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: usable * fraction)
                    .opacity(isEnabled ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let t = time(atX: value.location.x, inset: inset, usable: usable)
                        dragTime = t
                        onSeek(t)
                    }
                    .onEnded { _ in dragTime = nil }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverTime = time(atX: p.x, inset: inset, usable: usable)
                case .ended: hoverTime = nil
                }
            }
        }
        .frame(height: 16)
        .help(hoverText)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onSeek(min(currentTime + 5, duration))
            case .decrement: onSeek(max(currentTime - 5, 0))
            @unknown default: break
            }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            ForEach(legend, id: \.label) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(entry.color)
                        .frame(width: 8, height: 8)
                    Text(entry.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Self.knobSize / 2)
        .accessibilityElement(children: .combine)
    }

    private func time(atX x: CGFloat, inset: CGFloat, usable: CGFloat) -> TimeInterval {
        let f = min(max((x - inset) / usable, 0), 1)
        return f * span
    }

    private func speaker(at t: TimeInterval) -> String? {
        runs.first { t >= $0.start && t < $0.end }?.label
    }

    private var hoverText: String {
        guard let t = hoverTime else { return "" }
        if let who = speaker(at: t) { return "\(who) · \(Self.format(t))" }
        return Self.format(t)
    }

    private var accessibilityValueText: String {
        let base = "\(Self.format(currentTime)) of \(Self.format(duration))"
        if let who = speaker(at: currentTime) { return "\(base), \(who)" }
        return base
    }

    static func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The static coloured track. `Equatable` so `.equatable()` lets SwiftUI skip
/// the Canvas on playback ticks — it redraws only when runs/duration change
/// (or the colour scheme flips, which re-resolves the semantic colours).
private struct SpeakerSeekTrack: View, Equatable {
    let runs: [SpeakerSeekBar.Run]
    let duration: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2, style: .continuous)
            ctx.clip(to: track)
            ctx.fill(track, with: .color(Color.primary.opacity(0.12)))
            for run in runs {
                let x0 = CGFloat(max(run.start, 0) / duration) * size.width
                let x1 = CGFloat(min(run.end, duration) / duration) * size.width
                guard x1 > x0 else { continue }
                // Min ~1 pt so very short turns stay visible.
                let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
                ctx.fill(Path(rect), with: .color(run.color))
            }
        }
    }
}
