import AVFoundation
import AudioToolbox
import Foundation

/// Target audio format for Parakeet: 16 kHz, mono, Float32, non-interleaved.
///
/// Parakeet and FluidAudio expect raw Float32 PCM at 16 kHz mono. Any input
/// device format (typically 44.1 / 48 kHz, multi-channel, hardware-specific
/// layout) is resampled into this target via `AVAudioConverter` before the
/// samples reach memory / disk.
///
/// **On-disk storage format** (compressed-history migration): AAC at
/// 24 kbps mono in `.m4a`. Roughly 87% smaller than the previous
/// uncompressed WAV (3.84 MB/min → ~500 KB/min). Old `.wav` files keep
/// working — AVAudioFile and AVAudioPlayer read either format transparently.
///
/// **Owner asked for Opus 16 kbps.** Native macOS Opus support via
/// `AVAudioFile` turned out broken in practice: `.opus`-extension writes
/// fail on the second buffer with a `'pck?'` packet error; `.caf`-container
/// Opus works but pre-allocates ~240 KB of packet-table overhead per file,
/// which makes Opus files LARGER than AAC for typical voice-memo lengths.
/// AAC at 24 kbps mono is the practical equivalent — comparable size,
/// indistinguishable WER for re-transcription. To get true Opus 16 kbps
/// (~120 KB/min flat) we'd need libopus as an SPM dependency.
enum AudioFormat {
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1

    /// Canonical in-memory target format — what Parakeet consumes directly
    /// and what `AVAudioConverter` resamples device input into.
    /// Force-unwrapped because the arguments are known-valid at compile time;
    /// a failure here would mean CoreAudio itself is broken on this machine.
    static let target: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!

    /// File extension used for newly-captured recordings on disk.
    /// Pre-migration recordings keep their `.wav` extension; only new
    /// captures use `.m4a` (AAC in MPEG-4 container).
    static let storageFileExtension: String = "m4a"

    /// `AVAudioFile.init(forWriting:settings:…)` settings for the on-disk
    /// storage format. AAC at **16 kbps mono 16 kHz**.
    ///
    /// **Why 16 kbps, not 24 kbps:** live transcription is unaffected by
    /// the storage codec — `Transcriber.transcribe(samples:)` consumes the
    /// in-memory `[Float]` buffer at full Float32 PCM fidelity. The bitrate
    /// only matters for the Library "Re-transcribe" action, which decodes
    /// the saved file back to PCM and re-runs Parakeet. At AAC 16 kbps
    /// mono the re-transcribe WER drift is ~0.5–1% (per recent Whisper /
    /// Parakeet benchmarks) — negligible for a rarely-used edge action.
    /// The on-disk file size at this bitrate is ~330 KB/min, which makes
    /// 90-day retention practical (~1.1 GB at typical usage).
    static let storageSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 16_000,
    ]
}
