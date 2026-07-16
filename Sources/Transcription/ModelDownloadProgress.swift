import Foundation

/// Rich progress for the model-download UI. FluidAudio only hands us a bare
/// `fractionCompleted` Double, so this type derives bytes / speed / ETA from
/// that fraction plus `ParakeetModelID.approxBytes` (the listing total isn't
/// exposed to us), and names the post-download `preparing` phase (CoreML
/// compile / `ensureLoaded`) so 100% doesn't dead-air into a hang. Surfaces
/// render the ready-made `metaLine` ("214 MB of 640 MB · 8 MB/s · about 1 min
/// left") so copy stays identical across the banner, Settings, and the wizard.
public struct ModelDownloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Bytes are transferring — determinate bar + ETA.
        case downloading
        /// Bytes landed; CoreML is compiling / the model is loading. Shape stays
        /// a bar (indeterminate LINEAR pulse) — never a circular spinner.
        case preparing
    }

    public var fraction: Double        // 0…1, expected monotonic
    public var bytesReceived: Int64
    public var bytesTotal: Int64
    public var bytesPerSecond: Double  // 0 until the meter has two samples
    public var phase: Phase

    public init(
        fraction: Double,
        bytesReceived: Int64,
        bytesTotal: Int64,
        bytesPerSecond: Double,
        phase: Phase
    ) {
        self.fraction = fraction
        self.bytesReceived = bytesReceived
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.phase = phase
    }

    /// The "preparing" sentinel — indeterminate, no ETA.
    public static func preparing(bytesTotal: Int64) -> ModelDownloadProgress {
        ModelDownloadProgress(
            fraction: 1.0, bytesReceived: bytesTotal, bytesTotal: bytesTotal,
            bytesPerSecond: 0, phase: .preparing)
    }

    /// Seconds remaining, or nil when unknowable (still ramping up, or preparing).
    public var eta: TimeInterval? {
        guard phase == .downloading, bytesPerSecond > 0, bytesTotal > bytesReceived else { return nil }
        return Double(bytesTotal - bytesReceived) / bytesPerSecond
    }

    // MARK: - Ready-made display strings (keep copy identical across surfaces)

    /// "214 MB of 640 MB"
    public var byteProgressText: String {
        "\(Self.mb(bytesReceived)) of \(Self.mb(bytesTotal))"
    }

    /// "8 MB/s", or nil before the meter has a rate.
    public var speedText: String? {
        guard phase == .downloading, bytesPerSecond > 0 else { return nil }
        return "\(Self.mb(Int64(bytesPerSecond)))/s"
    }

    /// "about 1 min left" / "about 30 sec left" / "less than a minute" — never
    /// raw seconds above 90.
    public var etaText: String? {
        guard let eta, eta.isFinite, eta > 0 else { return nil }
        if eta < 10 { return "a few seconds left" }
        if eta < 90 { return "about \(Int((eta / 5).rounded()) * 5) sec left" }
        let mins = Int((eta / 60).rounded())
        return mins <= 1 ? "less than a minute" : "about \(mins) min left"
    }

    /// The full trailing meta line, e.g. "214 MB of 640 MB · 8 MB/s · about 1 min left".
    public var metaLine: String {
        [byteProgressText, speedText, etaText].compactMap { $0 }.joined(separator: " · ")
    }

    private static func mb(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / 1_000_000.0
        // Whole MB reads cleaner than decimals at this scale.
        return "\(Int(mb.rounded())) MB"
    }
}

/// Turns FluidAudio's monotonic `fractionCompleted` stream into
/// `ModelDownloadProgress` with an EMA-smoothed byte rate. Drive it from a
/// SINGLE context (e.g. the MainActor download callback) — it is not internally
/// synchronized. `record(fraction:)` returns the progress to publish.
///
/// `@unchecked Sendable`: the type has mutable state and no locking, so this is
/// a promise the CALLER only ever touches it from one context. Both call sites
/// honor that — `TranscriberHolder` reads its meter on the MainActor, and the
/// wizard calls `record` inside a `@MainActor` hop — so a `SpeedMeter` is only
/// ever mutated on the MainActor. The annotation exists solely so it can be
/// captured by FluidAudio's `@Sendable` progress closure.
public final class SpeedMeter: @unchecked Sendable {
    private let bytesTotal: Int64
    private var lastFraction: Double = 0
    private var lastTime: Date?
    private var emaBytesPerSecond: Double = 0
    /// Smoothing factor — higher tracks faster, lower is steadier. 0.3 keeps the
    /// number from jittering while still reacting to a stall within a couple s.
    private let alpha: Double

    public init(bytesTotal: Int64, alpha: Double = 0.3) {
        self.bytesTotal = max(1, bytesTotal)
        self.alpha = alpha
    }

    /// Feed the latest fraction; get back progress to publish. Clamps to [0,1]
    /// and never lets the rate go negative (a fraction that dips is treated as 0
    /// delta so the ETA doesn't blow up).
    public func record(fraction: Double, now: Date = Date()) -> ModelDownloadProgress {
        let f = min(1, max(0, fraction))
        let received = Int64(Double(bytesTotal) * f)
        if let last = lastTime {
            let dt = now.timeIntervalSince(last)
            let dBytes = Double(bytesTotal) * max(0, f - lastFraction)
            if dt > 0.05 {
                let inst = dBytes / dt
                emaBytesPerSecond = emaBytesPerSecond == 0 ? inst : (alpha * inst + (1 - alpha) * emaBytesPerSecond)
                lastTime = now
                lastFraction = f
            }
        } else {
            lastTime = now
            lastFraction = f
        }
        return ModelDownloadProgress(
            fraction: f,
            bytesReceived: received,
            bytesTotal: bytesTotal,
            bytesPerSecond: emaBytesPerSecond,
            phase: .downloading)
    }
}
