import Foundation
import Testing
@testable import Jot

/// All-or-nothing cache invariant tests for streaming model options.
///
/// The legacy streaming option pairs TDT v2 (batch) with EOU 120M
/// (streaming). The default streaming option pairs TDT v3 (batch) with
/// Nemotron. Each composite cache must return `true` only when both bundles
/// are fully present.
///
/// Tests stage filesystem layouts under a temp `ModelCache` root so
/// the dev/CI machine's real `~/Library/Application Support/Jot/`
/// tree is never touched. The "fully present" stagings reproduce
/// FluidAudio's exact required-files set (TDT v2 via
/// `AsrModels.modelsExist`, EOU via `ModelNames.ParakeetEOU.requiredModels`)
/// rather than relying on real downloads — the cache check is what's
/// under test, not the SDK loader.
@MainActor
@Suite(.serialized)
struct ModelCacheStreamingTests {

    // MARK: - Test infrastructure

    private static func freshTempCache() throws -> ModelCache {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("jot-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ModelCache(root: root)
    }

    private static func cleanup(_ cache: ModelCache) {
        try? FileManager.default.removeItem(at: cache.root)
    }

    /// FluidAudio's TDT-v2 batch loader requires Preprocessor + Encoder
    /// + Decoder + JointDecision .mlmodelc directories plus
    /// `parakeet_vocab.json`.
    ///
    /// `AsrModels.modelsExist` derives the on-disk repo path via
    /// `directory.deletingLastPathComponent().appendingPathComponent(version.repo.folderName)`
    /// — for `.v2` that resolves to `<root>/parakeet-tdt-0.6b-v2`
    /// (FluidAudio strips the `-coreml` suffix in `Repo.folderName`).
    /// `ModelCache.cacheURL(for:)` returns the placeholder
    /// `<root>/parakeet-tdt-0.6b-v2-coreml` we hand to FluidAudio's
    /// downloader, but the SDK then strips back and re-derives the
    /// real path. Tests must stage at the *real* path or
    /// `AsrModels.modelsExist` will report false even with every
    /// required file present. The helper keeps the staging in
    /// lockstep with FluidAudio's derivation rule.
    private static func batchStagingURL(_ cache: ModelCache) -> URL {
        // Hard-coded for v2 — keeping it explicit so the next SDK
        // rename surfaces as a focused test failure rather than a
        // mysterious "isCached returns false" symptom.
        cache.root.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    private static func batchV3Int4StagingURL(_ cache: ModelCache) -> URL {
        cache.root
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml-int4", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    private static func batchV3DefaultStagingURL(_ cache: ModelCache) -> URL {
        cache.root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    private static func stageBatchV2(_ cache: ModelCache, id: ParakeetModelID) {
        let dir = batchStagingURL(cache)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecision.mlmodelc",
            "parakeet_vocab.json",
        ]
        for name in files {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: path.path, contents: Data("{}".utf8))
            }
        }
    }

