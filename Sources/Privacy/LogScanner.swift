import Foundation
import SwiftData
import SwiftUI

public enum LogWorstState {
    case clean
    case yellow
    case red
    var isClean: Bool { if case .clean = self { return true }; return false }
    var isRed: Bool { if case .red = self { return true }; return false }
}

@MainActor
final class LogScanner: ObservableObject {
    @Published private(set) var visibleResults: [PrivacyCheckResult] = []
    @Published private(set) var isComplete: Bool = false
    @Published private(set) var stats: String = ""
    @Published private(set) var worst: LogWorstState = .clean

    private var allResults: [PrivacyCheckResult] = []
    private let modelContext: ModelContext?
    private let llmConfiguration: LLMConfiguration

    init(modelContext: ModelContext? = nil, llmConfiguration: LLMConfiguration) {
        self.modelContext = modelContext
        self.llmConfiguration = llmConfiguration
    }

    func run() async {
        let start = Date()
        let logURL = ErrorLog.logFileURL
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let byteSize = contents.utf8.count

        let config = llmConfiguration
        let keys = LLMConfiguration.bucketedProviders.map { config.apiKey(for: $0) }
        let baseURLs = LLMConfiguration.bucketedProviders.map { config.baseURL(for: $0) }
        let transcripts = fetchTranscripts()
        let home = NSHomeDirectory()

        let results = PrivacyScanner.scan(
            logContents: contents,
            currentAPIKeys: keys,
            customBaseURLs: baseURLs,
            knownTranscripts: transcripts,
            homeDirectory: home
        )
        allResults = results

        // Sequentially reveal each result with 3 second delay between reveals
        for r in results {
            withAnimation { visibleResults.append(r) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // Compute worst state
        let red: Set<PrivacyCheckKind> = [.apiKeys, .credentialURLs]
        var state: LogWorstState = .clean
        for r in results where !r.isClean {
            if red.contains(r.kind) { state = .red; break }
            state = .yellow
        }
        worst = state

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        stats = "Scanned \(byteSize / 1024) KB in \(ms) ms"
        isComplete = true
    }

    private func fetchTranscripts() -> [String] {
        guard let ctx = modelContext else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date.distantPast
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.createdAt >= cutoff }
        )
        descriptor.fetchLimit = 2000
        guard let recordings = try? ctx.fetch(descriptor) else { return [] }
        var all: [String] = []
        for r in recordings {
            if r.transcript.count >= 10 { all.append(r.transcript) }
            if r.rawTranscript.count >= 10 && r.rawTranscript != r.transcript { all.append(r.rawTranscript) }
        }
        return all
    }

    var currentContents: String {
        (try? String(contentsOf: ErrorLog.logFileURL, encoding: .utf8)) ?? ""
    }

    func redactedContents() -> String {
        let (redacted, _) = LogRedactor.redact(currentContents, using: allResults)
        return redacted
    }
}
