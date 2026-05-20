import FluidAudio
import Foundation

/// Identifiers for Parakeet ASR model variants used by Jot.
///
/// v1 shipped only the multilingual TDT 0.6B v3. v1.4 added the
/// Japanese-only TDT 0.6B (`.tdt_0_6b_ja`). v2.0 introduces
/// `.tdt_0_6b_v2_en_streaming` — a dual-bundle option that pairs the
/// English-only TDT v2 batch model with the Parakeet EOU 120M streaming
/// encoder for live transcript preview. v2.x also exposes
/// `.tdt_0_6b_v3_int4`, the same multilingual v3 model with FluidAudio's
/// int4 encoder precision. The case set is small enough that consumers
/// exhaustively switch on it rather than carry generic capability bits;
/// new variants slot in by adding a case and chasing the resulting
/// compiler errors.
public enum ParakeetModelID: String, CaseIterable, Sendable {
    case tdt_0_6b_v3
    case tdt_0_6b_v3_int4
    case tdt_0_6b_ja
    /// English-only batch + streaming combo. Internally dual-bundle:
    /// TDT v2 for the final transcript, EOU 120M (160 ms chunks) for
    /// the live partial preview shown in the recording pill. The two
    /// bundles are cached and downloaded as a unit (§9 / §11 R2).
    case tdt_0_6b_v2_en_streaming

