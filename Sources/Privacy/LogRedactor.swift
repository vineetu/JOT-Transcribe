import Foundation

public enum LogRedactor {
    public static func redact(_ text: String, using results: [PrivacyCheckResult]) -> (text: String, summary: String) {
        let findings = results.flatMap(\.findings).sorted { $0.range.lowerBound > $1.range.lowerBound }
        var output = text

        for finding in findings {
            let label: String
            switch finding.kind {
            case .apiKeys:
                label = "[REDACTED API KEY]"
            case .customEndpoint:
                label = "[REDACTED CUSTOM ENDPOINT]"
            case .transcripts:
                label = "[REDACTED TRANSCRIPT]"
            case .homeFolder:
                label = "/Users/<redacted>/"
            case .credentialURLs:
                label = "[REDACTED URL CREDENTIAL]"
            }
            output.replaceSubrange(finding.range, with: label)
        }

        let counts = Dictionary(grouping: findings, by: \.kind).mapValues(\.count)
        let summaryParts = PrivacyCheckKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(kind.rawValue)"
        }

        let header = """
        # Jot log - redacted by scanner v1
        # Categories removed: \(summaryParts.isEmpty ? "none" : summaryParts.joined(separator: ", "))
        # ---

        """

        return (header + output, summaryParts.joined(separator: ", "))
    }
}
