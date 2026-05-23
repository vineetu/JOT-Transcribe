import SwiftUI

/// Speaker Labels piece A: Settings sidebar pane for managing enrolled
/// voices and the master toggle.
///
/// Progressive disclosure per plan Decision #2:
/// * **Pre-setup (no identities enrolled):** description + privacy line +
///   a single `[Set up speaker labels →]` CTA. No toggle visible.
/// * **Post-setup (≥1 identity):** master toggle at the top, then the
///   list of enrolled voices with per-row `[Re-record voice]` / `[Delete]`,
///   and `[+ Add another person]` until the 4-identity cap is hit.
/// * **Unsupported hardware (< 16 GB):** toggle is locked OFF with a
///   short explanation. Enrollment is still allowed — the user can move
///   to a 16 GB Mac later via Time Machine and have it work.
///
/// Enrollment runs inline via `SpeakerLabelsEnrollmentSheet`. Recording
/// audio is captured by Jot's existing `AudioCapture` pipeline (16 kHz
/// mono Float32) and saved as a single clip on the new
/// `EnrolledIdentity` row.
struct SpeakerLabelsPane: View {

    @EnvironmentObject private var sortformerHolder: SortformerHolder
    @EnvironmentObject private var identitiesStore: EnrolledIdentitiesStore

    @AppStorage("jot.speakerLabels.enabled") private var masterEnabled: Bool = true

    @State private var enrollmentTarget: EnrollmentTarget?
    @State private var inFlightDownloadError: String?

    /// Identifies the active enrollment flow — first owner enrollment,
    /// adding a collaborator, or re-recording an existing identity.
    enum EnrollmentTarget: Identifiable {
        case owner
        case collaborator
        case replace(identity: EnrolledIdentity)

        var id: String {
            switch self {
            case .owner: return "owner"
            case .collaborator: return "collaborator"
            case .replace(let i): return "replace-\(i.id.uuidString)"
            }
        }
    }

