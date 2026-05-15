import Foundation

/// A snapshot of the user's current Jot configuration, built once per
/// `LanguageModelSession` creation and injected into the chatbot's
/// instructions (§4, §6). Never re-injected per turn — if the user
/// rebinds a shortcut mid-conversation, the snapshot only refreshes on
/// the next `clear()` or auto-recovery.
///
/// All fields are plain values (strings, bools, ints) so the struct
/// serializes cleanly into the formatted prompt block. No secrets land
/// here — no API keys, no clipboard contents, no transcripts. The
/// injection is meant to let the bot answer "what's my current
/// shortcut?" and "do I have Cleanup turned on?" style questions.
struct UserConfigSnapshot: Equatable {
    let toggleRecordingShortcut: String?
    let pushToTalkShortcut: String?
    let rewriteWithVoiceShortcut: String?
    let rewriteShortcut: String?
    let pasteLastShortcut: String?
    let cleanupEnabled: Bool
    let aiProviderDisplay: String?
    let modelDownloaded: Bool
    let retentionDays: Int
    let launchAtLogin: Bool
    let vocabularyEntryCount: Int

    /// Build a snapshot from current app state. Call sites pass in the
    /// bits that live outside UserDefaults (model-downloaded status is
    /// cached per-launch on AppDelegate, vocabulary count on the store)
    /// as plain values so this struct stays agnostic of the app's
    /// module graph and easy to unit-test.
    ///
    /// `@MainActor` because `KeyboardShortcuts.Shortcut.description` is
    /// itself MainActor-isolated in the current `sindresorhus` build.
    @MainActor
    static func current(
        modelDownloaded: Bool,
        vocabularyEntryCount: Int,
        aiProviderDisplay: String?,
        cleanupEnabled: Bool,
        launchAtLogin: Bool,
        retentionDays: Int
    ) -> UserConfigSnapshot {
        UserConfigSnapshot(
            toggleRecordingShortcut: SingleKeyMigration.effectiveBindingLabel(for: .toggleRecording),
            pushToTalkShortcut: SingleKeyMigration.effectiveBindingLabel(for: .pushToTalk),
            rewriteWithVoiceShortcut: SingleKeyMigration.effectiveBindingLabel(for: .rewriteWithVoice),
            rewriteShortcut: SingleKeyMigration.effectiveBindingLabel(for: .rewrite),
            pasteLastShortcut: SingleKeyMigration.effectiveBindingLabel(for: .pasteLastTranscription),
            cleanupEnabled: cleanupEnabled,
            aiProviderDisplay: aiProviderDisplay,
            modelDownloaded: modelDownloaded,
            retentionDays: retentionDays,
            launchAtLogin: launchAtLogin,
            vocabularyEntryCount: vocabularyEntryCount
        )
    }

    /// Pre-formatted block (~80 tokens per spec §6) slotted straight
    /// into the `instructions` string. Keep field order stable — the
    /// prompt design depends on "Toggle recording" appearing first.
    var formatted: String {
        let retention: String = retentionDays == 0 ? "forever" : "\(retentionDays) days"
        let provider = aiProviderDisplay ?? "not configured"
        return "toggle=\(toggleRecordingShortcut ?? "unbound"), push-to-talk=\(pushToTalkShortcut ?? "unbound"), rewrite-with-voice=\(rewriteWithVoiceShortcut ?? "unbound"), rewrite=\(rewriteShortcut ?? "unbound"), paste-last=\(pasteLastShortcut ?? "unbound"), cleanup=\(cleanupEnabled ? "on" : "off"), ai-provider=\(provider), model=\(modelDownloaded ? "ready" : "not downloaded"), retention=\(retention), launch-at-login=\(launchAtLogin ? "yes" : "no"), vocabulary=\(vocabularyEntryCount) entries"
    }
}
