import Foundation

/// Apple Silicon capability detection for transcription model auto-selection.
///
/// Per `docs/hardware-capability-matrix/design.md`: the ONLY hardware-gated
/// model is **Nemotron** (the heaviest model to *run* — its int8 encoder is
/// compute/ANE-heavy and must keep up with mic audio in real time). Every
/// other model (Parakeet v2 / v3 / JA batch + the `PreviewScheduler` live
/// preview) runs on every Apple Silicon Mac, so there is no dictation floor
/// to gate — `HardwareTier` exists purely to answer "may this Mac run
/// Nemotron?".
///
/// The gate is a firm product decision, not a measurement TODO: Nemotron is
/// offered ONLY on chip tier ≥ M2 Pro **AND** RAM ≥ 16 GB. All M1 (incl.
/// Pro/Max/Ultra), all base M2/M3/M4, and anything < 16 GB are walled out and
/// fall back to their per-language default. A future on-device RTF probe (v2)
/// would only ever *widen* eligibility (chiefly to base M3/M4); it never
/// narrows what this gate ships. See `nemotronEligible` below.
///
/// Resolve membership at recording start, never mid-session, to avoid a
/// visible model swap (jot-mobile invariant).
public enum HardwareTier {

    // MARK: - Nemotron gate (the one answer this type exists to give)

    /// Whether Nemotron may be offered/auto-selected on this machine.
    ///
    /// Both halves are required:
    ///  * **chip tier ≥ M2 Pro** — a Pro/Max/Ultra suffix on an M2-or-newer
    ///    chip (`chipClearsNemotronTier`), guarded by `isAppleSilicon`.
    ///  * **RAM ≥ 16 GB** — matching the existing `SortformerHardwareGate`
    ///    precedent (`SortformerHolder.swift`).
    ///
    /// Computed on demand from constant-per-boot sysctls; cheap enough to read
    /// at recording start without caching.
    public static var nemotronEligible: Bool {
        isAppleSilicon && hasSixteenGBOrMore && chipClearsNemotronTier(chipBrandString)
    }

    /// Whether an *existing English user* should be silently auto-upgraded to
    /// Nemotron at launch (the one-shot `NemotronAutoUpgradeMigration`).
    ///
    /// This is deliberately a **higher RAM bar than `nemotronEligible`**:
    ///  * `nemotronEligible` (the run/offer floor) requires **≥ 16 GB** — the
    ///    threshold at which Nemotron is allowed to run at all.
    ///  * `autoUpgradeToNemotronEligible` (the auto-*swap* gate) requires
    ///    **≥ 24 GB** — we only push the heavier model onto users with comfortable
    ///    headroom, since the swap is unsolicited (the user never asked for it).
    ///
    /// The chip bar is identical (≥ M2 Pro via `chipClearsNemotronTier`); only
    /// the memory floor differs. A 16–24 GB English user can still *manually*
    /// pick Nemotron (they clear `nemotronEligible`); they just won't be
    /// auto-swapped.
    public static var autoUpgradeToNemotronEligible: Bool {
        isAppleSilicon && hasTwentyFourGBOrMore && chipClearsNemotronTier(chipBrandString)
    }

    // MARK: - Raw detected facts (also useful for diagnostics / logging)

    /// `machdep.cpu.brand_string`, e.g. `"Apple M2 Pro"`. Constant per boot, so
    /// read once and memoized. `nil` if the sysctl is unavailable.
    public static let chipBrandString: String? = sysctlString("machdep.cpu.brand_string")

    /// Physical RAM in bytes. Reports ~nominal on Mac (no large iOS-style
    /// kernel carve-out), so a 16 GiB check is safe.
    public static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// True on a native arm64 build running on Apple Silicon. Used as a sanity
    /// guard before trusting the chip-name string (it can misreport under
    /// Rosetta translation).
    public static var isAppleSilicon: Bool {
        sysctlInt("hw.optional.arm64") == 1
    }

    // MARK: - Gate halves

    /// RAM half of the Nemotron gate: ≥ 16 GiB. Mirrors
    /// `SortformerHardwareGate.isSupported` deliberately (same 16 GB class
    /// threshold, different concern).
    public static var hasSixteenGBOrMore: Bool {
        physicalMemoryBytes >= UInt64(16) * 1_073_741_824
    }

    /// RAM bar for the *auto-upgrade* swap (distinct from the 16 GB run floor
    /// above): ≥ 24 GiB. We only auto-swap existing English users to the heavier
    /// Nemotron model when they have comfortable headroom, since the swap is
    /// unsolicited. See `autoUpgradeToNemotronEligible`.
    public static var hasTwentyFourGBOrMore: Bool {
        physicalMemoryBytes >= UInt64(24) * 1_073_741_824
    }

    /// Chip half of the Nemotron gate: a Pro/Max/Ultra tier on an M2-or-newer
    /// generation (i.e. ≥ M2 Pro).
    ///
    /// Keyed off the chip-name suffix rather than a board-ID lookup table
    /// (the device-ID table jot-mobile explicitly rejected). Known v1 edge:
    /// **base M3/M4 carry no Pro/Max suffix and are therefore excluded here**,
    /// even though they may match/exceed M2 Pro — the deliberate conservative
    /// call (never ship a model that can't keep up). The deferred v2 RTF probe
    /// is what would later admit them.
    ///
    /// Any M1 string fails the generation check, so all M1 (base *and*
    /// Pro/Max/Ultra) are excluded without needing the unverified bare
    /// `"Apple M1"` form.
    public static func chipClearsNemotronTier(_ brand: String?) -> Bool {
        guard let brand, brand.contains("Apple M") else { return false }
        let hasProTier = brand.contains("Pro") || brand.contains("Max") || brand.contains("Ultra")
        // Extend this list as new generations ship.
        let gen2Plus = brand.contains("M2") || brand.contains("M3")
            || brand.contains("M4") || brand.contains("M5")
        return hasProTier && gen2Plus
    }

    // MARK: - sysctl helpers

    /// Reads a string-valued sysctl by name (e.g. `machdep.cpu.brand_string`).
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads an integer-valued sysctl by name (e.g. `hw.optional.arm64`).
    static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
