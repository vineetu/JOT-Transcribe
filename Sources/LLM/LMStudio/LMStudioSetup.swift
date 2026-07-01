import Foundation
import Combine
import Darwin

/// Orchestrates the in-app, hardened, headless setup of LM Studio's
/// `llmster` daemon + the recommended local model (Qwen 3.5 9B, MLX
/// 4-bit), with thinking disabled, on capable Apple-Silicon Macs.
///
/// **Positioning:** LM Studio is the *recommended local* provider on
/// public builds ("Recommended (local)") and a plain *local option* on
/// Sony ("Local option"). It is never the default — selecting `.lmStudio`
/// as the active provider stays user-initiated. See
/// `docs/lmstudio-recommend/design.md`.
///
/// **One-gesture invariant (security F5/F6, mirrors `Flavor1Session`):**
/// every network / install action — downloading the pinned `install.sh`,
/// running it (which pulls the 577 MB `llmster` tarball), and the ~6 GB
/// `lms get` model pull — happens ONLY behind an explicit user button
/// press. `detectState()` is read-only and safe to call from `onAppear`;
/// `install()` and `downloadModel()` are the ONLY methods that spawn a
/// subprocess or touch the network, and both are button-driven. No
/// `onAppear` / timer / launch path may call them.
///
/// **No remote-script execution (F6):** we download `install.sh`, verify
/// it byte-for-byte against a Jot-pinned sha512, and run ONLY that exact
/// audited script — never `curl | sh`. The script itself version-pins the
/// tarball and verifies its own sha512 internally.
@MainActor
final class LMStudioSetup: ObservableObject {

    // MARK: - State

    enum SetupState: Equatable {
        /// physical RAM ≤ 16 GB — LM Studio is not surfaced as recommended
        /// and install is not offered. The card hides itself entirely.
        case unsupportedRAM
        /// `lms` CLI absent.
        case notInstalled
        /// Running the pinned `install.sh`. Progress is best-effort (0…1).
        case installing(Double)
        /// `lms` present, recommended model absent (or not yet served).
        case readyNoModel
        /// `lms get` in flight. Progress (0…1) is computed from the on-disk
        /// size of the model folder ÷ the known total — NOT from `lms get`'s
        /// per-shard CLI percentages, which reset 0→100 per shard and can't be
        /// aggregated into a monotonic bar. Byte-on-disk progress is monotonic
        /// and format-independent.
        case downloadingModel(Double)
        /// `lms get` finished; loading + serving + resolving the served id.
        /// Quick relative to the download, so it shows an indeterminate bar —
        /// distinct from `.downloadingModel` so the card stops claiming a
        /// (possibly cached, instant) "Downloading…" while it's really loading.
        case loadingModel
        /// Model present, server serving it, model id persisted into config.
        case configured
        /// Setup hit a fatal error. The card surfaces the message + retry.
        case error(String)
    }

    @Published private(set) var state: SetupState = .notInstalled

    /// Non-fatal warning surfaced alongside `.configured` — e.g. the
    /// no-think verification still saw reasoning tokens after a re-apply.
    /// Doesn't block use; the card shows it as an advisory.
    @Published private(set) var warning: String?

    // MARK: - Pinned constants

    /// User-space `lms` CLI path created by the headless `llmster` install.
    /// No sudo, no PATH edits (`LMS_NO_MODIFY_PATH=1`).
    static let lmsRelativePath = ".lmstudio/bin/lms"

    /// Recommended model alias. Resolves to
    /// `lmstudio-community/Qwen3.5-9B-MLX-4bit` (~6 GB). The id persisted
    /// into config is the one `/v1/models` reports, not this alias (F3).
    static let modelAlias = "qwen/qwen3.5-9b"

    /// On-disk repo subpath under `~/.lmstudio/models/` where `lms get` writes
    /// the recommended model's shards. Used to size the download for the
    /// progress bar.
    static let modelRepoSubpath = "lmstudio-community/Qwen3.5-9B-MLX-4bit"

