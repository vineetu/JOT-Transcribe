import AVFoundation
import Combine
import Foundation

@MainActor
public final class AmplitudePublisher: ObservableObject {
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 24)

    func append(rms: Float) {
        // Store the instantaneous level per slot. An earlier implementation
        // pushed values through a peak follower (`max(rms, peak * 0.8)`),
        // which ratcheted upward during sustained speech and hid valleys —
        // the line only ever climbed. Raw rms preserves per-syllable peaks
        // AND the troughs between them, which is what the waveform is for.
        let clamped = min(max(rms, 0), 1)
        history.removeFirst()
        history.append(clamped)
    }

    func reset() {
        history = Array(repeating: 0, count: 24)
    }

    nonisolated static func rms(from buffer: AVAudioPCMBuffer) -> Float {
        guard
            buffer.frameLength > 0,
            let channelData = buffer.floatChannelData
        else {
            return 0
        }

        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(buffer.frameLength)
        let rms = sqrt(meanSquare)
        let dbfs = 20 * log10(max(rms, 1e-7))
        // Map -50..-15 dBFS to 0..1. Typical conversational speech sits around
        // -30 to -15 dBFS, so this puts normal voice at 0.55..1.0. Paired with
        // a sqrt power curve in the renderer, quiet phonemes still register
        // visibly instead of flatlining near the midline.
        let normalized = (dbfs + 50) / 35
        return min(max(normalized, 0), 1)
    }
}
