import Foundation
import Testing
@testable import Jot

/// Cache invariant tests for the model options.
///
/// v2 and v3 are now **batch-only** for caching purposes: EOU was removed and
/// their live preview re-uses the batch weights via `PreviewScheduler`, so
/// `isCached` requires only the batch bundle. The Nemotron options (multilingual
/// v3 + Nemotron, and Nemotron-only English) still pair a separate streaming
/// bundle — those composite caches return `true` only when both bundles are
/// present.
///
/// Tests stage filesystem layouts under a temp `ModelCache` root so
/// the dev/CI machine's real `~/Library/Application Support/Jot/`
/// tree is never touched. The "fully present" stagings reproduce
/// FluidAudio's exact required-files set (TDT v2 via
/// `AsrModels.modelsExist`, Nemotron via
/// `ModelNames.NemotronStreaming.requiredModels`) rather than relying on real
/// downloads — the cache check is what's under test, not the SDK loader.
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

    /// v2 is now batch-only for caching: with EOU removed, the batch bundle
    /// alone is sufficient (live preview re-uses the batch weights via
    /// `PreviewScheduler`). Positive control for the other v2 assertions.
    @Test func v2BatchOnlyPresentReturnsTrue() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == true)
    }

    /// v2 with no batch bundle → not cached. The batch bundle is the only
    /// requirement now; without it nothing is installed.
    @Test func v2BatchMissingReturnsFalse() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
    }

    /// removeCache clears the v2 batch bundle so a subsequent retry can't see
    /// a partial earlier cache. After removeCache, isCached is false.
    @Test func removeCacheClearsV2Batch() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV2(cache, id: .tdt_0_6b_v2_en_streaming)
        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == true)

        cache.removeCache(for: .tdt_0_6b_v2_en_streaming)

        #expect(cache.isCached(.tdt_0_6b_v2_en_streaming) == false)
        let batchDerived = Self.batchStagingURL(cache)
        #expect(FileManager.default.fileExists(atPath: batchDerived.path) == false)
    }

    /// streamingPartialCacheURL returns a directory ONLY for the Nemotron
    /// options — the only ones with a separate streaming bundle. v2 / v3 / JA
    /// return nil now (their preview re-uses the batch weights).
    @Test func onlyNemotronOptionsHaveStreamingURL() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3_int4) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_ja) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v2_en_streaming) == nil)
        #expect(cache.streamingPartialCacheURL(for: .tdt_0_6b_v3_eou_streaming) == nil)
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
    /// Uses the multilingual Nemotron option (the v3 batch is shared and absent
    /// here; only the Nemotron streaming bundle is staged).
    @Test func stillPresentReportsStreamingSideOnly() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageStreamingNemotron(cache, id: .tdt_0_6b_v3_nemotron_streaming)

        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .batch) == false)
        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .streaming) == true)
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
    /// untouched — the symmetric case. Uses the multilingual Nemotron option,
    /// the only one with two distinct on-disk sides now that EOU is gone.
    @Test func surgicalBatchPurgeKeepsStreaming() throws {
        let cache = try Self.freshTempCache()
        defer { Self.cleanup(cache) }

        Self.stageBatchV3Default(cache)
        Self.stageStreamingNemotron(cache, id: .tdt_0_6b_v3_nemotron_streaming)

        cache.removeCache(
            for: .tdt_0_6b_v3_nemotron_streaming,
            removeBatch: true,
            removeStreaming: false
        )

        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .batch) == false)
        #expect(cache.stillPresent(.tdt_0_6b_v3_nemotron_streaming, side: .streaming) == true)
    }
}
