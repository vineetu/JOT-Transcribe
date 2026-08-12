import FluidAudio
import Foundation

/// `jot setup` / `jot doctor` — getting a machine ready to transcribe.
///
/// Agent-first, which here means the non-interactive path is the DEFAULT and
/// the interactive one is opt-in (`--wizard`), not the other way around:
///
///   - stdout carries one JSON object and nothing else; humans read stderr
///   - nothing ever prompts unless `--wizard` was asked for, so an agent can
///     never be left blocked on a question it can't see
///   - `--wizard` on a non-tty fails immediately rather than hanging
///   - exit codes are the contract: 0 ready, 1 something is missing or failed,
///     2 the command was used wrong
///   - `setup` is idempotent — running it twice downloads nothing the second
///     time, so it is safe to put in a provisioning script
enum Setup {

    // MARK: - Components

    /// One installable (or merely checkable) piece of the CLI's runtime.
    enum Component: String, CaseIterable {
        case asr
        case streamEn = "stream-en"
        case streamZh = "stream-zh"
        case diarizer
        case ffmpeg

        /// What the user loses without it — the string `doctor` prints.
        var summary: String {
            switch self {
            case .asr: return "Parakeet TDT v3 — `\(programName) transcribe`"
            case .streamEn: return "Nemotron streaming (en) — `\(programName) --stream --language en`"
            case .streamZh: return "Nemotron multilingual (zh) — `\(programName) --stream --language zh`"
            case .diarizer: return "speaker diarization — `\(programName) transcribe --diarize`"
            case .ffmpeg: return "audio/video decoding for `\(programName) transcribe`"
            }
        }

        /// The default set: what a working install needs. `stream-zh` and the
        /// diarizer are large and most people never touch them, so they are
        /// opt-in via `--all` or `--components`.
        static var defaults: [Component] { [.asr, .streamEn, .ffmpeg] }

        var isDownloadable: Bool { self != .ffmpeg }

