import FluidAudio
import Foundation

/// Identifiers for ASR model choices Jot knows how to migrate, cache,
/// download, and render.
///
/// The original v3 cases (and v1.10-vintage v3 + Nemotron pairing) stay
/// in the enum so stored `jot.defaultModelID` values can be migrated and
/// rollback builds can still read their caches, but they are no longer
/// user-selectable. The visible picker is now four choices:
/// - multilingual Parakeet v3 batch with a batch-pseudo-streaming live preview,
/// - Japanese Parakeet,
/// - legacy English Parakeet v2 batch with a batch-pseudo-streaming live preview,
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
    /// Legacy English-only Parakeet v2 batch. Live preview now comes from the
    /// batch-pseudo-streaming `PreviewScheduler` (no separate streaming
    /// bundle). Kept selectable for existing users, but deprecated in current
    /// UI. Raw value preserved so stored `jot.defaultModelID` resolves.
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
    /// transcript with a batch-pseudo-streaming live preview in the recording
    /// pill, driven by `PreviewScheduler` re-running the v3 batch weights over
    /// a trailing window (no separate streaming bundle). The preview reads as a
    /// rough draft that is replaced by the final batch transcript at stop.
    /// Raw value preserved (it historically named an EOU pairing) so existing
    /// users' stored `jot.defaultModelID` resolves with no migration. Users who
    /// want a single streaming model as the primary use `.nemotron_en`.
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
            return "Parakeet v2 + live preview (deprecated)"
        case .tdt_0_6b_v3_nemotron_streaming:
            return "Parakeet v3 (multilingual) + Nemotron live preview"
        case .tdt_0_6b_v3_eou_streaming:
            return "Parakeet v3 (multilingual) + live preview"
        case .nemotron_en:
            return "Nemotron English"
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
            // Batch only — live preview re-uses the batch weights
            // (PreviewScheduler), no separate streaming bundle.
            return 600_000_000
        case .tdt_0_6b_v3_nemotron_streaming:
            return 1_850_000_000
        case .tdt_0_6b_v3_eou_streaming:
            // Batch only — live preview re-uses the batch weights
            // (PreviewScheduler), no separate streaming bundle. v3 batch
            // ≈ 461 MB on disk.
            return 461_000_000
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

    /// `true` when the option pairs a SEPARATE streaming bundle (a distinct
    /// on-disk model) with recording — i.e. a model side that must be
    /// downloaded and cached in addition to the batch bundle. Only Nemotron
    /// qualifies now (English-only standalone, plus the retired v3+Nemotron
    /// migration anchor). v2 / v3 / JA drive their live preview from the batch
    /// weights via `PreviewScheduler`, so they have no separate streaming
    /// bundle and report `false`.
    public var supportsStreaming: Bool {
        switch self {
        // v2 / v3 / JA no longer pair a separate streaming bundle: their live
        // preview comes from the batch-pseudo-streaming `PreviewScheduler`
        // (re-running the batch model over a trailing window), routed by
        // explicit case match in `JotComposition.transcriberFactory` — NOT via
        // this flag. So `supportsStreaming == false` correctly means "fetches /
        // caches only its batch bundle" for these cases.
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return false
        case .tdt_0_6b_v3_nemotron_streaming,
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
            return "Multilingual batch transcript with a live preview in the recording pill. The live preview is a rough draft that gets replaced by the final transcript at stop. Best general-purpose option."
        case .tdt_0_6b_v2_en_streaming:
            return "Legacy option. Available for existing users; will be removed in a future release."
        case .nemotron_en:
            return "English-only. Single model handles both the final transcript and the live preview in the pill. Smaller and faster than option 1; best on read-style English; v2/v3 batch is more accurate on noisy/conversational audio. Doesn't support custom vocabulary — switch to Parakeet v3 if you rely on boosted terms."
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
