import Foundation

/// Compile-time feature gates. The flag controls UI visibility AND the
/// runtime entry points that warm/run the feature's pipeline — flipping
/// to `false` makes the feature invisible to users and prevents any
/// background work (downloads, model loads, post-stop passes) from
/// firing, while the underlying code stays compiled and reachable.
///
/// Flip to `true` to re-enable a gated feature without touching the
/// surrounding implementation.
enum Features {
    /// Speaker diarization — NVIDIA Nemotron 3 Diarization
    /// (`Nemotron3Diarizer`, fast128, via `DiarizerHolder`) driving the
    /// "Detect speakers" action in the recording detail view, with
    /// anonymous "Speaker N" labels the user renames per recording
    /// (`docs/speaker-diarization/design.md`). Replaces the earlier
    /// Sortformer-based "Speaker Labels piece A" (ripped out — wrong engine,
    /// heavy enrollment UX). Gates: the Settings → Speaker labels sidebar
    /// entry, the "Detect speakers" toolbar button + labeled transcript
    /// rendering in `RecordingDetailView`, and the label-preservation prompt
    /// rule in Cleanup / Rewrite (`SpeakerLabelDetector.looksLabeled`, which
    /// is engine-agnostic and runs regardless — this flag only controls
    /// whether a labeled timeline can ever be produced in the first place).
    static let speakerLabels: Bool = true
}
