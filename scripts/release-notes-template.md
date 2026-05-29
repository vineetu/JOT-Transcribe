# Jot v1.13.1

> A focused polish pass: a cleaner Recents pane, a less noisy Settings sidebar, a more useful overlay pill, and a recording-safety contract that means Esc never throws your transcript away.

## What's new

- **Recents redesigned.** The "New to Jot? See Basics" banner is gone. A small "Dictate" pill sits at the top of the pane — click it to start a recording, click again to stop without pasting (the transcript still saves to Recents). Search moved inline above the list. Today / Yesterday / Earlier dividers are gone in favor of a flat chronological list; each row now shows `duration · date`.
- **Esc no longer discards your recording.** Press Esc while recording → it stops, transcribes, and saves to Recents — the **paste** step is skipped, but the transcript is kept. Same contract for clicking the in-app "Dictate" pill while recording. The transcript only gets pasted at your cursor when you stop via the bound hotkey.
- **Overlay pill shows the stop shortcut.** A small `Press <YourShortcut> to stop` hint sits under the pill while recording, reading the actual key you have bound.
- **Saved-to-Recents click pill.** When Esc or the in-app Dictate button stops a recording without pasting, the overlay pill briefly becomes clickable — tap it and Jot opens to the exact transcript in Recents.
- **Settings sidebar tidied.** Clicking the Settings row now toggles the disclosure (no more auto-navigating to General). The reorder is General · Shortcuts · Transcription · AI · Prompts — Sound is gone from the sidebar entirely. The few sound knobs that matter (master volume) carry sensible defaults.
- **Transcription pane simplified.** Only your current model is shown; the rest live behind "Show other models." Automatically paste, Press Return after pasting, and Keep last transcript on clipboard are gated by the global "Show advanced features" toggle in General — no per-pane disclosures.
- **Setup Wizard polish.** The Welcome step reads your actual bound shortcut (not hardcoded "⌥Space"). The "On-device dictation" sub-line now says "Uses negligible battery" instead of mentioning the Apple Neural Engine. The Permissions step's Input Monitoring row also reads the live shortcut. Footer-button layout flips on the "You're set up" step so Skip is the prominent action (most people are done; Continue is the power-user path into the advanced tour).
- **Shortcuts pane info popovers describe the feature, not the binding mechanics.** The "chord vs single-key" mechanics explanation lives only at the top of the pane. Per-row subtitles are gone — the info dot is where the feature description lives.

## Fixes

- **Deterministic post-processing scoped to Parakeet v2.** Modern Parakeet (v3, v3+Nemotron, v3+EOU, Nemotron-only) emits clean, well-cased transcripts natively — running the legacy regex pass on top added no value and was occasionally regressing model output. v3+ is now pure pass-through; v2 keeps its regex chain because it needs it.

## Install

Sparkle will offer the update automatically. If you'd rather grab the DMG by hand, download `Jot.dmg` below.
