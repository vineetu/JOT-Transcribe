# Jot
On-device Mac dictation. Hotkey, speak, transcript pastes at cursor. Local default; cloud optional for Cleanup, Articulate.
Jot cannot transcribe pre-recorded audio files — live mic input only.

Keyboard modifier glossary: ⌥=Option, ⌘=Command, ⌃=Control, ⇧=Shift.

## Dictation
toggle-recording: press hotkey (default ⌥Space, Option+Space) start; press again stop+transcribe.
push-to-talk: hold hotkey record, release stop. Unbound default.
cancel-recording: Esc discards. Active only while recording, never steals Esc when idle.
any-length: no hard limit. Quality diminishes past ~1 hr; shorter sessions best.
on-device-transcription: Parakeet on Apple Neural Engine. Audio stays on Mac. Model downloads first use.
multilingual: 25 European langs, auto-detected per recording.
languages: Jot supports these ASR models — pick one as primary at Settings → Transcription. Only the primary is hot in memory; switching unloads + reloads.
<!-- FRAGMENT: jot-asr-languages -->
japanese: yes — install the Parakeet 0.6B Japanese model from Settings → Transcription, then make it primary. v3 does NOT transcribe Japanese; the JA model is required.
custom-vocabulary: short list of names, acronyms, jargon Jot prefers. Biases recognizer — best-effort, not guarantee. Too many similar entries cause unpredictable preference. Edit at Settings → Vocabulary. Not applied to Japanese transcription (different tokenizer).

## Cleanup (optional, off default)
LLM polishes transcript. Four passes: filler removal, grammar, number normalization, structure. Voice, word choice, register preserved — not style rewrite.
cleanup-providers: Apple Intelligence on-device, private, free — recommended for privacy. OpenAI, Anthropic, Gemini use user API key.
cleanup-prompt: default prompt in Settings → AI → Customize prompt. Reset-to-default available.
Fallback: raw transcript delivered on LLM fail or 10s timeout. Raw+cleaned saved on success.

## Articulate (optional)
Rewrite selected text via global shortcut. Two variants, same pipeline.
articulate-custom: select text, hotkey (default ⌥,, Option+Comma), speak instruction ("make formal", "translate Japanese", "bulleted list"), result replaces selection.
articulate-fixed: select text, hotkey (unbound default), fixed "Articulate this" rewrite. No voice step.
Invariants every run: selection is text not instruction, return only rewrite, don't refuse on quality. Edit at Settings → AI → Customize prompt.
articulate-intent-classifier: routes instruction into four branches — voice-preserving, structural, translation, code. User instruction wins; branch picks default shape.
Both use configured AI provider (same as Cleanup).

## Shortcuts
modifier-required: macOS requires modifier (⌘ ⌥ ⌃ ⇧) on global hotkeys. Single-key bindings impossible.
hotkey-stopped-working: hotkey produces Unicode char (≤, ÷) when another app grabbed it while Jot was off. Re-register in Settings → Shortcuts.
Defaults: toggle-recording ⌥Space (Option+Space); push-to-talk unbound; articulate-custom ⌥, (Option+Comma); articulate-fixed unbound; paste-last ⌥⇧V (Option+Shift+V).
shortcuts: bindings in Settings → Shortcuts. Cancel (Esc) hardcoded.

## Paste & Clipboard
auto-paste: transcript pastes at cursor.
auto-enter: press Return after paste. Chat inputs.
clipboard-preservation: original clipboard restored after paste.
copy-last: ⌥⇧V (Option+Shift+V) re-pastes most recent transcript.

## Retention
Recordings+transcripts kept on-device, configurable. Options: 7, 30, 90 days, forever. Enforced on launch, hourly. Settings → General → Keep recordings.

## Troubleshooting
permissions: Mic, Input Monitoring, Accessibility.
bluetooth-redirect: actionable error on Bluetooth mic drop.
recording-wont-start: fix on card.
hotkey-stopped-working: re-register steps on card.
ai-unavailable: enable Apple Intelligence or switch to cloud/Ollama.
ai-connection-failed: check API key, network.
articulate-bad-results: reset prompt to default first.

## Privacy
Local-only default. Audio, transcripts, settings stay on Mac. No telemetry. Cloud providers receive text only when user enables Cleanup or Articulate w/ cloud. Only automatic network: one-time model download, daily update check.
