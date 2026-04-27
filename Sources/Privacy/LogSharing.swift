import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
public enum LogSharing {
    /// Phase 3 F4: `modelIdentifier` is threaded in from the caller
    /// (which has access to the `TranscriberHolder` via env injection),
    /// replacing the prior `UserDefaults.standard.string(forKey:)` read
    /// off the cross-suite-shared `jot.defaultModelID` key.
    public static func emailBody(recordingsCount: Int, modelIdentifier: String) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let provider = UserDefaults.standard.string(forKey: "jot.llm.provider") ?? "unknown"
        let model = modelIdentifier
        let cleanup = UserDefaults.standard.bool(forKey: "jot.transformEnabled") ? "yes" : "no"
        return """
        [Paste the log below this line with ⌘V]

        ---
        App details (non-private):
        • Jot version: \(v) (build \(b))
        • macOS: \(os)
        • LLM provider: \(provider)
        • Transcription model: \(model)
        • Auto-correct enabled: \(cleanup)
        • Recordings count: \(recordingsCount)

        Describe what went wrong here:


        """
    }

    /// Phase 4 patch round 4: `pasteboard` seam threaded so the bug-report
    /// flow routes through `Pasteboarding` (production: `LivePasteboard`;
    /// harness: `StubPasteboard`) instead of `NSPasteboard.general` directly.
    static func openEmail(
        logText: String,
        recordingsCount: Int,
        modelIdentifier: String,
        pasteboard: any Pasteboarding
    ) {
        _ = pasteboard.write(logText)

        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let subject = "Jot \(v) — bug report"
        let body = emailBody(recordingsCount: recordingsCount, modelIdentifier: modelIdentifier)
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "jottranscribe@gmail.com"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Phase 4 patch round 4: `pasteboard` seam threaded so the "Copy log"
    /// affordance routes through the seam instead of `NSPasteboard.general`.
    static func copyToClipboard(_ text: String, pasteboard: any Pasteboarding) {
        _ = pasteboard.write(text)
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func writeTemp(_ text: String, prefix: String = "jot-redacted") -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let ts = Int(Date().timeIntervalSince1970)
        let url = tempDir.appendingPathComponent("\(prefix)-\(ts).log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