    /// Approximate total on-disk bytes of the recommended model (the two MLX
    /// shards ≈ 5.35 GB + 0.60 GB plus tokenizer/config ≈ 5.98 GB). Only the
    /// denominator for the byte-based progress bar; the bar caps at 0.99 until
    /// `lms get` returns, so a small over/under-estimate just shifts where the
    /// bar sits at completion, never its monotonicity.
    static let expectedModelBytes: Int64 = 5_980_000_000

    /// LM Studio's OpenAI-compatible server port.
    static let serverPort = 1234

    /// Recommend only when physical RAM is strictly greater than this.
    static let ramThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// Upper bound of the tight-RAM advisory band (16 GB < RAM ≤ 18 GB):
    /// works, but may be slow under memory pressure.
    static let tightRAMUpperBytes: UInt64 = 18 * 1024 * 1024 * 1024

    /// Minimum free disk (GB) required before offering the ~6 GB model pull.
    static let diskFloorGB: Double = 7

    /// Official LM Studio engine installer. Fetched over HTTPS and run as-is
    /// (no Jot-side hash pin — see `install()` for the rationale). The script
    /// self-pins its llmster version and verifies its own tarball's sha512.
    static let installShURL = "https://lmstudio.ai/install.sh"

    // MARK: - Process tuning

    /// Watchdog ceilings (seconds). The install script downloads 577 MB and
    /// the model pull downloads ~6 GB, so these are generous; they exist to
    /// kill a genuinely hung process, not to bound normal transfers.
    private static let installTimeoutSeconds: TimeInterval = 30 * 60
    private static let downloadTimeoutSeconds: TimeInterval = 60 * 60
    private static let quickCommandTimeoutSeconds: TimeInterval = 60

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Paths

    private var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    private var lmsPath: URL {
        homeDirectory.appendingPathComponent(Self.lmsRelativePath)
    }

    private var modelsDirectory: URL {
        homeDirectory.appendingPathComponent(".lmstudio/models")
    }

    /// Folder `lms get` writes the recommended model into. Polled for its size
    /// to drive the download progress bar.
    private var modelDownloadDirectory: URL {
        modelsDirectory.appendingPathComponent(Self.modelRepoSubpath)
    }

    /// Total bytes of all regular files under `directory` (0 if it doesn't
    /// exist yet). `nonisolated` + `Sendable`-input so the progress poller can
    /// call it off the main actor.
    nonisolated static func directorySizeBytes(at directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private var serverBaseURL: String {
        "http://localhost:\(Self.serverPort)/v1"
    }

    // MARK: - Read-only detection (safe from onAppear)

    /// True iff physical RAM qualifies the machine for the recommendation.
    static var ramQualifies: Bool {
        ProcessInfo.processInfo.physicalMemory > ramThresholdBytes
    }

    /// True for the tight-RAM advisory band: 16 GB < RAM ≤ 18 GB.
    static var isTightRAM: Bool {
        let ram = ProcessInfo.processInfo.physicalMemory
        return ram > ramThresholdBytes && ram <= tightRAMUpperBytes
    }

    private func lmsCliPresent() -> Bool {
        FileManager.default.fileExists(atPath: lmsPath.path)
    }

    /// Free disk in GB on the boot volume, for the model-pull gate.
    static func freeDiskGB() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else {
            return 0
        }
        return Double(bytes) / 1_000_000_000
    }

    /// Read-only state probe. Safe to call from `onAppear` — never spawns a
    /// subprocess or hits a remote host (only `http://localhost:<port>`).
    func detectState() async {
        guard Self.ramQualifies else {
            state = .unsupportedRAM
            return
        }
        guard lmsCliPresent() else {
            state = .notInstalled
            return
        }
        // lms present: is the recommended model downloaded AND served?
        if await serverServesRecommendedModel() {
            // F7 re-apply hook: LM Studio model updates can regenerate
            // `chat_template.jinja` and silently re-enable thinking. Re-prepend
            // the no-think directive whenever we detect a configured state.
            // This is a pure LOCAL file write (idempotent, no network, no
            // subprocess) — safe from `.task`/onAppear; it does NOT violate
            // the one-gesture/no-spawn rule. Any reload stays gesture-driven.
            applyNoThinkPatch()
            state = .configured
        } else {
            state = .readyNoModel
        }
    }

