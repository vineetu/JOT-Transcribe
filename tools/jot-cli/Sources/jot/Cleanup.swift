import Foundation
import JotTextPipeline

/// The deterministic cleanup chain, composed in the same order and with the
/// same language gating as the app (`Transcriber.transcribeWithAsrManager`):
/// segment (any language, needs timings) → filler-clean (per-language regex,
/// identity for unvalidated languages) → number-normalize (English-only) →
/// PostProcessing final whitespace pass (Latin-safe; the CLI batch engine is
/// Parakeet v3, whose scripts the app routes through this same pass).
enum TranscriptCleanup {
    static func apply(
        _ text: String,
        tokenTimings: [JotTextPipeline.TokenTiming]?,
        language: CLILanguage
    ) -> String {
        guard !text.isEmpty else { return text }

        var working = text
        if let timings = tokenTimings, !timings.isEmpty {
            working = ParagraphSegmenter.segment(rescoredText: working, tokenTimings: timings)
        }
        // Filler + number stay English-gated, mirroring the app's
        // `applyEnglishCleanup` exactly. The shared package DOES carry
        // validated multilingual filler lists, but the app doesn't use them
        // yet — enabling them is an app+CLI decision made together, never a
        // one-sided CLI divergence (review finding: the same Spanish audio
        // must not lose "eh" here while keeping it in the app).
        if language.isEnglish {
            working = NumberNormalizer.normalize(FillerWordCleaner.clean(working))
        }
        return PostProcessing.apply(working)
    }
}
