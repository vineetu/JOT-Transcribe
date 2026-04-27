import FluidAudio
import Foundation

/// Identifiers for Parakeet ASR model variants used by Jot.
///
/// v1 shipped only the multilingual TDT 0.6B v3. Phase 4 adds the
/// Japanese-only TDT 0.6B (`.tdt_0_6b_ja`) — see
/// `docs/plans/japanese-support.md`. Two-model coexistence is the
/// pattern future variants slot into without reshaping the download
/// layer; only the model `TranscriberHolder.primaryModelID` selects
/// is hot in memory.
public enum ParakeetModelID: String, CaseIterable, Sendable {
    case tdt_0_6b_v3
    case tdt_0_6b_ja

    /// Human-readable name for Setup Wizard / Settings UI.
    public var displayName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "Parakeet TDT 0.6B v3 (multilingual)"
        case .tdt_0_6b_ja:
            return "Parakeet 0.6B Japanese"
        }
    }

    /// Best-effort on-disk footprint in bytes. Used by UI to display download
    /// size before the fetch starts. Value is approximate; the authoritative
    /// size comes from HuggingFace at fetch time.
    ///
    /// Both v3 and JA CoreML bundles are ~0.6B parameters in float16/float32
    /// mix → roughly 1.25 GB on disk each.
    public var approxBytes: Int64 {
        switch self {
        case .tdt_0_6b_v3:
            return 1_250_000_000
        case .tdt_0_6b_ja:
            return 1_250_000_000
        }
    }

    /// The FluidAudio SDK's version enum this identifier maps to.
    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .tdt_0_6b_v3:
            return .v3
        case .tdt_0_6b_ja:
            return .tdtJa
        }
    }

    /// Name of the subdirectory FluidAudio writes model files into, under
    /// whatever parent directory we hand to its downloader. Conceptually a
    /// per-id placeholder — `ModelCache.cacheURL(for:)` constructs
    /// `root/<repoFolderName>` and FluidAudio's `AsrModels.download`
    /// strips the last component back to `root` before re-appending its
    /// own `Repo.folderName`. The two values don't have to be equal, but
    /// keeping them aligned with the SDK's actual on-disk folder name
    /// makes the layout legible when inspecting the cache directly.
    var repoFolderName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .tdt_0_6b_ja:
            // FluidAudio 0.13.7+ renamed `Repo.parakeetCtcJa` →
            // `Repo.parakeetJa` (the JA HF repo carries both CTC and TDT
            // weights; the old name was misleading). The SDK now writes
            // JA model files under `<parent>/parakeet-ja/` per
            // `Repo.parakeetJa.folderName`. Strictly speaking the value
            // returned here is cosmetic — every SDK call recomputes the
            // path as `parent + version.repo.folderName` and ignores
            // whatever subdirectory we pass in — but keeping it aligned
            // with the SDK's actual on-disk folder name makes the cache
            // layout legible when inspecting `~/Library/Application
            // Support/Jot/Models/Parakeet/` directly.
            return "parakeet-ja"
        }
    }
}
