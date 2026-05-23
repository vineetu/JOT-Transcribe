import Combine
import Foundation
import SwiftData
import os.log

/// Main-actor-bound query + write surface for `EnrolledIdentity` rows.
///
/// Two consumers today:
/// * Settings → Speaker Labels pane reads / writes via `@ObservableObject`
///   binding so the UI updates whenever the underlying SwiftData rows
///   change.
/// * `SortformerHolder.loadIfNeeded(clips:)` reads the list at app launch
///   to replay enrolled clips through Sortformer's slot bindings.
///
/// Concurrency contract (per plan): all writes happen synchronously on the
/// main actor inside this store; no off-main producer of `@Model` rows.
@MainActor
final class EnrolledIdentitiesStore: ObservableObject {

    @Published private(set) var identities: [EnrolledIdentity] = []

    private let context: ModelContext
    private let log = Logger(subsystem: "com.jot.Jot", category: "EnrolledIdentitiesStore")

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        // SortDescriptor on Bool is not available; do a primary sort by
        // enrolledAt and let the UI partition owner vs others.
        let descriptor = FetchDescriptor<EnrolledIdentity>(
            sortBy: [SortDescriptor(\.enrolledAt, order: .forward)]
        )
        do {
            let fetched = try context.fetch(descriptor)
            // Owner first, then collaborators in enrollment order.
            identities = fetched.sorted { lhs, rhs in
                if lhs.isUser != rhs.isUser { return lhs.isUser }
                return lhs.enrolledAt < rhs.enrolledAt
            }
        } catch {
            log.error("Failed to fetch EnrolledIdentity rows: \(String(describing: error))")
            identities = []
        }
    }

    /// True when at least one identity row exists. Drives the
    /// progressive-disclosure CTA-vs-toggle behavior in Settings.
    var hasIdentities: Bool { !identities.isEmpty }

    /// True when an owner identity (isUser == true) exists.
    var hasOwnerIdentity: Bool { identities.contains(where: { $0.isUser }) }

    /// Number of additional collaborators allowed before the cap is hit.
    /// Returns 0 when the cap (4 total) is reached.
    var remainingSlots: Int {
        max(0, SpeakerLabelsConstants.identityCap - identities.count)
    }

    /// Insert a new identity. Caller must ensure the cap is not exceeded;
    /// returns `false` and skips the write when adding would breach it.
    @discardableResult
    func add(name: String, isUser: Bool, samples: [Float]) -> EnrolledIdentity? {
        guard identities.count < SpeakerLabelsConstants.identityCap else {
            log.warning("Refusing to add EnrolledIdentity beyond cap of \(SpeakerLabelsConstants.identityCap)")
            return nil
        }
        let clipData = EnrolledIdentity.encode(samples: samples)
        let identity = EnrolledIdentity(
            name: name,
            isUser: isUser,
            voiceClips: [clipData]
        )
        context.insert(identity)
        save("add identity")
        refresh()
        return identity
    }

    /// Replace the (single) voice clip on an existing identity — used by
    /// "Re-record voice." Caller is responsible for re-enrolling the new
    /// clip into Sortformer if the model is loaded.
    func replaceClip(on identity: EnrolledIdentity, samples: [Float]) {
        identity.voiceClips = [EnrolledIdentity.encode(samples: samples)]
        identity.enrolledAt = .now
        save("replace clip on identity")
        refresh()
    }

    func delete(_ identity: EnrolledIdentity) {
        context.delete(identity)
        save("delete identity")
        refresh()
    }

    /// Wipe every identity row. Used by "Reset all data" and by tests.
    func deleteAll() {
        for identity in identities {
            context.delete(identity)
        }
        save("delete all identities")
        refresh()
    }

    /// Snapshot the enrolled clips as `EnrolledClip` records ready to hand
    /// to `SortformerHolder.loadIfNeeded(clips:)`. Skips identities whose
    /// clip blob decodes to an empty buffer.
    func clipsForWarmup() -> [EnrolledClip] {
        identities.compactMap { identity in
            guard let samples = identity.primarySamples, !samples.isEmpty else { return nil }
            return EnrolledClip(name: identity.name, samples: samples)
        }
    }

    private func save(_ label: String) {
        do {
            try context.save()
        } catch {
            log.error("SwiftData save failed (\(label, privacy: .public)): \(String(describing: error))")
        }
    }
}