        /// Where it lives on disk. `nil` for ffmpeg, which is an executable we
        /// look up rather than a directory we own.
        var directory: URL? {
            switch self {
            case .asr:
                return ModelPaths.parakeetV3BundleDir(root: ModelPaths.parakeetRoot(override: nil))
            case .streamEn:
                return MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronStreaming1120)
            case .streamZh:
                // The repo is laid out by vocab FAMILY, not by language:
                // `<repo>/<latin|multilingual>/<chunkMs>ms`. zh falls in
                // "multilingual", and 2240 ms is what `--stream --language zh`
                // asks for (StreamRun's NemotronMultilingualEngine.chunkMs) —
                // checking a `zh-CN/` directory would report "missing" for a
                // model that is right there.
                return MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronMultilingual)
                    .appendingPathComponent("multilingual", isDirectory: true)
                    .appendingPathComponent("2240ms", isDirectory: true)
            case .diarizer:
                // Must match what `--diarize` actually loads: DiarizeEngine
                // hands `ModelPaths.diarizerRoot` to OfflineDiarizerManager
                // (the VBx diarizer), which keeps its files in a
                // `speaker-diarization/` subfolder. NOT
                // `DiarizerModels.defaultModelsDirectory()` — that is a
                // different diarizer family (pyannote/wespeaker) in a
                // different place, so setting it up would leave `--diarize`
                // exactly as broken as before.
                return ModelPaths.diarizerRoot.appendingPathComponent(
                    "speaker-diarization", isDirectory: true)
            case .ffmpeg:
                return nil
            }
        }

        /// Resolved location, whether or not it is present.
        var path: String {
            if case .ffmpeg = self { return FFmpegDecoder.ffmpegPath }
            return directory?.path ?? ""
        }

        var isReady: Bool {
            switch self {
            case .ffmpeg:
                return FileManager.default.isExecutableFile(atPath: FFmpegDecoder.ffmpegPath)
            case .asr:
                guard let dir = directory else { return false }
                return AsrModels.modelsExist(at: dir, version: .v3, encoderPrecision: .int8)
            case .streamZh:
                // FluidAudio treats this exact file as its "already cached"
                // marker (`downloadVariant`), so we use the same test rather
                // than inventing a weaker one.
                guard let dir = directory else { return false }
                return FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(
                        ModelNames.NemotronMultilingualStreaming.metadata).path)
            case .diarizer:
                // Name the actual model files: the parent dir also holds
                // `owner-voiceprint.json`, so "directory isn't empty" would
                // call a model-less install ready.
                guard let dir = directory else { return false }
                return ["Segmentation.mlmodelc", "Embedding.mlmodelc"].allSatisfy {
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
                }
            case .streamEn:
                // These managers own their own on-disk layout, so "the
                // directory exists and isn't empty" is the honest check —
                // claiming more would mean duplicating FluidAudio's file list
                // and going stale the next time it changes.
                guard let dir = directory else { return false }
                let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
                return !(contents ?? []).isEmpty
            }
        }

        /// What to tell someone whose machine is missing this.
        var hint: String {
            switch self {
            case .ffmpeg:
                return "install ffmpeg (`brew install ffmpeg`), or run the CLI from inside Jot.app "
                    + "where it ships alongside"
            default:
                return "run: \(programName) setup --components \(rawValue)"
            }
        }

        func install(progress: @escaping @Sendable (String) -> Void) async throws {
            switch self {
            case .ffmpeg:
                throw SetupError.notInstallable(
                    "ffmpeg is an external tool — \(hint)")
            case .asr:
                guard let dir = directory else { throw SetupError.notInstallable("no target directory") }
                progress("downloading Parakeet TDT v3 (~600 MB on a cold machine)…")
                _ = try await AsrModels.download(to: dir, version: .v3, encoderPrecision: .int8)
            case .streamEn:
                progress("downloading Nemotron streaming (en)…")
                let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
                try await manager.loadModels()
            case .streamZh:
                progress("downloading Nemotron multilingual (zh-CN)…")
                _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "zh-CN")
            case .diarizer:
                progress("downloading the speaker diarizer…")
                // prepareModels downloads into `<root>/speaker-diarization`,
                // which is the layout DiarizeEngine reads back.
                try await OfflineDiarizerManager(config: .default)
                    .prepareModels(directory: ModelPaths.diarizerRoot)
            }
        }
    }

    enum SetupError: Error, CustomStringConvertible {
        case notInstallable(String)
        var description: String {
            switch self {
            case .notInstallable(let s): return s
            }
        }
    }

    // MARK: - Commands

    @MainActor
    static func runSetup(_ rawArgs: [String]) async -> Int32 {
        var args = rawArgs
        let wizard = args.contains("--wizard")
        args.removeAll { $0 == "--wizard" }
        let force = args.contains("--force")
        args.removeAll { $0 == "--force" }

        let components: [Component]
        switch selectComponents(&args) {
        case .failure(let message):
            humanErr(message)
            return 2
        case .success(let selected):
            components = selected
        }
        guard args.isEmpty else {
            humanErr("setup: unexpected argument(s): \(args.joined(separator: " "))")
            return 2
        }

        if wizard {
            guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
                humanErr(
                    "setup --wizard needs an interactive terminal (stdin is not a tty). "
                        + "Drop --wizard to run non-interactively.")
                return 2
            }
            return await runWizard(components: components, force: force)
        }
        return await runNonInteractive(components: components, force: force)
    }

    @MainActor
    static func runDoctor(_ rawArgs: [String]) -> Int32 {
        var args = rawArgs
        let human = args.contains("--human")
        args.removeAll { $0 == "--human" }

        let components: [Component]
        switch selectComponents(&args) {
        case .failure(let message):
            humanErr(message)
            return 2
        case .success(let selected):
            components = selected
        }
        guard args.isEmpty else {
            humanErr("doctor: unexpected argument(s): \(args.joined(separator: " "))")
            return 2
        }

        let rows = components.map {
            (component: $0, ready: $0.isReady)
        }
        let ok = rows.allSatisfy(\.ready)

        if human {
            for row in rows {
                let mark = row.ready ? "ok     " : "MISSING"
                print("\(mark)  \(row.component.rawValue)  \(row.component.summary)")
                print("         \(row.component.path)")
                if !row.ready { print("         → \(row.component.hint)") }
            }
            print(ok ? "\nEverything this CLI needs is present." : "\nSomething is missing — see above.")
        } else {
            emitJSON([
                "ok": ok,
                "components": rows.map { row in
                    var entry: [String: Any] = [
                        "id": row.component.rawValue,
                        "status": row.ready ? "ready" : "missing",
                        "path": row.component.path,
                        "summary": row.component.summary,
                    ]
                    if !row.ready { entry["hint"] = row.component.hint }
                    return entry
                },
            ])
        }
        return ok ? 0 : 1
    }

    // MARK: - Modes

    @MainActor
    private static func runNonInteractive(components: [Component], force: Bool) async -> Int32 {
        var results: [[String: Any]] = []
        var allOK = true

        for component in components {
            if component.isReady && !force {
                results.append(entry(component, status: "ready", action: "already-present"))
                continue
            }
            guard component.isDownloadable else {
                allOK = false
                var e = entry(component, status: "missing", action: "not-installable")
                e["hint"] = component.hint
                results.append(e)
                continue
            }
            do {
                try await component.install { humanErr("setup: \($0)") }
                let ready = component.isReady
                allOK = allOK && ready
                results.append(
                    entry(component, status: ready ? "ready" : "missing", action: "installed"))
            } catch {
                allOK = false
                var e = entry(component, status: "missing", action: "failed")
                e["error"] = "\(error)"
                results.append(e)
            }
        }

        emitJSON(["ok": allOK, "components": results])
        return allOK ? 0 : 1
    }

    @MainActor
    private static func runWizard(components: [Component], force: Bool) async -> Int32 {
        print("Jot CLI setup\n")
        let pending = components.filter { force ? $0.isDownloadable : !$0.isReady }

        for component in components where component.isReady && !force {
            print("  ✓ \(component.rawValue) — already installed")
        }
        guard !pending.isEmpty else {
            print("\nNothing to do; this machine is ready.")
            return 0
        }

        print("\nMissing:")
        for component in pending {
            print("  • \(component.rawValue) — \(component.summary)")
            if !component.isDownloadable { print("      \(component.hint)") }
        }

        let downloadable = pending.filter(\.isDownloadable)
        let blocked = pending.filter { !$0.isDownloadable }
        guard !downloadable.isEmpty else {
            print("\nNothing here can be installed automatically.")
            return 1
        }

        print("\nDownload \(downloadable.count == 1 ? "it" : "them") now? [Y/n] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer.isEmpty || answer == "y" || answer == "yes" else {
            print("Skipped. Re-run `\(programName) setup --wizard` whenever you're ready.")
            return 1
        }

        var failed = false
        for component in downloadable {
            print("\n\(component.rawValue):")
            do {
                try await component.install { print("  \($0)") }
                if component.isReady {
                    print("  done.")
                } else {
                    failed = true
                    print("  finished, but the files still aren't there — try again with --force.")
                }
            } catch {
                failed = true
                print("  failed: \(error)")
            }
        }

        if !blocked.isEmpty {
            print("\nStill needs you:")
            for component in blocked { print("  • \(component.rawValue) — \(component.hint)") }
        }
        let ok = !failed && blocked.isEmpty
        print(ok ? "\nAll set." : "\nFinished with problems — `\(programName) doctor --human` shows what's left.")
        return ok ? 0 : 1
    }

    // MARK: - Shared

    private enum Selection {
        case success([Component])
        case failure(String)
    }

    /// `--all`, `--components a,b`, or the default set.
    private static func selectComponents(_ args: inout [String]) -> Selection {
        let all = args.contains("--all")
        args.removeAll { $0 == "--all" }

        var explicit: String?
        if let i = args.firstIndex(of: "--components"), i + 1 < args.count {
            explicit = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }

        if let explicit {
            var chosen: [Component] = []
            for raw in explicit.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard let component = Component(rawValue: raw) else {
                    let known = Component.allCases.map(\.rawValue).joined(separator: ", ")
                    return .failure("unknown component '\(raw)' (known: \(known))")
                }
                chosen.append(component)
            }
            guard !chosen.isEmpty else { return .failure("--components was empty") }
            return .success(chosen)
        }
        return .success(all ? Component.allCases : Component.defaults)
    }

    private static func entry(_ component: Component, status: String, action: String) -> [String: Any] {
        [
            "id": component.rawValue,
            "status": status,
            "action": action,
            "path": component.path,
        ]
    }

    /// The one thing stdout is allowed to carry in non-wizard mode.
    private static func emitJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else {
            humanErr("could not serialize the result")
            return
        }
        print(text)
    }

    private static func humanErr(_ s: String) {
        FileHandle.standardError.write(Data("\(programName): \(s)\n".utf8))
    }
}
