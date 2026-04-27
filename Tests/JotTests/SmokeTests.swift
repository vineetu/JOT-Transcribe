import Testing
@testable import Jot

/// Phase 1.1 smoke test — proves the `JotTests` target compiles, the
/// Swift Testing runtime is wired up, the test bundle loads against the
/// `Jot.app` test host, and `@testable import Jot` resolves so Phase 1.4+
/// flow tests will see internal types (`JotComposition`, `AppServices`,
/// the eight protocol seams).
///
/// Phase 1.4-1.7 fill this target with the four `JotHarness` flow tests
/// (`dictate`, `articulateCustom`, `askJotVoice`, `runWizard`). Until
/// then this single test is the only thing exercising the bundle.
struct SmokeTests {
    @Test func smokeTrivial() {
        #expect(1 + 1 == 2)
    }
}
