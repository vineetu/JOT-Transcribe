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
/// The gate is a firm product decision, not a pure measurement TODO: Nemotron
/// is offered on chips that clear an **M2 Pro-class throughput bar** — any
/// Pro/Max/Ultra from M2 on, plus base chips from M4 on (base silicon crossed
/// that bar at gen 4) — **AND** RAM ≥ 16 GB. All M1 (incl. Pro/Max/Ultra),
/// base M2/M3, and anything < 16 GB are walled out and fall back to their
/// per-language default. A future on-device RTF probe (v2) would only ever
/// *widen* eligibility (chiefly to base M2/M3); it never narrows what this
/// gate ships. See `nemotronEligible` below.
///
/// Resolve membership at recording start, never mid-session, to avoid a
/// visible model swap (jot-mobile invariant).
public enum HardwareTier {

    // MARK: - Nemotron gate (the one answer this type exists to give)

    /// Whether Nemotron may be offered/auto-selected on this machine.
    ///
    /// Both halves are required:
    ///  * **chip clears the M2 Pro-class bar** — any Pro/Max/Ultra from M2 on,
    ///    or a base chip from M4 on (`chipClearsNemotronTier`), guarded by
    ///    `isAppleSilicon`.
    ///  * **RAM ≥ 16 GB** — the same class threshold once used to gate the
    ///    (since-removed) Sortformer diarization pipeline.
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
    /// The chip bar is identical (via `chipClearsNemotronTier`); only the
    /// memory floor differs. A 16–24 GB English user can still *manually*
    /// pick Nemotron (they clear `nemotronEligible`); they just won't be
    /// auto-swapped.
    public static var autoUpgradeToNemotronEligible: Bool {
        isAppleSilicon && hasTwentyFourGBOrMore && chipClearsNemotronTier(chipBrandString)
    }

    /// Whether this Mac is allowed to run the **Nemotron 3.5 Multilingual**
    /// model — a *capability* gate, deliberately distinct from
    /// `autoUpgradeToNemotronEligible` (an auto-*swap policy* gate) even though
    /// they resolve differently (capability ≥ 16 GB measured; auto-swap ≥ 24 GB
    /// politeness). They mean different things:
    /// this answers "can the hardware run the multilingual model?", the
    /// other answers "should we silently swap an unsuspecting English user?".
    /// Routing/migration/picker code MUST consult this one — not the auto-swap
    /// gate — so a future change to auto-swap headroom never silently moves the
    /// capability wall.
    ///
    /// The floor is **16 GB, measured** (2026-07-14, tools/nemotron-memprobe on
    /// M2 Pro/32 GB): the full multilingual ship streams at **33× realtime**
    /// with a working footprint in the ~1.2–1.5 GB class — the same class as
    /// nemotron_en, which the wizard already places on 16 GB Macs. The original
    /// 24 GB bar was an unmeasured launch guess inherited from the auto-swap
    /// gate; capability and swap-politeness now diverge exactly as this
    /// comment always promised they could (auto-swap stays ≥ 24 GB above —
    /// nobody gets an unsolicited 600 MB download on a small machine; they
    /// just may now *choose* these languages).
    public static var nemotronMultilingualEligible: Bool {
        isAppleSilicon && hasSixteenGBOrMore && chipClearsNemotronTier(chipBrandString)
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
    /// the same 16 GB class threshold once used to gate the (since-removed)
    /// Sortformer diarization pipeline — same threshold, different concern.
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

    /// Chip half of the Nemotron gate: does this chip clear an **M2 Pro-class
    /// ANE/CPU throughput bar**?
    ///
    ///  * **Pro/Max/Ultra** clear from generation 2 on — the original M2 Pro
    ///    floor, unchanged.
    ///  * **Base** chips clear from generation 4 on. Base silicon crossed the
    ///    M2-Pro-class bar at gen 4 (a base M4 out-throughputs the M2 Pro that
    ///    already passes), so the earlier "no Pro/Max suffix ⇒ excluded" call is
    ///    now wrong for M4+ — it walled out real users (e.g. the base-M5
    ///    MacBook Air owner who reported the miss). Base M2/M3 keep failing:
    ///    that's a measured-caution call, deliberately left in place here.
    ///
    /// Keyed off the chip-name string rather than a board-ID lookup table (the
    /// device-ID table jot-mobile explicitly rejected). The generation is parsed
    /// as a full integer after the "M" (see `appleSiliconGeneration`), so a
    /// future "M12" reads as 12 — not as a substring hit on "M1".
    ///
    /// Any M1 string (generation 1) fails both arms, so all M1 (base *and*
    /// Pro/Max/Ultra) stay excluded.
    public static func chipClearsNemotronTier(_ brand: String?) -> Bool {
        guard let brand, let generation = appleSiliconGeneration(from: brand) else { return false }
        let hasProTier = brand.contains("Pro") || brand.contains("Max") || brand.contains("Ultra")
        return hasProTier ? generation >= 2 : generation >= 4
    }

    /// The Apple-silicon generation number in a CPU brand string — the run of
    /// digits immediately after the "M" in `"Apple M<N>"` (`"Apple M4"` → 4,
    /// `"Apple M2 Pro"` → 2, a hypothetical `"Apple M12"` → 12). `nil` for any
    /// string without the `"Apple M<digits>"` shape (Intel, empty, Rosetta-
    /// mangled). Parses the whole digit run instead of `contains("M2")`-style
    /// substring checks so "M12" never collides with "M1".
    static func appleSiliconGeneration(from brand: String) -> Int? {
        guard let range = brand.range(of: "Apple M") else { return nil }
        let digits = brand[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
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
