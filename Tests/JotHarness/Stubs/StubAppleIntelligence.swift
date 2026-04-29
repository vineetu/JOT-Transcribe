import Foundation
import os
@testable import Jot

/// Harness conformer for `AppleIntelligenceClienting`. Returns canned
/// strings from a FIFO queue for `transform(...)` / `articulate(...)`,
/// with a controllable `isAvailable` flag and a `blocksUntilCancelled`
/// mode for the I1 cancel-doesn't-cancel regression.
///
/// **`isAvailable` is `nonisolated` per the protocol.** A `Mutex`-guarded
/// flag would be cleaner but `os.Mutex` requires macOS 26 — we use
/// `OSAllocatedUnfairLock` which has been available since macOS 13. The
/// flag is set once at init and effectively read-only thereafter; the
/// lock is belt-and-suspenders for strict-concurrency.
///
/// **`blocksUntilCancelled` mode:** when the seed selects this, the
/// next `articulate(...)` call awaits a continuation that's only
/// resumed when the in-flight task is cancelled. This is the only way
/// the I1 regression can drive `condensationTaskWasCancelled == true`
/// — every other seed completes synchronously.
actor StubAppleIntelligence: AppleIntelligenceClienting {
    private let availabilityFlag = OSAllocatedUnfairLock<Bool>(initialState: true)

    private var transformResponses: [String] = []
    private var articulateResponses: [String] = []
    private var blocksOnArticulate: Bool = false

    /// `true` after a `blocksUntilCancelled` articulate call observed
    /// `Task.isCancelled` before completing. Read by the I1 flow
    /// method to populate `AskJotResult.condensationTaskWasCancelled`.
    private(set) var lastArticulateWasCancelled: Bool = false

    init(seed: AppleIntelligenceSeed = .stub) {
        switch seed {
        case .stub:
            availabilityFlag.withLock { $0 = true }
        case .unavailable:
            availabilityFlag.withLock { $0 = false }
        case .blocksUntilCancelled:
            availabilityFlag.withLock { $0 = true }
            self.blocksOnArticulate = true
        }
    }

    /// Enqueue a canned response for the next `transform(...)` call.
    func enqueueTransform(_ response: String) {
        transformResponses.append(response)
    }

    /// Enqueue a canned response for the next `articulate(...)` call.
    func enqueueArticulate(_ response: String) {
        articulateResponses.append(response)
    }

    // MARK: - AppleIntelligenceClienting

    nonisolated var isAvailable: Bool {
        availabilityFlag.withLock { $0 }
    }

    func transform(transcript: String, instruction: String) async throws -> String {
        guard isAvailable else { throw LLMError.appleIntelligenceUnavailable }
        guard !transformResponses.isEmpty else {
            // Default echo so flow tests that don't care about cleanup
            // content still get a plausible string back.
            return transcript
        }
        return transformResponses.removeFirst()
    }

    func articulate(
        selectedText: String,
        instruction: String,
        branchPrompt: String
    ) async throws -> String {
        guard isAvailable else { throw LLMError.appleIntelligenceUnavailable }

        if blocksOnArticulate {
            // Suspend until cancelled. Setting the flag *before*
            // throwing CancellationError gives the harness a stable
            // signal to read in `AskJotResult.condensationTaskWasCancelled`.
            await withTaskCancellationHandler {
                await suspendForever()
            } onCancel: {
                Task { await self.markCancelled() }
            }
            throw CancellationError()
        }

        guard !articulateResponses.isEmpty else { return selectedText }
        return articulateResponses.removeFirst()
    }

    /// Stub `AIChatRequest` streaming. Yields each enqueued articulate
    /// response (one per turn) split into coarse chunks so consumers
    /// observe the `for try await` loop. No tool-calling — the stub
    /// surface ignores `request.showFeatureTool`.
    nonisolated func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard self.isAvailable else {
                    continuation.finish(throwing: LLMError.appleIntelligenceUnavailable)
                    return
                }
                let response = await self.dequeueChatResponse(prompt: request.messages)
                continuation.yield(response)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func dequeueChatResponse(prompt: [AIChatMessage]) -> String {
        if !articulateResponses.isEmpty {
            return articulateResponses.removeFirst()
        }
        // Default echo of the last user prompt so flow tests that
        // don't enqueue a chat response still get something readable.
        return prompt.last(where: { $0.role == .user })?.content ?? ""
    }

    // MARK: - Helpers

    private func suspendForever() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Intentionally never resumed — the cancellation handler
            // throws CancellationError out of `articulate(...)`.
        }
    }

    private func markCancelled() {
        lastArticulateWasCancelled = true
    }
}
