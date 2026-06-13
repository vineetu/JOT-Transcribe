import XCTest
@testable import Jot

/// Unit tests for the Nemotron chip-tier gate. `chipClearsNemotronTier` is a
/// pure function over the `machdep.cpu.brand_string` value, so the whole
/// product decision (≥ M2 Pro) is deterministically testable without real
/// hardware. Per `docs/hardware-capability-matrix/design.md`.
final class HardwareTierTests: XCTestCase {

    // MARK: - Eligible: M2 Pro and newer Pro/Max/Ultra tiers

    func testM2ProEligible() {
        XCTAssertTrue(HardwareTier.chipClearsNemotronTier("Apple M2 Pro"))
    }

    func testM2MaxEligible() {
        XCTAssertTrue(HardwareTier.chipClearsNemotronTier("Apple M2 Max"))
    }

    func testM2UltraEligible() {
        XCTAssertTrue(HardwareTier.chipClearsNemotronTier("Apple M2 Ultra"))
    }

    func testM3MaxEligible() {
        XCTAssertTrue(HardwareTier.chipClearsNemotronTier("Apple M3 Max"))
    }

    func testM4ProEligible() {
        XCTAssertTrue(HardwareTier.chipClearsNemotronTier("Apple M4 Pro"))
    }

    // MARK: - Excluded: all M1 (the firm product decision), any tier

    func testM1BaseExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M1"))
    }

    func testM1ProExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M1 Pro"))
    }

    func testM1MaxExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M1 Max"))
    }

    func testM1UltraExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M1 Ultra"))
    }

    // MARK: - Excluded: base tiers (no Pro/Max/Ultra suffix) — known v1 edge

    func testM2BaseExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M2"))
    }

    func testM3BaseExcludedV1Edge() {
        // Base M3 may match M2 Pro perf but has no suffix → excluded in v1
        // (the deferred RTF probe is what would admit it).
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M3"))
    }

    func testM4BaseExcludedV1Edge() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier("Apple M4"))
    }

    // MARK: - Excluded: non-Apple-Silicon / malformed

    func testIntelExcluded() {
        XCTAssertFalse(
            HardwareTier.chipClearsNemotronTier("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz")
        )
    }

    func testNilExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier(nil))
    }

    func testEmptyExcluded() {
        XCTAssertFalse(HardwareTier.chipClearsNemotronTier(""))
    }
}
