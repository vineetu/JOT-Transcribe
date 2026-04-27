import AppKit
import Foundation

/// OS-boundary seam for the system pasteboard. The live conformer is
/// `LivePasteboard` (wraps `NSPasteboard.general` via `ClipboardSandwich`'s
/// existing snapshot/write/restore implementation); harness conformers in
/// `Tests/JotHarness/` keep an in-memory store so flow tests can verify
/// pasteboard state without affecting the developer's real clipboard.
///
/// Methods mirror the operations the live recording / articulate paths
/// already perform:
/// - `snapshot()` captures current pasteboard contents (per-type data)
///   so the clipboard-sandwich can roll back after a synthetic ⌘V.
/// - `write(_:)` clears + sets the pasteboard string. `@discardableResult
///   Bool` preserves the failure-detection path that DeliveryService and
///   ArticulateController already act on.
/// - `restore(_:)` writes a snapshot back, used by both the auto-paste
///   delay-restore and the Articulate selection-capture flow.
/// - `changeCount` exposes `NSPasteboard.changeCount` because
///   ArticulateController.captureSelection compares before/after to detect
///   whether the synthetic ⌘C actually moved data onto the pasteboard.
/// - `readString()` exposes `NSPasteboard.string(forType: .string)` for the
///   same Articulate flow.
///
/// All operations are `@MainActor`-isolated because `NSPasteboard` and the
/// existing `ClipboardSandwich` helpers are MainActor-bound, and the only
/// consumers (`DeliveryService`, `ArticulateController`) are themselves
/// `@MainActor`. `Sendable` so `any Pasteboarding` round-trips through
/// `AppServices` without warnings.
@MainActor
protocol Pasteboarding: AnyObject, Sendable {
    func snapshot() -> PasteboardSnapshot
    @discardableResult
    func write(_ string: String) -> Bool
    func restore(_ snapshot: PasteboardSnapshot)
    var changeCount: Int { get }
    func readString() -> String?

    /// Synthetic ⌘C key event. Live conformers post a real CGEvent to
    /// the foreground app's responder chain (which copies the user's
    /// selection onto the pasteboard); harness conformers simulate the
    /// resulting clipboard mutation without touching CGEvent. Phase 0.7
    /// originally seamed only the data path (snapshot/write/restore);
    /// Phase 1.5 closed the gap by adding the key-event ops too — see
    /// `ClipboardSandwich.PostError` for the failure shape.
    func postCommandC() throws

    /// Synthetic ⌘V key event. Same semantics as `postCommandC()` —
    /// the live conformer posts a CGEvent that the foreground app
    /// consumes as a paste action; harness conformers no-op because
    /// what matters for assertions is the preceding `write(_:)` call.
    func postCommandV() throws

    /// Synthetic Return key event (no modifiers). Used by
    /// `DeliveryService` when the auto-press-Enter setting is on
    /// (chat apps).
    func postReturn() throws
}

/// Top-level alias for `ClipboardSandwich.Snapshot` so the seam protocol
/// can refer to it by a Pasteboarding-flavored name. The shape is owned
/// by `ClipboardSandwich` (where the snapshot/restore implementation
/// lives); this is just a public-facing rename used at the protocol
/// boundary.
typealias PasteboardSnapshot = ClipboardSandwich.Snapshot

/// Live conformer — forwards every call to the existing
/// `ClipboardSandwich` static methods against `NSPasteboard.general`. No
/// behavior change versus pre-Phase-0.7: every operational path that
/// previously wrote to `NSPasteboard.general` still does, just routed
/// through this seam so the harness can intercept.
@MainActor
final class LivePasteboard: Pasteboarding {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func snapshot() -> PasteboardSnapshot {
        ClipboardSandwich.snapshot(pasteboard: pasteboard)
    }

    @discardableResult
    func write(_ string: String) -> Bool {
        ClipboardSandwich.writeString(string, pasteboard: pasteboard)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        ClipboardSandwich.restore(snapshot, pasteboard: pasteboard)
    }

    var changeCount: Int { pasteboard.changeCount }

    func readString() -> String? { pasteboard.string(forType: .string) }

    func postCommandC() throws {
        try ClipboardSandwich.postCommandC()
    }

    func postCommandV() throws {
        try ClipboardSandwich.postCommandV()
    }

    func postReturn() throws {
        try ClipboardSandwich.postReturn()
    }
}
