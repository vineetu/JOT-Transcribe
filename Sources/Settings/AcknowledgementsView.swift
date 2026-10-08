import SwiftUI

/// About → Acknowledgements → "Models and open-source licenses": every model
/// Jot downloads and every library it ships, with author, what Jot uses it
/// for, and its license. The attribution these licenses ask for (CC BY 4.0
/// credit, keeping OpenMDW / NVIDIA notices) lives here.
///
/// When a model or package is added or removed, update `sections` — the list
/// is hand-kept so each entry can say what Jot actually uses it for.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Acknowledgements").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                Section {
                    Text("Jot is built on these models and open-source projects. Thank you to everyone who made them and shared them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Self.sections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            AcknowledgementRow(entry: entry)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        }
        .frame(width: 560, height: 620)
    }
}

private struct AcknowledgementRow: View {
    let entry: Acknowledgement

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).fontWeight(.medium)
                Spacer()
                Link(entry.license.name, destination: entry.license.url)
                    .font(.callout)
            }
            Text(entry.credit)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(entry.use)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let notice = entry.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

// MARK: - Data

struct AcknowledgementSection: Identifiable {
    let title: String
    let entries: [Acknowledgement]
    var id: String { title }
}

struct Acknowledgement: Identifiable {
    let name: String
    let credit: String
    let use: String
    let license: License
    var notice: String? = nil
    var id: String { name }

    struct License {
        let name: String
        let url: URL

        static let ccBy4 = License(name: "CC BY 4.0", url: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
        static let nvidiaOpenModel = License(name: "NVIDIA Open Model License", url: URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!)
        static let openMDW = License(name: "OpenMDW 1.1", url: URL(string: "https://openmdw.ai/license/1-1/")!)
        static let apache2 = License(name: "Apache 2.0", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
        static let lgpl21 = License(name: "LGPL 2.1", url: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!)
        /// `file` is the license's path in the repo (not every repo calls it LICENSE).
        static func mit(_ repo: String, file: String = "LICENSE") -> License {
            License(name: "MIT", url: URL(string: "https://github.com/\(repo)/blob/HEAD/\(file)")!)
        }
    }
}

extension AcknowledgementsView {
    private static let nvidiaViaFluid = "NVIDIA · Core ML conversion by FluidInference"

    static let sections: [AcknowledgementSection] = [
        AcknowledgementSection(title: "Speech recognition", entries: [
            Acknowledgement(
                name: "Parakeet TDT 0.6B v3",
                credit: nvidiaViaFluid,
                use: "Transcribes dictation and imported files in 25 European languages.",
                license: .ccBy4),
            Acknowledgement(
                name: "Parakeet TDT 0.6B v2",
                credit: nvidiaViaFluid,
                use: "English transcription (older option).",
                license: .ccBy4),
            Acknowledgement(
                name: "Parakeet TDT-CTC 0.6B Japanese",
                credit: nvidiaViaFluid,
                use: "Japanese transcription.",
                license: .ccBy4),
            Acknowledgement(
                name: "Parakeet Realtime EOU 120M",
                credit: nvidiaViaFluid,
                use: "Live preview while you speak.",
                license: .nvidiaOpenModel),
            Acknowledgement(
                name: "Nemotron Speech Streaming English 0.6B",
                credit: nvidiaViaFluid,
                use: "Streaming English transcription.",
                license: .nvidiaOpenModel),
            Acknowledgement(
                name: "Nemotron 3.5 ASR Streaming Multilingual 0.6B",
                credit: nvidiaViaFluid,
                use: "Streaming transcription in other languages.",
                license: .openMDW),
            Acknowledgement(
                name: "Parakeet CTC 110M and 0.6B",
                credit: nvidiaViaFluid,
                use: "Spots your custom vocabulary in what you said.",
                license: .ccBy4),
        ]),
        AcknowledgementSection(title: "Speaker labels", entries: [
            Acknowledgement(
                name: "Nemotron 3 Diarization",
                credit: nvidiaViaFluid,
                use: "Works out who spoke when in a recording.",
                license: .openMDW),
        ]),
        AcknowledgementSection(title: "Search", entries: [
            Acknowledgement(
                name: "multilingual-e5-small",
                credit: "Microsoft · Core ML conversion by Jot",
                use: "Finds recordings by meaning, not just matching words.",
                license: .mit("microsoft/unilm")),
        ]),
        AcknowledgementSection(title: "Libraries", entries: [
            Acknowledgement(
                name: "FluidAudio",
                credit: "FluidInference (Jot uses a fork)",
                use: "Runs the speech and speaker models on the Neural Engine.",
                license: .apache2),
            Acknowledgement(
                name: "swift-transformers, swift-huggingface, swift-jinja",
                credit: "Hugging Face",
                use: "Splits text into tokens for the search model.",
                license: .apache2),
            Acknowledgement(
                name: "Sparkle",
                credit: "The Sparkle Project",
                use: "App updates.",
                license: .mit("sparkle-project/Sparkle")),
            Acknowledgement(
                name: "KeyboardShortcuts",
                credit: "Sindre Sorhus",
                use: "Global shortcut recording and handling.",
                license: .mit("sindresorhus/KeyboardShortcuts", file: "license")),
            Acknowledgement(
                name: "EventSource",
                credit: "Mattt",
                use: "Streams AI responses.",
                license: .mit("mattt/EventSource", file: "LICENSE.md")),
            Acknowledgement(
                name: "yyjson",
                credit: "YaoYuan",
                use: "Fast JSON parsing.",
                license: .mit("ibireme/yyjson")),
            Acknowledgement(
                name: "Swift Collections, Crypto, NIO, Atomics, System, ASN.1",
                credit: "Apple and the Swift project",
                use: "Supporting libraries.",
                license: .apache2),
            Acknowledgement(
                name: "FFmpeg",
                credit: "The FFmpeg developers",
                use: "Decodes audio and video formats macOS can't open on its own.",
                license: .lgpl21,
                notice: "Unmodified FFmpeg 7.1.1 (ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz), built decode-only; the build recipe is in Jot's repository at Vendor/ffmpeg/BUILD.md and the license text is inside Jot.app. FFmpeg is a trademark of Fabrice Bellard."),
        ]),
    ]
}
