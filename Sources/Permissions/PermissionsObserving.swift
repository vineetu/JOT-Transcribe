import Combine
import Foundation

/// OS-boundary seam for the macOS permission grant matrix (Microphone,
/// Input Monitoring, Accessibility post-events, Accessibility full AX).
/// The live conformer is `PermissionsService` (kept as a singleton per
/// `cleanup-roadmap.md` Phase 3 allowlist — tier-2 platform-bound);
/// harness conformers in `Tests/JotHarness/` return canned grant maps
/// so flow tests can exercise both the granted and denied paths without
/// poking System Settings.
///
/// The shape mirrors `PermissionsService`'s existing public surface so
/// the operational call sites (`DeliveryService`, `ArticulateController`,
/// `VoiceInputPipeline`) can swap to the protocol with a one-line type
/// change.
///
/// **Capability vs. PermissionKind:** the brief said `PermissionKind` but
/// the existing codebase has used `Capability` (`Sources/Permissions/Capability.swift`)
/// since v1.4. Renaming would touch every Settings, Wizard, and Help
/// surface — out of scope for a Phase 0 seam. The seam uses `Capability`
/// to match the existing taxonomy.
///
/// `@MainActor` because every operational consumer is `@MainActor`-isolated
/// and `PermissionsService` itself is `@MainActor`. `AnyObject & Sendable`
/// lets `any PermissionsObserving` round-trip through `AppServices`
/// without warnings.
@MainActor
protocol PermissionsObserving: AnyObject, Sendable {
    /// Last-known grant map. Read by every operational consumer to gate
    /// the recording / paste / articulate flows.
    var statuses: [Capability: PermissionStatus] { get }

    /// Single-capability lookup. Convenience for `statuses[capability] ?? .notDetermined`
    /// — saves callers the optional-chaining bookkeeping.
    func status(for capability: Capability) -> PermissionStatus

    /// Re-poll every capability and update `statuses`. Cheap (synchronous
    /// kernel calls); called speculatively by every operational consumer
    /// before reading the grant matrix.
    func refreshAll()

    /// Prompt the user for a specific capability. Microphone routes through
    /// `AVCaptureDevice.requestAccess`; Input Monitoring through
    /// `IOHIDRequestAccess`; Accessibility opens System Settings.
    /// `refreshAll()` runs after the prompt resolves so observers see the
    /// new grant immediately.
    func request(_ capability: Capability) async

    /// Combine publisher mirroring `@Published var statuses`. SwiftUI
    /// surfaces (currently `PermissionsStep`) consume this as a publisher
    /// rather than the `@ObservedObject` projection so the protocol stays
    /// usable through `any` without the `ObservableObject` associated-type
    /// constraint that breaks existential types.
    ///
    /// Pre-Observation framework: when the codebase migrates to the
    /// `@Observable` macro (Phase 3 D1), this becomes an `Observable`
    /// requirement and the publisher disappears.
    var statusesPublisher: AnyPublisher<[Capability: PermissionStatus], Never> { get }
}
