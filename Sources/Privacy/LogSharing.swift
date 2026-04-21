import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
public enum LogSharing {
    public static func emailBody(recordingsCount: Int) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let provider = UserDefaults.standard.string(forKey: "jot.llm.provider") ?? "unknown"
        let model = UserDefaults.standard.string(forKey: "jot.defaultModelID") ?? "unknown"
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

    public static func openEmail(logText: String, recordingsCount: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(logText, forType: .string)

        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let subject = "Jot \(v) — bug report"
        let body = emailBody(recordingsCount: recordingsCount)
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

    public static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
