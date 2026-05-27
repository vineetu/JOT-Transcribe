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
    /// Speaker Labels piece A — Sortformer-driven diarization of
    /// multi-speaker recordings. Held off in v1.13 while UX polish and
    /// load-time hitches settle; the pipeline, downloader, enrollment
    /// UI, RecordingDetailView labeled-view, and the post-stop pass in
    /// `RecordingPersister` are all still compiled. Set to `true` to
    /// surface the Settings sidebar entry, render labeled transcripts,
    /// and re-arm the launch-time warmup / auto-redownload paths.
    static let speakerLabels: Bool = false
}
