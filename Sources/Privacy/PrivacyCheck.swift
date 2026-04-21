import Foundation

public enum PrivacyCheckKind: String, CaseIterable, Identifiable, Sendable {
    case apiKeys
    case customEndpoint
    case transcripts
    case homeFolder
    case credentialURLs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apiKeys: return "Looking for your API key"
        case .customEndpoint: return "Looking for your custom endpoint"
        case .transcripts: return "Looking for your transcripts"
        case .homeFolder: return "Looking for your home folder path"
        case .credentialURLs: return "Looking for credentials in URLs"
        }
    }
}

public struct PrivacyFinding: Identifiable, Sendable {
    public let id = UUID()
    public let kind: PrivacyCheckKind
    public let snippet: String
    public let range: Range<String.Index>

    public init(kind: PrivacyCheckKind, snippet: String, range: Range<String.Index>) {
        self.kind = kind
        self.snippet = snippet
        self.range = range
    }
}

public struct PrivacyCheckResult: Sendable {
    public let kind: PrivacyCheckKind
    public let findings: [PrivacyFinding]

    public var isClean: Bool { findings.isEmpty }

    public init(kind: PrivacyCheckKind, findings: [PrivacyFinding]) {
        self.kind = kind
        self.findings = findings
    }
}

public enum PrivacyScanner {
    public static func scan(
        logContents: String,
        currentAPIKey: String?,
        customBaseURL: String?,
        knownTranscripts: [String],
        homeDirectory: String
    ) -> [PrivacyCheckResult] {
        var results: [PrivacyCheckResult] = []
        results.append(scanAPIKeys(in: logContents, currentKey: currentAPIKey))
        results.append(scanCustomEndpoint(in: logContents, url: customBaseURL))
        results.append(scanTranscripts(in: logContents, transcripts: knownTranscripts))
        results.append(scanHomeFolder(in: logContents, home: homeDirectory))
        results.append(scanCredentialURLs(in: logContents))
        return results
    }

    private static let apiKeyPatterns: [(String, PrivacyCheckKind)] = [
        ("sk-proj-[A-Za-z0-9_-]{20,}", .apiKeys),
        ("sk-ant-(?:api03-)?[A-Za-z0-9_-]{20,}", .apiKeys),
        ("\\bsk-[A-Za-z0-9]{32,}\\b", .apiKeys),
        ("AIza[A-Za-z0-9_-]{35}", .apiKeys),
        ("-----BEGIN [A-Z ]*PRIVATE KEY-----", .apiKeys)
    ]

    private static func scanAPIKeys(in text: String, currentKey: String?) -> PrivacyCheckResult {
        var findings: [PrivacyFinding] = []
        if let key = currentKey, !key.isEmpty {
            findings.append(contentsOf: exactMatches(of: key, in: text, kind: .apiKeys, label: "[API KEY]"))
        }
        for (pattern, kind) in apiKeyPatterns {
            findings.append(contentsOf: regexMatches(pattern: pattern, in: text, kind: kind, label: "[API KEY]"))
        }
        return PrivacyCheckResult(kind: .apiKeys, findings: findings)
    }

    private static func scanCustomEndpoint(in text: String, url: String?) -> PrivacyCheckResult {
        guard let url, !url.isEmpty else {
            return PrivacyCheckResult(kind: .customEndpoint, findings: [])
        }
        return PrivacyCheckResult(
            kind: .customEndpoint,
            findings: exactMatches(of: url, in: text, kind: .customEndpoint, label: "[CUSTOM ENDPOINT]")
        )
    }

    private static func scanTranscripts(in text: String, transcripts: [String]) -> PrivacyCheckResult {
        var findings: [PrivacyFinding] = []
        let sorted = transcripts.filter { $0.count >= 10 }.sorted { $0.count > $1.count }
        for transcript in sorted {
            findings.append(
                contentsOf: exactMatches(
                    of: transcript,
                    in: text,
                    kind: .transcripts,
                    label: "[TRANSCRIPT - \(transcript.count) chars]"
                )
            )
        }
        return PrivacyCheckResult(kind: .transcripts, findings: findings)
    }

    private static func scanHomeFolder(in text: String, home: String) -> PrivacyCheckResult {
        var findings = exactMatches(of: home, in: text, kind: .homeFolder, label: "[HOME PATH]")
        findings.append(contentsOf: regexMatches(pattern: "/Users/[^/\\s\"]+/", in: text, kind: .homeFolder, label: "[HOME PATH]"))
        return PrivacyCheckResult(kind: .homeFolder, findings: findings)
    }

    private static func scanCredentialURLs(in text: String) -> PrivacyCheckResult {
        let pattern = "https?://\\S*[?&](?:key|api[_-]?key|token|access_token|authorization)=\\S+"
        return PrivacyCheckResult(
            kind: .credentialURLs,
            findings: regexMatches(pattern: pattern, in: text, kind: .credentialURLs, label: "[URL CREDENTIAL]")
        )
    }

    private static func exactMatches(
        of needle: String,
        in haystack: String,
        kind: PrivacyCheckKind,
        label: String
    ) -> [PrivacyFinding] {
        guard !needle.isEmpty else { return [] }
        var findings: [PrivacyFinding] = []
        var searchStart = haystack.startIndex

        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            findings.append(
                PrivacyFinding(
                    kind: kind,
                    snippet: contextSnippet(haystack, around: range, label: label),
                    range: range
                )
            )
            searchStart = range.upperBound
        }

        return findings
    }

    private static func regexMatches(
        pattern: String,
        in text: String,
        kind: PrivacyCheckKind,
        label: String
    ) -> [PrivacyFinding] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return PrivacyFinding(
                kind: kind,
                snippet: contextSnippet(text, around: range, label: label),
                range: range
            )
        }
    }

    private static func contextSnippet(_ text: String, around range: Range<String.Index>, label: String) -> String {
        let padBefore = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let padAfter = text.index(range.upperBound, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
        let before = String(text[padBefore..<range.lowerBound])
        let after = String(text[range.upperBound..<padAfter])
        return "...\(before)\(label)\(after)..."
    }
}