    var body: some View {
        Form {
            headerSection
            if identitiesStore.hasIdentities {
                masterToggleSection
                enrolledVoicesSection
            } else {
                setupCtaSection
            }
            downloadStatusSection
        }
        .formStyle(.grouped)
        .sheet(item: $enrollmentTarget) { target in
            SpeakerLabelsEnrollmentSheet(
                target: target,
                onComplete: { name, isOwner, samples in
                    handleEnrollmentComplete(
                        target: target,
                        name: name,
                        isOwner: isOwner,
                        samples: samples
                    )
                },
                onCancel: { enrollmentTarget = nil }
            )
            .frame(minWidth: 520, minHeight: 360)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker labels")
                    .font(.headline)
                Text("Label who said what in meeting recordings. Jot recognizes your voice and labels other speakers. Voice profiles stay on this Mac — about 4 MB at the 4-identity cap, never sent to a server, wiped on Reset all data.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var masterToggleSection: some View {
        Section {
            HStack {
                Toggle(isOn: $masterEnabled) {
                    Text("Speaker labels")
                }
                .disabled(!SortformerHardwareGate.isSupported)
                .onChange(of: masterEnabled) { _, newValue in
                    handleMasterToggle(to: newValue)
                }
                Spacer()
            }

            if !SortformerHardwareGate.isSupported {
                Text("Speaker labels need 16 GB of RAM to run. Your setup is saved on this Mac and ready if you later move Jot to a Mac with more memory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var enrolledVoicesSection: some View {
        Section("Enrolled voices") {
            ForEach(identitiesStore.identities, id: \.id) { identity in
                identityRow(identity)
            }
            if identitiesStore.remainingSlots > 0 {
                Button {
                    enrollmentTarget = .collaborator
                } label: {
                    Label("Add another person", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Reached the 4-identity limit. Delete a voice to add a new one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func identityRow(_ identity: EnrolledIdentity) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.isUser ? "You (\(identity.name))" : identity.name)
                    .font(.system(size: 13, weight: .medium))
                Text("Enrolled \(identity.enrolledAt, format: .relative(presentation: .named))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-record voice") {
                enrollmentTarget = .replace(identity: identity)
            }
            .controlSize(.small)
            if !identity.isUser {
                Button(role: .destructive) {
                    delete(identity: identity)
                } label: {
                    Text("Delete")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var setupCtaSection: some View {
        Section {
            Button {
                Task { await beginOwnerEnrollment() }
            } label: {
                HStack {
                    Image(systemName: "person.wave.2")
                    Text("Set up speaker labels")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !SortformerHardwareGate.isSupported {
                Text("Heads up: this Mac has less than 16 GB of RAM. You can still set up and store voice profiles, but the labeling itself won't run here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var downloadStatusSection: some View {
        switch sortformerHolder.state {
        case .downloading(let progress):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading speaker-recognition model…")
                        .font(.system(size: 12, weight: .medium))
                    ProgressView(value: progress)
                }
            }
        case .downloadFailed(let message):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download failed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await downloadModel() }
                    }
                    .controlSize(.small)
                }
            }
        case .loading:
            Section {
                Label("Loading voice-recognition model…", systemImage: "hourglass")
                    .font(.system(size: 12))
            }
        case .loaded, .offHaveModel, .notSetUp, .unsupportedHardware:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func beginOwnerEnrollment() async {
        await ensureModelOnDisk()
        if case .downloadFailed = sortformerHolder.state { return }
        enrollmentTarget = .owner
    }

    private func ensureModelOnDisk() async {
        switch sortformerHolder.state {
        case .notSetUp, .downloadFailed:
            await downloadModel()
        case .downloading, .offHaveModel, .loading, .loaded, .unsupportedHardware:
            return
        }
    }

    private func downloadModel() async {
        do {
            try await sortformerHolder.downloadModelIfNeeded()
        } catch {
            inFlightDownloadError = error.localizedDescription
        }
    }

    private func handleMasterToggle(to newValue: Bool) {
        if newValue {
            // ON: load the model + replay enrolled clips so the next
            // recording produces labels.
            let clips = identitiesStore.clipsForWarmup()
            Task {
                await sortformerHolder.loadIfNeeded(clips: clips)
            }
        } else {
            // OFF: drop the in-memory model. Identities + on-disk model
            // are preserved (Decision #3).
            sortformerHolder.unload()
        }
    }

    private func handleEnrollmentComplete(
        target: EnrollmentTarget,
        name: String,
        isOwner: Bool,
        samples: [Float]
    ) {
        switch target {
        case .owner:
            _ = identitiesStore.add(name: name, isUser: true, samples: samples)
        case .collaborator:
            _ = identitiesStore.add(name: name, isUser: false, samples: samples)
        case .replace(let identity):
            identitiesStore.replaceClip(on: identity, samples: samples)
        }

        // Refresh Sortformer's slot bindings. If the model is already
        // loaded, hot-enroll the new/replacement clip. If it's only on
        // disk (toggle OFF or not yet loaded), do nothing — the next
        // load will replay every clip from SwiftData.
        let clip = EnrolledClip(name: name, samples: samples)
        if !sortformerHolder.enrollLiveIfLoaded(clip: clip) {
            // Model isn't loaded — if the master toggle is ON and the
            // model is on disk, kick off a load now so the next recording
            // benefits.
            if masterEnabled, sortformerHolder.state == .offHaveModel {
                let clips = identitiesStore.clipsForWarmup()
                Task { await sortformerHolder.loadIfNeeded(clips: clips) }
            }
        }

        enrollmentTarget = nil
    }

    private func delete(identity: EnrolledIdentity) {
        identitiesStore.delete(identity)
        // Sortformer has no hot-update API for slot removal; the next
        // app launch's warmup replays only the surviving clips.
    }
}
