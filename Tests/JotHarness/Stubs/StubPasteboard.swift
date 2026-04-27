import AppKit
import Foundation
@testable import Jot

/// Harness conformer for `Pasteboarding`. Keeps an in-memory
/// pasteboard backed by a private `NSPasteboard.withUniqueName()` so
/// the developer's real clipboard is never touched.
///
/// **`history: [PasteEvent]`** is the test-visible record of every
/// `write(_:)` call, ordered. Flow methods aggregate this into
/// `DictationResult.pasteboardHistory` so I2-style tests can assert
/// "the transcript was written exactly once".
///
/// `@MainActor` because the protocol is `@MainActor`-isolated and
/// `NSPasteboard` operations are MainActor-bound.
@MainActor
final class StubPasteboard: Pasteboarding {
    private let pasteboard: NSPasteboard
    private(set) var history: [PasteEvent] = []

    /// Test-only: when non-nil, the next `postCommandC()` call writes
    /// this text to the pasteboard (bumping `changeCount` naturally
    /// via `NSPasteboard.clearContents()`). Models the user having a
    /// selection in the foreground app at the moment the controller
    /// posts a synthetic ⌘C. Cleared after one `postCommandC()` so a
    /// second copy attempt in the same flow exercises the
    /// "no selection" branch.
    var simulatedExternalSelection: String?

    init() {
        // `withUniqueName()` mints a private named pasteboard so two
        // concurrent stubs in the same process don't collide and so
        // the developer's `general` clipboard is unaffected.
        self.pasteboard = NSPasteboard.withUniqueName()
    }

    deinit {
        // `withUniqueName()` allocates a private pasteboard that
        // sticks around for the process lifetime; calling
        // `releaseGlobally()` lets the test runner reclaim it
        // between iterations.
        pasteboard.releaseGlobally()
    }

    // MARK: - Pasteboarding

    func snapshot() -> PasteboardSnapshot {
        ClipboardSandwich.snapshot(pasteboard: pasteboard)
    }

    @discardableResult
    func write(_ string: String) -> Bool {
        let success = ClipboardSandwich.writeString(string, pasteboard: pasteboard)
        if success {
            history.append(PasteEvent(text: string, timestamp: Date()))
        }
        return success
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        ClipboardSandwich.restore(snapshot, pasteboard: pasteboard)
    }

    var changeCount: Int { pasteboard.changeCount }

    func readString() -> String? { pasteboard.string(forType: .string) }

    // MARK: - Synthetic key events (Pasteboarding seam)

    /// Synthetic ⌘C. If `simulatedExternalSelection` is non-nil, write
    /// it to the pasteboard via `clearContents() + setString(...)` —
    /// this bumps `changeCount` exactly the way a real foreground-app
    /// copy would, satisfying `ArticulateController.captureSelection`'s
    /// guard. **Bypasses `history`** — synthetic copies are not
    /// `write(_:)` calls; tests assert on rewrites, not selection
    /// captures.
    ///
    /// Cleared after one call so a second `postCommandC()` in the
    /// same harness instance exercises the "no selection" branch
    /// (returns without bumping changeCount → controller throws
    /// `ArticulateError(message: "No text was copied. ...")`).
    func postCommandC() throws {
        guard let text = simulatedExternalSelection else { return }
        simulatedExternalSelection = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Synthetic ⌘V. No-op on the stub — what matters for assertions
    /// is the preceding `write(_:)` call (which lands in `history`
    /// and reflects on `readString()`). The live conformer would post
    /// a CGEvent here that the foreground app consumes as a paste; on
    /// the stub there is no foreground app to paste into.
    func postCommandV() throws {
        // Intentionally empty.
    }

    /// Synthetic Return. No-op on the stub.
    func postReturn() throws {
        // Intentionally empty.
    }
}