    private static func stageStreamingEOU(_ cache: ModelCache, id: ParakeetModelID) {
        guard let dir = cache.streamingPartialCacheURL(for: id) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "streaming_encoder.mlmodelc",
            "decoder.mlmodelc",
            "joint_decision.mlmodelc",
            "vocab.json",
        ]
        for name in files {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: path.path, contents: Data("{}".utf8))
            }
        }
    }

    private static func stageBatchV3Int4(_ cache: ModelCache) {
        let dir = batchV3Int4StagingURL(cache)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "Preprocessor.mlmodelc",
            "EncoderInt4.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
            "parakeet_vocab.json",
        ]
        for name in files {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: path.path, contents: Data("{}".utf8))
            }
        }
    }

    private static func stageBatchV3Default(_ cache: ModelCache) {
        let dir = batchV3DefaultStagingURL(cache)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
            "parakeet_vocab.json",
        ]
        for name in files {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: path.path, contents: Data("{}".utf8))
            }
        }
    }

    private static func stageStreamingNemotron(_ cache: ModelCache, id: ParakeetModelID) {
        guard let dir = cache.streamingPartialCacheURL(for: id) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "preprocessor.mlmodelc",
            "encoder/encoder_int8.mlmodelc",
            "decoder.mlmodelc",
            "joint.mlmodelc",
            "tokenizer.json",
            "metadata.json",
        ]
        for name in files {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: path.path, contents: Data("{}".utf8))
            }
        }
    }

    // MARK: - Scenarios

    /// Empty cache → not cached.
    @Test func emptyCacheReturnsFalse() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
    }

    /// Both bundles fully staged → cached. Positive control for the
    /// other tests in this suite — without this, every "false" assertion
    /// could pass for the wrong reason (e.g. a typo in stageBatchV2
    /// would never produce a "fully present" rig and the negative
    /// tests would all trivially succeed).
    @Test func bothBundlesPresentReturnsTrue() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)
        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == true)
    }

    /// Only the batch bundle staged → not cached. The streaming option
    /// requires both halves; a partial cache must NOT report success
    /// because the user would see "Installed" but the actual streaming
    /// load would fail at runtime.
    @Test func batchOnlyReturnsFalse() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
    }

    /// Only the streaming bundle staged → not cached. Symmetric to the
    /// batch-only case — neither bundle alone is enough.
    @Test func streamingOnlyReturnsFalse() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
    }

    /// EOU bundle missing one required file → not cached. Belt-and-
    /// suspenders: a download that lost a file partway through must
    /// not deceive the cache check.
    @Test func streamingMissingOneFileReturnsFalse() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)
        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)

        // Yank vocab.json — FluidAudio requires it.
        let vocab = cache.streamingPartialCacheURL(for: .tdt_0_6b_v2_en_streaming)!
            .appendingPathComponent("vocab.json")
        try? FileManager.default.removeItem(at: vocab)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
    }

    /// removeCache cleans both bundle directories so a subsequent
    /// retry can't see a partial earlier cache. Verifies the contract
    /// from the user-visible side: after removeCache, isCached is false.
    @Test func removeCacheClearsBothBundles() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)
        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)
        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == true)

        cache.removeCache(for: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
        let batchDerived = Self.batchStagingURL(cache)
        let streamingDir = cache.streamingPartialCacheURL(for: .tdt_0_6b_v2_en_streaming)!
        #expect(FileManager.default.fileExists(atPath: batchDerived.path) == false)
        #expect(FileManager.default.fileExists(atPath: streamingDir.path) == false)
    }

    /// streamingPartialCacheURL returns nil for non-streaming options.
    /// Keeps existing v3 / JA call sites unaffected.
    @Test func nonStreamingOptionHasNoStreamingURL() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3_int4) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_ja) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v2_en_streaming) != nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3_nemotron_streaming) != nil)
        #expect(cache.streamingPartialCacheURL(for: .nemotron_en) != nil)
    }

    /// The int4 v3 option uses the same FluidAudio repo and `.v3`
    /// architecture as default v3, but Jot must give it a separate parent
    /// folder so the SDK-derived `parakeet-tdt-0.6b-v3` cache does not
    /// overlap with the default v3 install.
    @Test func v3CompositeUsesDefaultBatchCacheAndInt4KeepsDedicatedParent() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        let int4URL = cache.cacheURL(for: .tdt_0_6b_v3_int4)
        let option1URL = cache.cacheURL(for: .tdt_0_6b_v3_nemotron_streaming)
        let defaultURL = cache.cacheURL(for: .tdt_0_6b_v3)

        #expect(int4URL != defaultURL)
        #expect(option1URL == defaultURL)
        #expect(option1URL != int4URL)
        #expect(int4URL.path.contains("parakeet-tdt-0.6b-v3-coreml-int4"))
        #expect(int4URL.lastPathComponent == "parakeet-tdt-0.6b-v3-coreml")

        let paths = cache.batchCachePaths(for: .tdt_0_6b_v3_int4)
        let int4Derived = cache.root
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml-int4", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        let defaultDerived = cache.root
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)

        #expect(paths.contains(int4Derived))
        #expect(!paths.contains(defaultDerived))
    }

    @Test func nemotronOptionsShareDedicatedStreamingCache() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        let option1 = cache.streamingPartialCacheURL(for: .tdt_0_6b_v3_nemotron_streaming)
        let option3 = cache.streamingPartialCacheURL(for: .nemotron_en)

        #expect(option1 == option3)
        #expect(option1?.lastPathComponent == "nemotron-streaming-en-1120ms")
    }

    @Test func nemotronOnlyRequiresOnlyNemotronBundle() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        #expect(cache.isCached(.nemotron_en) == false)

        Self.stageStreamingNemotron(cache, id: .nemotron_en)

        #expect(cache.isCached(.nemotron_en) == true)
    }

    @Test func nemotronOnlyRemoveCacheDoesNotDeleteDefaultV3Batch() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV3Default(cache)
        Self.stageStreamingNemotron(cache, id: .nemotron_en)
        #expect(cache.isCached(.tdt_0_6b_v3) == true)
        #expect(cache.isCached(.nemotron_en) == true)

        cache.removeCache(for: .nemotron_en)

        #expect(cache.isCached(.tdt_0_6b_v3) == true)
        #expect(cache.isCached(.nemotron_en) == false)
    }

    @Test func multilingualNemotronRequiresDefaultV3BatchAndNemotronBundle() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV3Default(cache)
        #expect(cache.isCached(.tdt_0_6b_v3_nemotron_streaming) == false)

        Self.stageStreamingNemotron(cache, id: .tdt_0_6b_v3_nemotron_streaming)

        #expect(cache.isCached(.tdt_0_6b_v3_nemotron_streaming) == true)
    }

    // MARK: - Startup self-heal: per-side presence (`stillPresent`)

    /// `stillPresent` reports each side independently. The self-heal uses this
    /// to tell a *missing* side (skip purge, downloadIfMissing fetches it) from
    /// a *present-but-load-failed* side (corrupt → purge). Batch present,
    /// streaming absent.
    @Test func stillPresentReportsBatchSideOnly() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .batch) == true)
        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .streaming) == false)
    }

    /// Streaming present, batch absent → only the streaming side reports.
    @Test func stillPresentReportsStreamingSideOnly() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .batch) == false)
        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .streaming) == true)
    }

    /// Nemotron-only: the single streaming bundle backs both sides, so a
    /// `.batch` query returns the streaming presence (single-side passthrough).
    @Test func stillPresentNemotronTreatsBothSidesAsStreamingBundle() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageStreamingNemotron(cache, id: .nemotron_en)

        #expect(cache.stillPresent(.nemotron_en, side: .batch) == true)
        #expect(cache.stillPresent(.nemotron_en, side: .streaming) == true)
    }

    // MARK: - Startup self-heal: surgical purge (M4)

    /// Surgical purge of ONLY the streaming side leaves the SHARED v3 batch
    /// bundle intact — the M4 invariant. A blunt `removeCache(for:)` would
    /// evict the v3 batch bundle that other options depend on; the self-heal
    /// must never do that.
    @Test func surgicalStreamingPurgeKeepsSharedV3Batch() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV3Default(cache)
        Self.stageStreamingNemotron(cache, id: .tdt_0_6b_v3_nemotron_streaming)
        #expect(cache.isCached(.tdt_0_6b_v3) == true)

        // Purge ONLY the (simulated-corrupt) streaming side.
        cache.removeCache(
            for: .tdt_0_6b_v3_nemotron_streaming,
            removeBatch: false,
            removeStreaming: true
        )

        // Shared v3 batch bundle survives; only the streaming side is gone.
        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .batch) == true)
        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .streaming) == false)
        #expect(cache.isCached(.tdt_0_6b_v3) == true)
    }

    /// Surgical purge of ONLY the batch side leaves the streaming bundle
    /// untouched — the symmetric case.
    @Test func surgicalBatchPurgeKeepsStreaming() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)
        Self.stageStreamingEOU(cache, id: .tdt_0_6b_v2_en_streaming)

        cache.removeCache(
            for: .tdt_0_6b_v2_en_streaming,
            removeBatch: true,
            removeStreaming: false
        )

        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .batch) == false)
        #expect(cache.stillPresent(.tdt_0_6b_v2_en_streaming, side: .streaming) == true)
    }
}
