import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Actor wrapping FluidAudio's `StreamingNemotronAsrManager` (Nemotron
/// 0.6B, 1120 ms chunks). This intentionally mirrors
/// `StreamingTranscriber` without sharing a protocol abstraction: EOU and
/// Nemotron have similar control flow but different SDK types and model
/// cache layouts.
final actor NemotronStreamingTranscriber {

    private var manager: StreamingNemotronAsrManager?
    private let bundleDirectory: URL
    private var activeGeneration: UInt64?
    private let continuationBox = NemotronContinuationBox()
    private var consumerTask: Task<Void, Never>?

    init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
    }

    var isReady: Bool { manager != nil }

    func ensureLoaded() async throws {
        if manager != nil { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let mgr = StreamingNemotronAsrManager(
            configuration: config,
            requestedChunkSize: .ms1120
        )
        try await mgr.loadModels(from: bundleDirectory)
        manager = mgr
    }

    func start(
        generation: UInt64,
        onPartial: @escaping @Sendable (String, UInt64) -> Void
    ) {
        activeGeneration = generation

        var holder: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { c in
            holder = c
        }
        continuationBox.set(holder)

        consumerTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureLoaded()
            } catch {
                await ErrorLog.shared.error(
                    component: "NemotronStreamingTranscriber",
                    message: "ensureLoaded failed in consumer (skipping partials)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                return
            }
            guard let mgr = await self.activeManager() else { return }

            await mgr.reset()
            await mgr.setPartialCallback { partial in
                onPartial(partial, generation)
            }

            for await samples in stream {
                if Task.isCancelled { break }
                guard !samples.isEmpty,
                      let buffer = Self.makeBuffer(samples)
                else { continue }
                do {
                    _ = try await mgr.process(audioBuffer: buffer)
                } catch {
                    await ErrorLog.shared.error(
                        component: "NemotronStreamingTranscriber",
                        message: "process failed",
                        context: ["error": ErrorLog.redactedAppleError(error)]
                    )
                }
            }
        }
    }

    private func activeManager() -> StreamingNemotronAsrManager? { manager }

    nonisolated func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuationBox.yield(samples)
    }

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    func finish() async throws -> String {
        continuationBox.finish()
        await drainConsumerWithTimeout(seconds: 2)
        defer {
            activeGeneration = nil
        }
        guard activeGeneration != nil, let manager else {
            throw TranscriberError.modelNotLoaded
        }
        return try await manager.finish()
    }

    /// One-shot fallback for paths that do not have a live recording session
    /// already feeding this actor (for example Library re-transcribe). The
    /// samples are passed through Nemotron in one buffer and flushed with
    /// `finish()`, matching FluidAudio's streaming API without inventing a
    /// separate batch abstraction.
    func transcribeOneShot(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        guard let manager else {
            throw TranscriberError.modelNotLoaded
        }
        await manager.reset()
        guard let buffer = Self.makeBuffer(samples) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.NemotronStreamingTranscriber", code: -1)
            )
        }
        _ = try await manager.process(audioBuffer: buffer)
        return try await manager.finish()
    }

    func cancel() async {
        continuationBox.finish()
        consumerTask?.cancel()
        consumerTask = nil
        activeGeneration = nil
        if let mgr = manager {
            Task.detached { await mgr.reset() }
        }
    }

    private func drainConsumerWithTimeout(seconds: TimeInterval) async {
        guard let task = consumerTask else { return }
        consumerTask = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        if !task.isCancelled {
            task.cancel()
        }
    }
}

private final class NemotronContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?

    func set(_ c: AsyncStream<[Float]>.Continuation?) {
        lock.lock()
        let prev = continuation
        continuation = c
        lock.unlock()
        prev?.finish()
    }

    func yield(_ samples: [Float]) {
        lock.lock()
        let c = continuation
        lock.unlock()
        c?.yield(samples)
    }

    func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.finish()
    }
}
