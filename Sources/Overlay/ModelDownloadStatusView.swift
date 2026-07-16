import SwiftUI

/// Shared model-download status surface (design: `docs/plans/model-download-ux-
/// mockup.html`). ONE component renders every download/repair state across the
/// main-window banner, the Settings → General model row, and the Setup Wizard
/// language step — so the copy, glyph vocabulary, and progress treatment stay
/// identical everywhere.
///
/// **Owner refinement honored:** download progress renders ONLY here (banner /
/// Settings / wizard) — never in the status pill. The pill's repair/download
/// rendering was removed.
///
/// **Core UI principle (HIG):** exactly ONE horizontal bar. A *determinate*
/// `.linear` bar while bytes transfer; an *indeterminate* `.linear` pulse for
/// the pre-first-byte and "Preparing" phases. There is deliberately NO circular
/// `ProgressView()` anywhere — a spinner stacked on top of a bar (the old bug)
/// is not a state this view can represent.
///
/// The view is intentionally decoupled from `TranscriberHolder`: each surface
/// maps its own producer (`pendingSwitch` / `repairState`) into `State`, so a
/// future change to either producer only touches the (small) mapping helper at
/// the call site, not this file.
struct ModelDownloadStatusView: View {
    enum State: Equatable {
        /// Bytes transferring — `arrow.down.circle`, DETERMINATE `.linear` bar at
        /// `fraction`. `meta` is the ready-made `ModelDownloadProgress.metaLine`
        /// ("214 MB of 640 MB · 8 MB/s · about 1 min left"); pass "" to hide it.
        /// `subtext` is the "Keep dictating in <lang>…" reassurance line.
        case downloading(title: String, meta: String, fraction: Double, subtext: String?)
        /// Indeterminate `.linear` pulse. `symbol` distinguishes the pre-first-byte
        /// ramp (`.downloading` → `arrow.down.circle`) from the post-100% CoreML
        /// compile (`.preparing` → `gearshape`).
        case working(title: String, symbol: WorkingSymbol, subtext: String?)
        /// A retriable failure that Jot is auto-retrying — `exclamationmark.
        /// triangle` (yellow: a wait, not a red failure). `message` is the taxonomy
        /// `errorDescription`. A non-nil `nextRetryAt` drives a live "Retrying in
        /// Ns…" countdown next to a "Retry now" button.
        case retrying(message: String, nextRetryAt: Date?, subtext: String?)
        /// A terminal failure the user must act on (offline / disk full) —
        /// `exclamationmark.triangle` (yellow) + the taxonomy `errorDescription`
        /// and a "Retry" button.
        case failed(message: String)

        enum WorkingSymbol: Equatable { case downloading, preparing }
    }

    /// Chrome around the content. `.banner` is the full-width, material-backed
    /// strip used in `JotAppWindow`'s top safe-area inset; `.inline` drops the
    /// background so the component sits cleanly inside a Settings `Form` row or
    /// the wizard's `VStack`.
    enum Style: Equatable { case banner, inline }

    let state: State
    var style: Style = .banner
    /// Wired to `retryPendingSwitch()` / `runManualRepair(_:)` / the wizard's
    /// `startDownload()` for the `.retrying` and `.failed` states.
    var onRetry: (() -> Void)? = nil
    /// Wired to `cancelPendingSwitch()`. Rendered as the trailing ✕ only while
    /// downloading / working.
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph
            VStack(alignment: .leading, spacing: 6) {
                header
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    // MARK: - Glyph

    private var glyph: some View {
        Group {
            switch style {
            case .banner:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(glyphTint.opacity(0.14))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(glyphTint)
                    )
            case .inline:
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(glyphTint)
                    .frame(width: 16)
            }
        }
        // Keep the glyph optically aligned with the first line of text.
        .padding(.top, style == .banner ? 0 : 1)
    }

    private var symbolName: String {
        switch state {
        case .downloading:
            return "arrow.down.circle"
        case .working(_, let symbol, _):
            return symbol == .preparing ? "gearshape" : "arrow.down.circle"
        case .retrying, .failed:
            return "exclamationmark.triangle"
        }
    }

    private var glyphTint: Color {
        switch state {
        case .downloading, .working:
            return .blue
        case .retrying, .failed:
            // Yellow, not red: a wait / recoverable condition, never an alarm.
            return .yellow
        }
    }

    // MARK: - Header (title row + cancel)

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(titleText)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showsCancel, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
                .accessibilityLabel("Cancel download")
            }
        }
    }

    private var titleText: String {
        switch state {
        case .downloading(let title, _, _, _): return title
        case .working(let title, _, _): return title
        case .retrying(let message, _, _): return message
        case .failed(let message): return message
        }
    }

    private var titleSize: CGFloat { style == .banner ? 14 : 12 }

    private var showsCancel: Bool {
        switch state {
        case .downloading, .working: return true
        case .retrying, .failed: return false
        }
    }

    // MARK: - Detail (meta, bar, subtext, actions)

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .downloading(_, let meta, let fraction, let subtext):
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(.blue)
            subtextView(subtext)

        case .working(_, _, let subtext):
            // Indeterminate LINEAR pulse — never a circular spinner.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.blue)
            subtextView(subtext)

        case .retrying(_, let nextRetryAt, let subtext):
            subtextView(subtext)
            HStack(spacing: 10) {
                if let nextRetryAt {
                    RetryCountdown(nextRetryAt: nextRetryAt)
                }
                if onRetry != nil {
                    Button("Retry now") { onRetry?() }
                        .controlSize(.small)
                }
            }

        case .failed:
            if onRetry != nil {
                Button("Retry") { onRetry?() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func subtextView(_ subtext: String?) -> some View {
        if let subtext, !subtext.isEmpty {
            Text(subtext)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chrome

    private var padding: EdgeInsets {
        switch style {
        case .banner: return EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        case .inline: return EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .banner: Rectangle().fill(.regularMaterial)
        case .inline: Color.clear
        }
    }
}

/// Live "Retrying in Ns…" countdown for the `.retrying` state. `TimelineView`
/// re-renders once a second off the system clock without an owned `Timer`, so it
/// tears down cleanly with the view. Reads reassuring, not alarming.
private struct RetryCountdown: View {
    let nextRetryAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(nextRetryAt.timeIntervalSince(context.date).rounded(.up)))
            Text(remaining > 0 ? "Retrying in \(remaining)s…" : "Retrying…")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
