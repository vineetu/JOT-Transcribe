import AVFoundation
import Foundation

/// Target audio format for Parakeet: 16 kHz, mono, Float32, non-interleaved.
///
/// Parakeet and FluidAudio expect raw Float32 PCM at 16 kHz mono. Any input
/// device format (typically 44.1 / 48 kHz, multi-channel, hardware-specific
/// layout) is resampled into this target via `AVAudioConverter` before the
/// samples reach memory / disk.
enum AudioFormat {
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1

    /// Canonical target format used by the capture tap and the WAV file.
    /// Force-unwrapped because the arguments are known-valid at compile time —
    /// a failure here would mean CoreAudio itself is broken on this machine.
    static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
}
