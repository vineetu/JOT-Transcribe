import AVFoundation
import Foundation

// Port of Sources/Recording/AudioFormat.swift. Kept byte-for-byte compatible
// with the production format; the test harness must target the exact same
// canonical format the app uses so any format-math regression is caught.
//
// Phase 2 collapses this duplicate back into the production target.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: AVAudioChannelCount = 1

    public static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
}
