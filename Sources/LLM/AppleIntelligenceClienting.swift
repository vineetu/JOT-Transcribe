import Foundation

/// OS-boundary seam for Apple Intelligence (`FoundationModels.LanguageModelSession`).
/// The live conformer is `AppleIntelligenceClient` (actor wrapping
/// `FoundationModels.LanguageModelSession.streamResponse(to:)`); harness
/// conformers in `Tests/JotHarness/` return canned strings without touching
/// the on-device model.
///
/// Two operational methods (`transform`, `articulate`) plus an availability
/// gate (`isAvailable`). Method signatures mirror `AppleIntelligenceClient`'s
/// existing public surface verbatim.
///
/// `Sendable` because conformers cross actor isolation domains —
/// `AppleIntelligenceClient` is itself an actor (implicitly `Sendable`),
/// and `LLMClient` (also an actor) reads the seam.
protocol AppleIntelligenceClienting: Sendable {
    /// `true` when FoundationModels exists AND the current machine reports
    /// the default system language model as `.available`. Returns `false`
    /// on older macOS, non-AI-eligible hardware, or when Apple Intelligence
    /// is disabled in System Settings.
    ///
    /// `nonisolated` on actor conformers so the read can happen from any
    /// isolation domain — the underlying check is a synchronous read of
    /// `SystemLanguageModel.default.availability`, which carries no actor
    /// state.
    nonisolated var isAvailable: Bool { get }

    /// Clean up a raw dictation transcript. The caller passes the system
    /// prompt (`instruction`) and the raw transcript; the seam returns the
    /// cleaned text. Throws `LLMError.appleIntelligenceUnavailable` when
    /// the model isn't available on this machine.
    func transform(transcript: String, instruction: String) async throws -> String

    /// Articulate a user selection. The caller composes the combined system
    /// prompt (shared invariants + branch tendency) into `branchPrompt` and
    /// hands the seam the selection plus the user's (voice or fixed)
    /// instruction. Throws `LLMError.appleIntelligenceUnavailable` when
    /// the model isn't available.
    func articulate(selectedText: String, instruction: String, branchPrompt: String) async throws -> String

    /// Stream an Ask Jot turn through Apple Intelligence. Returns a
    /// delta-token stream backed by `LanguageModelSession.streamResponse`.
    ///
    /// The caller passes a `request.session` either to reuse an
    /// existing FoundationModels session (KV-cache warm, conversation
    /// history retained) or `nil` to mint a fresh one. Errors —
    /// including the original `LanguageModelSession.GenerationError`
    /// cases (`exceededContextWindowSize`, `guardrailViolation`,
    /// `unsupportedLanguageOrLocale`) — propagate verbatim so consumers
    /// can switch on the typed error.
    ///
    /// Returns an empty stream that immediately finishes with
    /// `LLMError.appleIntelligenceUnavailable` on macOS < 26 or when
    /// `FoundationModels` is missing.
    nonisolated func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error>
}
