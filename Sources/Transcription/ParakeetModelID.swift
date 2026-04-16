import FluidAudio
import Foundation

/// Identifiers for Parakeet ASR model variants used by Jot.
///
/// v1 only ships the multilingual TDT 0.6B v3. The enum exists so future
/// variants (English-only v2, CTC-110M for fast-path, etc.) can slot in
/// without reshaping the download layer.
public enum ParakeetModelID: String, CaseIterable, Sendable {
    case tdt_0_6b_v3

    /// Human-readable name for eventual Setup Wizard / Settings UI.
    public var displayName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "Parakeet TDT 0.6B v3 (multilingual)"
        }
    }

    /// Best-effort on-disk footprint in bytes. Used by UI to display download
    /// size before the fetch starts. Value is approximate; the authoritative
    /// size comes from HuggingFace at fetch time.
    ///
    /// v3 CoreML bundle (preprocessor + decoder + joint, fused encoder):
    /// ~0.6B parameters in float32/float16 mix → roughly 1.25 GB on disk.
    /// Refine once we have telemetry from real downloads.
    public var approxBytes: Int64 {
        switch self {
        case .tdt_0_6b_v3:
            return 1_250_000_000
        }
    }

    /// The FluidAudio SDK's version enum this identifier maps to.
    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .tdt_0_6b_v3:
            return .v3
        }
    }

    /// Name of the subdirectory FluidAudio writes model files into, under
    /// whatever parent directory we hand to its downloader. Must match the
    /// `Repo.folderName` FluidAudio uses internally — hard-coded here because
    /// that type is `internal` to the SDK.
    var repoFolderName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "parakeet-tdt-0.6b-v3-coreml"
        }
    }
}