    /// Human-readable name for Setup Wizard / Settings UI.
    public var displayName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "Parakeet TDT 0.6B v3 (multilingual)"
        case .tdt_0_6b_v3_int4:
            return "Parakeet TDT 0.6B v3 (int4, lighter)"
        case .tdt_0_6b_ja:
            return "Parakeet 0.6B Japanese"
        case .tdt_0_6b_v2_en_streaming:
            return "Parakeet 0.6B v2 (English, live preview)"
        }
    }

    /// Best-effort on-disk footprint in bytes. Used by UI to display download
    /// size before the fetch starts. Value is approximate; the authoritative
    /// size comes from HuggingFace at fetch time.
    ///
    /// v3 and JA CoreML bundles are ~0.6B parameters in float16/float32
    /// mix → roughly 1.25 GB on disk each. The int4 v3 option swaps only
    /// the encoder for FluidAudio's quantized bundle, putting its total
    /// around 1.1 GB. The streaming option pairs TDT v2 (~600 MB) with
    /// the EOU 120M streaming encoder (~120 MB), totaling ~720 MB. CTC
    /// 110M for custom vocabulary is shared across all options and is
    /// not counted here.
    public var approxBytes: Int64 {
        switch self {
        case .tdt_0_6b_v3:
            return 1_250_000_000
        case .tdt_0_6b_v3_int4:
            return 1_100_000_000
        case .tdt_0_6b_ja:
            return 1_250_000_000
        case .tdt_0_6b_v2_en_streaming:
            return 720_000_000
        }
    }

    /// The FluidAudio SDK's batch ASR version this identifier maps to.
    /// For the streaming option, the value points at the *batch* TDT v2;
    /// the streaming side runs through `StreamingEouAsrManager`, which
    /// has its own model loader.
    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4:
            return .v3
        case .tdt_0_6b_ja:
            return .tdtJa
        case .tdt_0_6b_v2_en_streaming:
            return .v2
        }
    }

    /// FluidAudio encoder precision for v3 split-frontend models. Int4 is
    /// orthogonal to `AsrModelVersion`: both v3 options load `.v3`, and this
    /// flag selects which encoder bundle FluidAudio fetches and loads.
    var encoderPrecision: ParakeetEncoderPrecision {
        switch self {
        case .tdt_0_6b_v3_int4:
            return .int4
        case .tdt_0_6b_v3, .tdt_0_6b_ja, .tdt_0_6b_v2_en_streaming:
            return .int8
        }
    }

    /// Name of the subdirectory FluidAudio writes batch model files into,
    /// under whatever parent directory we hand to its downloader.
    /// Conceptually a per-id placeholder. For most options,
    /// `ModelCache.cacheURL(for:)` constructs `root/<repoFolderName>` and
    /// FluidAudio's `AsrModels.download` strips the last component back to
    /// `root` before re-appending its own `Repo.folderName`. The int4 v3
    /// option uses this as a dedicated parent folder so FluidAudio's v3 repo
    /// folder can live under it without sharing the default v3 cache slot.
    /// Keeping these names aligned with the SDK's model identity makes the
    /// layout legible when inspecting the cache directly.
    ///
    /// For the streaming option this returns the batch (TDT v2) folder;
    /// the EOU streaming bundle has its own slot under
    /// `root/parakeet-eou-streaming/160ms/` reached via
    /// `ModelCache.streamingPartialCacheURL(for:)`.
    var repoFolderName: String {
        switch self {
        case .tdt_0_6b_v3:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .tdt_0_6b_v3_int4:
            return "parakeet-tdt-0.6b-v3-coreml-int4"
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
        case .tdt_0_6b_v2_en_streaming:
            return "parakeet-tdt-0.6b-v2-coreml"
        }
    }

    /// `true` when this option pairs a streaming engine with the batch
    /// transcriber. Today only the `.tdt_0_6b_v2_en_streaming` option
    /// returns true. Consumers use this to decide whether to mint a
    /// `DualPipelineTranscriber` (Phase 2) and to wire the audio
    /// streaming sink in `VoiceInputPipeline`.
    public var supportsStreaming: Bool {
        switch self {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return false
        case .tdt_0_6b_v2_en_streaming:
            return true
        }
    }

    /// `true` when the option is shipped under an experimental label.
    /// UI surfaces (Settings → Transcription, Setup Wizard model step)
    /// render an "Experimental" badge next to the display name so the
    /// user knows the option is opt-in / best-effort. Currently only
    /// the dual-bundle streaming option carries this flag — the live-
    /// preview path still has known flakiness on cold ANE state and
    /// degrades gracefully to batch-only when the streaming engine
    /// hasn't warmed yet.
    public var isExperimental: Bool {
        switch self {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return false
        case .tdt_0_6b_v2_en_streaming:
            return true
        }
    }

    /// `true` when the option should be labelled as the lighter local
    /// footprint variant instead of experimental or recommended.
    public var isLighterVariant: Bool {
        switch self {
        case .tdt_0_6b_v3_int4:
            return true
        case .tdt_0_6b_v3, .tdt_0_6b_ja, .tdt_0_6b_v2_en_streaming:
            return false
        }
    }

    /// Extra descriptive copy for model picker rows that need more context
    /// than the install state and approximate footprint.
    public var detailText: String? {
        switch self {
        case .tdt_0_6b_v3_int4:
            return "Same multilingual v3 with smaller, faster int4-quantized encoder. Slightly higher WER (<0.5%) for ~11% smaller download and lower RAM."
        case .tdt_0_6b_v3, .tdt_0_6b_ja, .tdt_0_6b_v2_en_streaming:
            return nil
        }
    }

    /// `true` when the option should be visually surfaced as the
    /// recommended pick. UI renders a "Recommended" badge alongside
    /// the display name (and the Experimental badge when both apply).
    /// The streaming option carries this flag — its live preview is
    /// the headline experience we want users to try first, even though
    /// it's still labelled Experimental.
    public var isRecommended: Bool {
        switch self {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return false
        case .tdt_0_6b_v2_en_streaming:
            return true
        }
    }

    /// Subset of `allCases` that should be rendered in user-facing UI
    /// (Settings → Transcription, Setup Wizard's Model step). Lets a
    /// case land on the enum before its UI is wired without forcing
    /// every iteration site behind `#if DEBUG`.
    ///
    /// Phase 1 of the streaming option excludes the streaming case
    /// from this list so the plumbing can ship hidden. Phase 3 adds it
    /// alongside Settings/Wizard polish + classifier wiring. The
    /// filter remains in place after Phase 3 as future infrastructure
    /// for hidden / experimental options.
    public static var visibleCases: [ParakeetModelID] {
        [.tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja, .tdt_0_6b_v2_en_streaming]
    }
}
