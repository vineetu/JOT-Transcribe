// Sources/AskJot/Cloud/CloudChatStream.swift — canonical shared protocol for cloud chat streaming. Per-provider files conform. Unification point from docs/plans/llm-unification-deferred.md; see that doc for the long-term AIService merge.

import Foundation

protocol CloudChatStream {
    /// Streams a chat completion. When `showFeatureTool` is `nil`, the
    /// conformer MUST omit the `tools` array from the request body
    /// entirely and skip the tool-call loop (text-only streaming) — the
    /// path used by transcript Q&A, which has no help-navigation tool.
    /// When non-nil, behavior is unchanged: the `showFeature` tool is
    /// advertised and the tool-call loop runs (the Help-bot path).
    func streamChat(
        messages: [CloudChatMessage],
        systemInstructions: String,
        showFeatureTool: ((String) async -> String)?,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error>
}

struct CloudChatMessage: Equatable, Sendable {
    let role: CloudChatRole
    let content: String
}

enum CloudChatRole: Equatable, Sendable {
    case user
    case assistant
    case tool(callId: String, name: String)
}
