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
public final class LogScanner: ObservableObject {
    @Published public private(set) var visibleResults: [PrivacyCheckResult] = []
    @Published public private(set) var isComplete: Bool = false
    @Published public private(set) var stats: String = ""
    @Published public private(set) var worst: LogWorstState = .clean

    private var allResults: [PrivacyCheckResult] = []
    private let modelContext: ModelContext?

    public init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    public func run() async {
        let start = Date()
        let logURL = ErrorLog.logFileURL
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let byteSize = contents.utf8.count

        let key = LLMConfiguration.shared.apiKey
        let baseURL = UserDefaults.standard.string(forKey: "jot.llm.baseURL")
        let transcripts = fetchTranscripts()
        let home = NSHomeDirectory()

        let results = PrivacyScanner.scan(
            logContents: contents,
            currentAPIKey: key,
            customBaseURL: baseURL,
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

    public var currentContents: String {
        (try? String(contentsOf: ErrorLog.logFileURL, encoding: .utf8)) ?? ""
    }

    public func redactedContents() -> String {
        let (redacted, _) = LogRedactor.redact(currentContents, using: allResults)
        return redacted
    }
}
