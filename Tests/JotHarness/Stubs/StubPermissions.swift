import Combine
import Foundation
@testable import Jot

/// Harness conformer for `PermissionsObserving`. Returns canned
/// `[Capability: PermissionStatus]` maps; mutable so tests that flip
/// permissions mid-flow (e.g. F1 "Mic granted then revoked") can drive
/// the change through the publisher.
///
/// `@MainActor` because the protocol is `@MainActor`-isolated.
@MainActor
final class StubPermissions: PermissionsObserving {
    private let subject: CurrentValueSubject<[Capability: PermissionStatus], Never>

    init(seed: PermissionGrants = .allGranted) {
        self.subject = CurrentValueSubject(Self.expand(seed))
    }

    /// Mutate the grant matrix at runtime. Pushes through the
    /// publisher so any `@Published`-flavored consumer sees the
    /// change immediately.
    func update(_ grants: PermissionGrants) {
        subject.send(Self.expand(grants))
    }

    /// Direct override — flip a single capability without rebuilding
    /// the whole map.
    func set(_ capability: Capability, _ status: PermissionStatus) {
        var current = subject.value
        current[capability] = status
        subject.send(current)
    }

    // MARK: - PermissionsObserving

    var statuses: [Capability: PermissionStatus] { subject.value }

    func status(for capability: Capability) -> PermissionStatus {
        subject.value[capability] ?? .notDetermined
    }

    func refreshAll() {
        // No-op: the stub's truth is whatever the test set.
    }

    func request(_ capability: Capability) async {
        // Default behavior: granting on request mirrors the happy
        // path. Tests that want to deny a request should pre-set
        // `.denied` via `set(_:_:)` and override behavior in their
        // test fixture.
        set(capability, .granted)
    }

    var statusesPublisher: AnyPublisher<[Capability: PermissionStatus], Never> {
        subject.eraseToAnyPublisher()
    }

    // MARK: - Seed → matrix

    private static func expand(_ grants: PermissionGrants) -> [Capability: PermissionStatus] {
        switch grants {
        case .allGranted:
            return Capability.allCases.reduce(into: [:]) { $0[$1] = .granted }
        case .micDenied:
            return [
                .microphone: .denied,
                .inputMonitoring: .granted,
                .accessibilityPostEvents: .granted,
                .accessibilityFullAX: .granted,
            ]
        case .inputMonitoringDenied:
            return [
                .microphone: .granted,
                .inputMonitoring: .denied,
                .accessibilityPostEvents: .granted,
                .accessibilityFullAX: .granted,
            ]
        case .accessibilityDenied:
            return [
                .microphone: .granted,
                .inputMonitoring: .granted,
                .accessibilityPostEvents: .denied,
                .accessibilityFullAX: .denied,
            ]
        case .custom(let map):
            // Fill in any missing capabilities as `.notDetermined` so
            // downstream lookups never crash.
            var filled = map
            for cap in Capability.allCases where filled[cap] == nil {
                filled[cap] = .notDetermined
            }
            return filled
        }
    }
}
