import SwiftUI

/// Placeholder waveform strip. A real peak-per-pixel renderer lands alongside
/// the re-transcription pipeline — until then we show a quiet hairline strip
/// so the detail layout stays honest about the missing affordance.
struct WaveformView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
            HStack(spacing: 2) {
                ForEach(0..<48, id: \.self) { i in
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2, height: placeholderHeight(for: i))
                }
            }
        }
        .frame(height: 56)
        .overlay(alignment: .bottomTrailing) {
            Text("Waveform rendering arrives in a later release")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(6)
        }
    }

    private func placeholderHeight(for i: Int) -> CGFloat {
        // Deterministic pseudo-shape; no RNG so the stripe is stable across
        // redraws and screenshot diffs.
        let phase = Double(i) * 0.35
        return 8 + CGFloat(abs(sin(phase)) * 24)
    }
}