    /// Hits `GET <localhost>/v1/models` and checks whether any served id
    /// looks like the recommended Qwen 3.5 9B model. Localhost only.
    private func serverServesRecommendedModel() async -> Bool {
        (await servedModelIDs()).contains(where: Self.looksLikeRecommendedModel)
    }

    private func servedModelIDs() async -> [String] {
        guard let url = URL(string: "\(serverBaseURL)/models") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            return []
        }
        return LMStudioProbe.parse(data: data).map(\.id)
    }

    /// Loose match for the recommended model's served id. The alias is
    /// `qwen/qwen3.5-9b`; the served id is typically
    /// `qwen3.5-9b` / `lmstudio-community/Qwen3.5-9B-MLX-4bit`.
    private static func looksLikeRecommendedModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("qwen3.5-9b") || lower.contains("qwen3.5_9b")
    }

    // MARK: - install() — ONE user gesture

    /// Downloads the official `install.sh` over HTTPS and runs it headlessly.
    /// THE ONLY install entry point — button-driven only.
    ///
    /// No Jot-side checksum pin. LM Studio reformats `install.sh` every few
    /// releases; a pinned-hash check made the feature break for EVERY user on
    /// each bump until an app update shipped — pinning a volatile artifact in a
    /// rarely-updated app. Instead we trust HTTPS to the official host (TLS
    /// cert-validated) plus the script's OWN internal sha512 verification of the
    /// llmster tarball it fetches (`verify_checksum`, payload from
    /// `llmster.lmstudio.ai/download`). Same trust model as `curl … | sh`, minus
    /// the pipe: we still persist to a temp file and run it via /bin/sh rather
    /// than streaming the download into a shell.
    func install() async {
        // Re-entrancy guard: ignore a second tap while an install is in
        // flight. Don't rely on the view swapping out the button.
        if case .installing = state { return }
        warning = nil
        state = .installing(0)
        do {
            let scriptData = try await downloadInstallScript()

            // Persist the downloaded script to a temp file and run it via
            // /bin/sh. We never pipe the download into a shell.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("jot-lmstudio-install-\(UUID().uuidString).sh")
            try scriptData.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            state = .installing(0)
            // NOTE: we deliberately do NOT set LMS_PRINT_QUIET here. Quiet mode
            // makes install.sh run curl as `-s` (zero progress output), which is
            // why the install bar had nothing to show and was indeterminate.
            // Verbose mode emits curl's `--progress-bar` (a single ~580 MB file,
            // so the percentage is monotonic) which we parse into a real bar.
            // The extra console_log lines are harmless — `parseProgressFraction`
            // ignores any line without a trailing percentage.
            let result = try await runProcess(
                executable: "/bin/sh",
                arguments: [tmp.path],
                environment: [
                    "LMS_NO_MODIFY_PATH": "1",
                ],
                timeout: Self.installTimeoutSeconds,
                onProgress: { [weak self] line in
                    guard let fraction = Self.parseProgressFraction(from: line) else { return }
                    Task { @MainActor in self?.state = .installing(fraction) }
                }
            )
            guard result.exitCode == 0 else {
                state = .error("LM Studio install failed (exit \(result.exitCode)). Check that you have a network connection and try again.")
                return
            }
            // Re-detect from the filesystem / server.
            await detectState()
        } catch let error as ProcessError {
            state = .error(Self.message(for: error, action: "install"))
        } catch {
            state = .error("LM Studio install failed: \(error.localizedDescription)")
        }
    }

    private func downloadInstallScript() async throws -> Data {
        guard let url = URL(string: Self.installShURL) else {
            throw ProcessError.launchFailed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw ProcessError.nonZeroExit(-1)
        }
        return data
    }

    // MARK: - downloadModel() — ONE user gesture, after readyNoModel

    /// Pulls the recommended model, applies the no-think patch, ensures the
    /// server is running, resolves + persists the served id, and verifies
    /// thinking is off. Button-driven only. `config` is the live
    /// `LLMConfiguration` so the served id is persisted for `.lmStudio`
    /// BEFORE the provider can be selected (design F3 — otherwise requests
    /// would fire with `model: ""`).
    func downloadModel(config: LLMConfiguration) async {
        // Re-entrancy guard: ignore a second tap while a pull is in flight.
        if case .downloadingModel = state { return }
        warning = nil
        guard Self.freeDiskGB() >= Self.diskFloorGB else {
            state = .error("Need about \(Int(Self.diskFloorGB)) GB of free disk to download Qwen 3.5 9B (~6 GB). Free up some space and try again.")
            return
        }
        state = .downloadingModel(0)
        // Drive the bar from on-disk bytes (monotonic, format-independent)
        // rather than `lms get`'s per-shard CLI percentages. A cached model
        // makes `lms get` return ~instantly; the poller then reads the full
        // size once and the bar jumps to ~0.99 before we move to `.loadingModel`.
        let downloadDir = modelDownloadDirectory
        let totalBytes = Self.expectedModelBytes
        let progressPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // File I/O off the main actor; state mutation back on it.
                let bytes = await Task.detached { Self.directorySizeBytes(at: downloadDir) }.value
                let fraction = min(max(Double(bytes) / Double(totalBytes), 0), 0.99)
                guard let self, case .downloadingModel = self.state else { return }
                self.state = .downloadingModel(fraction)
                try? await Task.sleep(for: .seconds(0.7))
            }
        }
        defer { progressPoller.cancel() }
        do {
            let pull = try await runProcess(
                executable: lmsPath.path,
                arguments: ["get", Self.modelAlias, "--mlx", "-y"],
                environment: ["LMS_PRINT_QUIET": "1"],
                timeout: Self.downloadTimeoutSeconds,
                onProgress: { _ in }
            )
            progressPoller.cancel()
            guard pull.exitCode == 0 else {
                state = .error("Model download failed (exit \(pull.exitCode)). Try again.")
                return
            }

            // Download done — the remaining load/serve/resolve work is quick and
            // is NOT a download, so stop showing the "Downloading…" bar.
            state = .loadingModel
            applyNoThinkPatch()
            try await ensureServerRunning()

            // Explicitly LOAD the freshly-pulled model. LM Studio JIT-loads,
            // so a just-`lms get`-pulled model often doesn't appear in
            // /v1/models until loaded — and the GUI may already be serving a
            // DIFFERENT model on :1234. Loading by alias forces our model to
            // be the one we then resolve + persist. Non-fatal if the load
            // command errors (some `lms` builds auto-load on first request);
            // the poll below is the real gate.
            _ = try? await runProcess(
                executable: lmsPath.path,
                arguments: ["load", Self.modelAlias, "-y"],
                environment: ["LMS_PRINT_QUIET": "1"],
                timeout: Self.downloadTimeoutSeconds,
                onProgress: { _ in }
            )

            // Resolve the served id (F3) — never the alias. Poll /v1/models
            // for a POSITIVE qwen3.5-9b match; the model can take a moment to
            // register after load. NO blind "first served id" fallback — we
            // must never pin a different model's id under `.lmStudio`.
            guard let servedModel = await pollForRecommendedModelID() else {
                state = .error("Couldn't confirm the model loaded. Open LM Studio and make sure Qwen 3.5 9B is available, then try again.")
                return
            }
            // CRITICAL (F3): persist BEFORE the provider can be selected.
            config.setModel(servedModel, for: .lmStudio)

            await verifyThinkingOff(model: servedModel)
            state = .configured
        } catch let error as ProcessError {
            state = .error(Self.message(for: error, action: "model download"))
        } catch {
            state = .error("Model download failed: \(error.localizedDescription)")
        }
    }

    /// Starts `lms server start --port <port>` if the server isn't already
    /// answering on localhost. Idempotent — does nothing if already up.
    private func ensureServerRunning() async throws {
        let servedModels = await servedModelIDs()
        let reachable = await serverReachable()
        if !servedModels.isEmpty || reachable {
            return
        }
        _ = try await runProcess(
            executable: lmsPath.path,
            arguments: ["server", "start", "--port", String(Self.serverPort)],
            environment: ["LMS_PRINT_QUIET": "1"],
            timeout: Self.quickCommandTimeoutSeconds,
            onProgress: { _ in }
        )
        // Give the server a brief moment to bind before callers poll.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// Polls `/v1/models` for a positively-matched qwen3.5-9b served id,
    /// retrying a few times to absorb the registration lag right after a
    /// load. Returns the matched id, or nil if no qwen match appears. Never
    /// returns a non-qwen id (no blind fallback).
    private func pollForRecommendedModelID() async -> String? {
        for attempt in 0..<6 {
            if let match = (await servedModelIDs()).first(where: Self.looksLikeRecommendedModel) {
                return match
            }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return nil
    }

    private func serverReachable() async -> Bool {
        guard let url = URL(string: "\(serverBaseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            return false
        }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - No-think patch (primary mechanism, design #5/F5)

    private static let noThinkLine = "{%- set enable_thinking = false %}"

    /// Locates the recommended model's `chat_template.jinja` and, if its
    /// first line isn't already the no-think directive, prepends it.
    /// Idempotent (first-line check). Exposed so the UI can re-apply it
    /// when the user selects `.lmStudio` or on first readiness — NOT
    /// blindly every launch (F7).
    func applyNoThinkPatch() {
        guard let templateURL = locateChatTemplate() else { return }
        guard let existing = try? String(contentsOf: templateURL, encoding: .utf8) else { return }

        // Idempotent: skip if the first non-empty line is already the
        // directive. Drift-detect via the first line; don't double-prepend.
        let firstLine = existing
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        if firstLine == Self.noThinkLine {
            return
        }

        let patched = Self.noThinkLine + "\n" + existing
        // Skip silently if LM Studio holds the file mid-update — a failed
        // write is non-fatal; verifyThinkingOff() is the backstop.
        try? patched.write(to: templateURL, atomically: true, encoding: .utf8)
    }

    /// Walks `~/.lmstudio/models/**` for a `Qwen3.5-9B-*` directory holding
    /// a `chat_template.jinja`. The MLX layout nests the template under the
    /// quantized model folder.
    private func locateChatTemplate() -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == "chat_template.jinja" {
            let parents = url.pathComponents.map { $0.lowercased() }
            if parents.contains(where: { $0.contains("qwen3.5-9b") }) {
                return url
            }
        }
        return nil
    }

    // MARK: - verifyThinkingOff (design F10)

    /// Confirms on the live server that thinking is actually off: POSTs a
    /// tiny completion and checks `usage.completion_tokens_details
    /// .reasoning_tokens`. If nonzero, re-applies the patch + reloads the
    /// model once; if still nonzero, sets a non-fatal warning (never
    /// hard-fails).
    func verifyThinkingOff(model: String) async {
        let observed = await reasoningTokens(model: model)
        // -1 means the verification request itself failed (e.g. the server
        // is still warming). Treat as "couldn't verify" — do NOT trigger a
        // reload on a healthy-but-warming server; leave the warning nil.
        if observed < 0 {
            warning = nil
            return
        }
        if observed == 0 {
            warning = nil
            return
        }
        // observed > 0: thinking is genuinely on. Re-apply + reload once.
        applyNoThinkPatch()
        _ = try? await runProcess(
            executable: lmsPath.path,
            arguments: ["load", model, "-y"],
            environment: ["LMS_PRINT_QUIET": "1"],
            timeout: Self.quickCommandTimeoutSeconds,
            onProgress: { _ in }
        )
        if await reasoningTokens(model: model) > 0 {
            warning = "Set up, but the model still emitted reasoning tokens. Replies may include thinking text. Re-applying the no-think patch from Settings → AI may help."
        } else {
            warning = nil
        }
    }

    /// Returns `usage.completion_tokens_details.reasoning_tokens` from a
    /// minimal completion, or -1 if the request couldn't be made (treated
    /// as "couldn't verify" — not a thinking-on signal).
    private func reasoningTokens(model: String) async -> Int {
        guard let url = URL(string: "\(serverBaseURL)/chat/completions") else { return -1 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 32,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = root["usage"] as? [String: Any]
        else {
            return -1
        }
        if let details = usage["completion_tokens_details"] as? [String: Any],
           let reasoning = details["reasoning_tokens"] as? Int {
            return reasoning
        }
        // No reasoning-token field reported → treat as 0 (thinking off).
        return 0
    }

    // MARK: - Progress parsing

    /// Best-effort extraction of a 0…1 progress fraction from a CLI output line.
    /// Handles BOTH integer (`42%`) and decimal (`42.8%`) percentages — curl's
    /// `--progress-bar` prints decimals, and a naive `(\d{1,3})%` would match the
    /// single digit before `%` (`42.8%` → `8%`). Returns nil when no percentage
    /// is present.
    static func parseProgressFraction(from line: String) -> Double? {
        guard let range = line.range(
            of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression
        ) else {
            return nil
        }
        let token = line[range].dropLast()  // strip the '%'
        guard let value = Double(token) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }

    // MARK: - Process shell-out (mirrors Flavor1Session)

    enum ProcessError: Error {
        case launchFailed
        case timedOut
        case nonZeroExit(Int32)
    }

    struct ProcessResult {
        let exitCode: Int32
        let standardOutput: String
    }

    private static func message(for error: ProcessError, action: String) -> String {
        switch error {
        case .timedOut:
            return "LM Studio \(action) timed out. Check your connection and try again."
        case .launchFailed, .nonZeroExit:
            return "LM Studio \(action) failed. Check logs and try again."
        }
    }

    /// Runs a subprocess with a watchdog timeout and a SIGTERM-the-process-
    /// group kill on timeout — the same robustness pattern as
    /// `Flavor1Session.runGimmeAICreds()`. `onProgress` is invoked with
    /// each line of combined stdout/stderr as it streams (used to drive the
    /// install / download progress bars). The continuation is resumed
    /// exactly once via `ResumeGuard`, whichever of {termination handler,
    /// watchdog} wins the race.
    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        onProgress: @escaping (String) -> Void
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Stream lines for progress. The accumulator captures full stdout
        // for callers that parse the final output (e.g. served-id resolve).
        let accumulator = OutputAccumulator()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            accumulator.append(chunk)
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                onProgress(String(line))
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessError.launchFailed
        }

        // Own process group so the watchdog can SIGTERM the whole tree
        // (install.sh spawns curl/tar; lms spawns the daemon).
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let didResume = ResumeGuard()

                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                watchdog.schedule(deadline: .now() + timeout)
                watchdog.setEventHandler {
                    guard !didResume.isResumed else { return }
                    if process.isRunning {
                        // SIGTERM-only (no SIGKILL escalation) — matches the
                        // Flavor1Session precedent; a wedged child gets a clean
                        // termination signal to the whole group, not a hard kill.
                        _ = kill(-pid, SIGTERM)
                    }
                    if didResume.markResumed() {
                        outputPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: ProcessError.timedOut)
                    }
                }
                watchdog.resume()

                process.terminationHandler = { proc in
                    watchdog.cancel()
                    guard didResume.markResumed() else { return }
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            standardOutput: accumulator.snapshot()
                        )
                    )
                }
            }
        } onCancel: {
            // Task cancellation isn't a user-initiated kill. The watchdog
            // still protects against a runaway process; let an in-flight
            // download run rather than orphaning a half-pulled model.
        }
    }
}

// MARK: - Helpers

/// Thread-safe accumulator for streamed subprocess output. The pipe's
/// `readabilityHandler` fires on an arbitrary queue, so guard with a lock.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// Tiny guard making the termination handler + watchdog race-safe — the
/// same primitive `Flavor1Session` uses. Whichever fires first resumes the
/// continuation; the other sees `isResumed == true` and bails.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _isResumed = false

    var isResumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isResumed
    }

    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _isResumed { return false }
        _isResumed = true
        return true
    }
}
