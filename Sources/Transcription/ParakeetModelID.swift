import FluidAudio
import Foundation

/// Identifiers for ASR model choices Jot knows how to migrate, cache,
/// download, and render.
///
/// The original v3 cases (and v1.10-vintage v3 + Nemotron pairing) stay
/// in the enum so stored `jot.defaultModelID` values can be migrated and
/// rollback builds can still read their caches, but they are no longer
/// user-selectable. The visible picker is now four choices:
/// - multilingual Parakeet v3 batch with English EOU live preview,
/// - Japanese Parakeet,
/// - legacy English Parakeet v2 batch with EOU live preview,
/// - English-only Nemotron streaming.
///
/// Nemotron is not an `AsrManager` model. It is loaded through
/// `StreamingNemotronAsrManager`, so callers that need FluidAudio's batch
/// `AsrModelVersion` must switch explicitly instead of assuming every case
/// has a batch backend.
public enum ParakeetModelID: String, CaseIterable, Sendable {
    case tdt_0_6b_v3
    case tdt_0_6b_v3_int4
    case tdt_0_6b_ja
    /// Legacy English-only batch + EOU streaming combo. Kept selectable for
    /// existing users, but marked deprecated in current UI.
    case tdt_0_6b_v2_en_streaming
    /// Pre-v1.12 default. Multilingual Parakeet v3 batch paired with
    /// Nemotron English live preview. Retired in v1.12: the Nemotron live
    /// preview was producing more accurate English than the v3 batch
    /// finalized to, so users saw a visible regression at recording stop.
    /// Kept here only so stored `jot.defaultModelID` values can be migrated
    /// to `.tdt_0_6b_v3_eou_streaming` on first launch of v1.12. Not user-
    /// selectable.
    case tdt_0_6b_v3_nemotron_streaming
    /// Current default for multilingual users. Parakeet v3 batch final
    /// transcript with English EOU live preview in the recording pill.
    /// EOU is intentionally a lighter, less accurate streaming model so
    /// the live preview reads as a rough draft that gets replaced by the
    /// more accurate batch final at stop — no "transcript got worse"
    /// surprise. Users who want a higher-quality streaming model as the
    /// primary use `.nemotron_en` directly.
    case tdt_0_6b_v3_eou_streaming
    /// English-only Nemotron option. One streaming model powers both live
    /// preview and the final transcript.
    case nemotron_en

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
            return "Parakeet v2 + EOU live preview (deprecated)"
        case .tdt_0_6b_v3_nemotron_streaming:
            return "Parakeet v3 (multilingual) + Nemotron live preview"
        case .tdt_0_6b_v3_eou_streaming:
            return "Parakeet v3 (multilingual) + EOU live preview"
        case .nemotron_en:
            return "Nemotron (English, lighter)"
        }
    }

    /// Best-effort on-disk footprint in bytes. Used by UI to display download
    /// size before the fetch starts. Value is approximate; the authoritative
    /// size comes from HuggingFace at fetch time. CTC 110M for custom
    /// vocabulary is shared across compatible Parakeet options and is not
    /// counted here.
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
        case .tdt_0_6b_v3_nemotron_streaming:
            return 1_850_000_000
        case .tdt_0_6b_v3_eou_streaming:
            // v3 batch ≈ 461 MB on disk + EOU 120M ≈ 428 MB on disk.
            return 890_000_000
        case .nemotron_en:
            return 600_000_000
        }
    }

    /// The FluidAudio SDK's batch ASR version this identifier maps to.
    /// Do not call for `.nemotron_en`: Nemotron is loaded outside
    /// `AsrManager`.
    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return .v3
        case .tdt_0_6b_ja:
            return .tdtJa
        case .tdt_0_6b_v2_en_streaming:
            return .v2
        case .nemotron_en:
            preconditionFailure("Nemotron is not an AsrManager model")
        }
    }

    /// FluidAudio encoder precision for batch Parakeet models. Nemotron has
    /// its own int8 encoder under `encoder/encoder_int8.mlmodelc`, so this
    /// property is irrelevant for `.nemotron_en`.
    var encoderPrecision: ParakeetEncoderPrecision {
        switch self {
        case .tdt_0_6b_v3_int4:
            return .int4
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming:
            return .int8
        case .nemotron_en:
            preconditionFailure("Nemotron is not an AsrManager model")
        }
    }

    /// Name of the Jot-managed subdirectory under
    /// `~/Library/Application Support/Jot/Models/Parakeet/`.
    ///
    /// For batch Parakeet options this is the directory handed to
    /// FluidAudio's downloader/loader. The visible multilingual option
    /// deliberately reuses the default v3 cache so users who already
    /// downloaded v3 do not fetch that batch encoder again. For
    /// `.nemotron_en`, this is the dedicated Nemotron streaming bundle
    /// directory.
    var repoFolderName: String {
        switch self {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .tdt_0_6b_v3_int4:
            return "parakeet-tdt-0.6b-v3-coreml-int4"
        case .tdt_0_6b_ja:
            // FluidAudio 0.13.7+ renamed `Repo.parakeetCtcJa` →
            // `Repo.parakeetJa` (the JA HF repo carries both CTC and TDT
            // weights; the old name was misleading). Keeping this aligned
            // with the SDK's actual on-disk folder name makes the cache
            // layout legible.
            return "parakeet-ja"
        case .tdt_0_6b_v2_en_streaming:
            return "parakeet-tdt-0.6b-v2-coreml"
        case .nemotron_en:
            return "nemotron-streaming-en-1120ms"
        }
    }

    /// `true` when FluidAudio's batch `AsrManager` provides the final
    /// transcript for this model choice.
    var usesBatchAsrManager: Bool {
        switch self {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return true
        case .nemotron_en:
            return false
        }
    }

    /// `true` when the option pairs a streaming engine with recording.
    /// Current visible streaming options use EOU (v2 legacy, v3 default)
    /// and Nemotron (English-only standalone). The retired v3+Nemotron
    /// pairing is kept here for migration anchors only.
    public var supportsStreaming: Bool {
        switch self {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return false
        case .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .nemotron_en:
            return true
        }
    }

    /// `true` when this case should appear in current user-facing pickers.
    /// `tdt_0_6b_v3_nemotron_streaming` was demoted in v1.12 — kept as a
    /// migration anchor only.
    public var isUserSelectable: Bool {
        switch self {
        case .tdt_0_6b_v3_eou_streaming,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .nemotron_en:
            return true
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_v3_nemotron_streaming:
            return false
        }
    }

    /// `true` when the option remains available only for compatibility.
    public var isDeprecated: Bool {
        switch self {
        case .tdt_0_6b_v2_en_streaming:
            return true
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .nemotron_en:
            return false
        }
    }

    /// `true` when the option should be labelled as experimental.
    public var isExperimental: Bool {
        false
    }

    /// `true` when the option should be labelled as a smaller-footprint
    /// variant. No currently visible option uses the legacy "Lighter" badge.
    public var isLighterVariant: Bool {
        false
    }

    /// Extra descriptive copy for model picker rows that need more context
    /// than the install state and approximate footprint.
    public var detailText: String? {
        switch self {
        case .tdt_0_6b_v3_int4:
            return "Same multilingual v3 with smaller, faster int4-quantized encoder. Slightly higher WER (<0.5%) for ~11% smaller download and lower RAM."
        case .tdt_0_6b_v3_eou_streaming:
            return "Multilingual batch transcript with English live preview in the recording pill. The live preview is a rough draft that gets replaced by the more accurate final transcript at stop. Best general-purpose option."
        case .tdt_0_6b_v2_en_streaming:
            return "Legacy option. Available for existing users; will be removed in a future release."
        case .nemotron_en:
            return "English-only. Single model handles both the final transcript and the live preview in the pill. Smaller and faster than option 1; best on read-style English; v2/v3 batch is more accurate on noisy/conversational audio. Doesn't support custom vocabulary — switch to Parakeet v3 + EOU if you rely on boosted terms."
        case .tdt_0_6b_v3, .tdt_0_6b_v3_nemotron_streaming, .tdt_0_6b_ja:
            return nil
        }
    }

    /// `true` when the option should be visually surfaced as the
    /// recommended pick in the wizard and Settings → Transcription.
    ///
    /// Note the asymmetry with the technical fresh-install default
    /// (`TranscriberHolder` boots new users on `tdt_0_6b_v3_eou_streaming`
    /// for safe multilingual coverage). The recommended badge sits on
    /// the Nemotron-only English option because for the majority of
    /// English-speaking users — which is most of Jot's audience — the
    /// lighter, faster single-model Nemotron path is what we'd actually
    /// recommend they pick. Users who need multilingual or Japanese
    /// still see those options and can switch without losing anything.
    /// Order in `visibleCases` is unchanged; only the badge moved.
    public var isRecommended: Bool {
        switch self {
        case .nemotron_en:
            return true
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return false
        }
    }

    /// Subset of `allCases` rendered in user-facing model pickers.
    public static var visibleCases: [ParakeetModelID] {
        [
            .tdt_0_6b_v3_eou_streaming,
            .tdt_0_6b_ja,
            .tdt_0_6b_v2_en_streaming,
            .nemotron_en,
        ]
    }
}
