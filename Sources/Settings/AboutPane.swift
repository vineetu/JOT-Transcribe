import AppKit
import SwiftUI

/// About pane — identity, vision, donation ask, privacy pledge.
///
/// No automatic network calls: the donation total lives on the web at
/// `jot-donations.ideaflow.page/summary` and opens in the user's browser.
/// Keeps Jot's privacy invariant intact (model download + daily appcast +
/// user-configured LLMs are the only outbound calls from within the app).
struct AboutPane: View {
    var body: some View {
        Form {
            identitySection
            visionSection
            donationSection
            privacySection
            creditSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jot")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Press a hotkey, speak, paste.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(versionString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    // MARK: - Vision

    private var visionSection: some View {
        Section("Vision") {
            Text("To use AI to optimize your natural flow of thought and clearly articulate your ideas — empowering you to think for yourself rather than letting the AI do the thinking for you.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Donation

    private var donationSection: some View {
        Section("Support") {
            Text("Jot is free. If you'd like to support it, please donate to charity through my every.org fund instead of paying me — 100% goes to causes I've personally vetted.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Link(destination: URL(string: "https://www.every.org/@vineet.sriram")!) {
                    Label("Donate to charity", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Link(destination: URL(string: "https://jot.ideaflow.page/donations")!) {
                    Label("See total raised", systemImage: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("Transcription runs entirely on-device. No telemetry, no analytics, no accounts. The only automatic network calls Jot makes are the first-run transcription model download and a daily update check. AI features, when enabled, talk to whichever provider you configure.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Credit

    private var creditSection: some View {
        Section {
            HStack(spacing: 4) {
                Text("Built by")
                    .foregroundStyle(.secondary)
                Text("Vineet Sriram")
                Spacer()
            }
            .font(.system(size: 11))
        }
    }
}
