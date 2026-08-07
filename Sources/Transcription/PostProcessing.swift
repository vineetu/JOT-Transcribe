import Foundation
import JotTextPipeline

/// Text cleanup applied to every local transcript before it reaches the
/// clipboard / the user.
///
/// The rule set itself (trim, collapse repeated interior whitespace inside
/// each paragraph, preserve paragraph breaks, drop stray spaces before
/// sentence punctuation) now lives in the shared `JotTextPipeline` package
/// (`PostProcessing.apply`) so the app and the `jot` CLI run one
/// implementation, pinned by the package's golden-fixture suite. This file
/// keeps only the app's per-model routing.
///
/// The English/Latin branch is the shared rule set. The Japanese branch is
/// wired but currently a passthrough — it will only diverge once we
/// empirically verify the punctuation bytes the shipped Parakeet JA model
/// emits (full-width vs ASCII). See `docs/plans/japanese-support.md` items 6
/// and 12.
public enum PostProcessing {
    public static func apply(_ text: String, language: ParakeetModelID = .tdt_0_6b_v3) -> String {
        guard !text.isEmpty else { return "" }

        switch language {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .nemotron_en:
            return JotTextPipeline.PostProcessing.apply(text)
        case .tdt_0_6b_ja:
            return applyJapanese(text)
        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // These emit clean native punctuation/casing across scripts (CJK,
            // Arabic, Devanagari, …); the Latin regex chain would mangle
            // non-Latin output. Passthrough.
            return text
        }
    }

    private static func applyJapanese(_ text: String) -> String {
        // TODO: empirical punctuation verification per docs/plans/japanese-support.md item 12 — currently passthrough
        return text
    }
}
