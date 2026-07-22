import FluidAudio

/// Disambiguation alias for the ASR engine's per-word timing type.
///
/// The app links BOTH `FluidAudio` and `JotVocabCore`, and each exports a public
/// `TokenTiming`, so the bare name is ambiguous in any file that imports both
/// (notably `VocabularyRescorerHolder`, which maps the engine's timings into the
/// package's neutral value type at the gate seam). The usual fix — module-
/// qualifying as `FluidAudio.TokenTiming` — does NOT work here, because the
/// `FluidAudio` module also contains a type named `FluidAudio`, so
/// `FluidAudio.TokenTiming` resolves against that TYPE and fails to compile.
/// This file imports ONLY `FluidAudio`, where `TokenTiming` is unambiguous, and
/// re-exports it under a distinct name the dual-import call sites can use.
public typealias EngineTokenTiming = TokenTiming
