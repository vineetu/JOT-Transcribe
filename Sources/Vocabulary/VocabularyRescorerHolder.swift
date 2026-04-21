import FluidAudio
import Foundation
import os.log

/// Owns the FluidAudio vocabulary-boosting stack. Separate from
/// `VocabularyStore` (which owns the user's list + the file on disk)
/// because the rescorer carries live CoreML resources that only need to
/// exist while transcription actually uses them.
///
/// Lifecycle:
/// - `prepare()` loads the CTC 110M bundle (downloading on first use),
///   loads the user's vocabulary via FluidAudio's `loadWithCtcTokens`
///   (which tokenizes against the CTC vocabulary while it's warm), and
///   builds the `CtcKeywordSpotter` + `VocabularyRescorer` pair.
/// - `rebuildVocabulary()` reuses the already-loaded `CtcModels` and just
///   re-tokenizes the updated term list. Cheap.
/// - `unload()` drops the in-memory state — used when the user turns
///   vocabulary boosting off or hits Factory Reset.
///
/// Actor-isolated. The `Transcriber` actor calls in; the MainActor
/// `VocabularyStore` can also ask `prepare()` to run as a side effect
/// of the user flipping the master toggle.
public actor VocabularyRescorerHolder {
    public static let shared = VocabularyRescorerHolder()

    private let log = Logger(subsystem: "com.jot.Jot", category: "VocabularyRescorer")
    private let cache: CtcModelCache

    private var models: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?
    private var tokenizer: CtcTokenizer?
    private var isPreparing: Bool = false

    /// Monotonic token incremented on every `prepare` / `rebuildVocabulary`
    /// entry. Each async rebuild captures its own token and, before
    /// publishing its result to `self`, confirms its token is still the
    /// latest. Protects against actor reentrancy: two rapid saves from
    /// `VocabularyStore.save()` can each start a rebuild that suspends
    /// at the tokenizer load / rescorer build points; without this
    /// guard the older one could land after the newer and overwrite
    /// `self.vocabulary` with stale data.
    private var generation: UInt64 = 0

    public init(cache: CtcModelCache = .shared) {
        self.cache = cache
    }

    /// True when the spotter + rescorer + a non-empty vocabulary are all
    /// live in memory — the precondition for `rescore(...)` to actually
    /// change the transcript.
    public var isReady: Bool {
        spotter != nil && rescorer != nil && (vocabulary?.terms.isEmpty == false)
    }

    /// True when a prepare() call is currently executing. Caller (e.g.
    /// the Vocabulary pane's Download button) reads this to show a
    /// spinner.
    public var preparing: Bool { isPreparing }

    /// Drop every FluidAudio handle. Subsequent `rescore(...)` calls
    /// become no-ops until `prepare(...)` is called again.
    public func unload() {
        models = nil
        spotter = nil
        rescorer = nil
        vocabulary = nil
        tokenizer = nil
        generation &+= 1
        log.info("vocabulary rescorer unloaded")
    }

    /// Load the CTC 110M bundle (downloading on first use), tokenize the
    /// user's list, construct the rescorer. Idempotent — if models are
    /// already loaded, this path only re-tokenizes the term list via
    /// `rebuildVocabulary(from:)`.
    ///
    /// - Parameter vocabularyFileURL: the user-visible `vocabulary.txt`
    ///   file maintained by `VocabularyStore`. We read it via
    ///   `CustomVocabularyContext.loadFromSimpleFormat` directly so every
    ///   CoreML / cache file stays under Jot's own Application Support
    ///   subtree instead of FluidAudio's default `~/Library/Application
    ///   Support/FluidAudio/...` (which is where `loadWithCtcTokens`
    ///   would put it).
    public func prepare(vocabularyFileURL: URL) async throws {
        guard !isPreparing else {
            // A second concurrent prepare() just waits for the first to
            // finish; we don't queue both.
            return
        }
        isPreparing = true
        defer { isPreparing = false }

        if models == nil {
            log.info("loading CTC 110M bundle (downloading if needed)")
            do {
                let loaded = try await cache.ensureLoaded()
                models = loaded
                spotter = CtcKeywordSpotter(models: loaded)
            } catch {
                // A partially-populated cache directory can make
                // `modelsExist` lie; on load failure, nuke it so the
                // next retry starts from a known-empty state instead
                // of sticking on a corrupt bundle forever.
                cache.removeCache()
                log.error("CTC bundle load failed — cache cleared: \(error.localizedDescription)")
                throw error
            }
        }

        if tokenizer == nil {
            do {
                tokenizer = try await CtcTokenizer.load(from: cache.directory)
            } catch {
                log.error("CTC tokenizer load failed: \(error.localizedDescription)")
                throw error
            }
        }

        try await rebuildVocabulary(from: vocabularyFileURL)
    }

    /// Re-tokenize the user's vocab list against the already-warm CTC
    /// tokenizer. Call this when `VocabularyStore` writes a new term /
    /// alias set. Assumes `prepare(...)` has already run once — if not,
    /// throws so the caller knows to prepare first.
    public func rebuildVocabulary(from url: URL) async throws {
        guard let spotter, let tokenizer else {
            throw VocabularyRescorerError.notPrepared
        }

        generation &+= 1
        let ownGeneration = generation

        let baseVocab: CustomVocabularyContext
        do {
            baseVocab = try CustomVocabularyContext.loadFromSimpleFormat(from: url)
        } catch {
            log.error("vocabulary file parse failed: \(error.localizedDescription)")
            throw error
        }

        let tokenized = baseVocab.terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: term.weight,
                aliases: term.aliases,
                tokenIds: nil,
                ctcTokenIds: ids
            )
        }
        let droppedCount = baseVocab.terms.count - tokenized.count
        if droppedCount > 0 {
            log.warning("dropped \(droppedCount) term(s) that tokenized to empty — likely out-of-vocab characters")
        }

        let vocab = CustomVocabularyContext(terms: tokenized)
        let rescorer: VocabularyRescorer
        do {
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocab,
                config: .default,
                ctcModelDirectory: cache.directory
            )
        } catch {
            log.error("rescorer build failed: \(error.localizedDescription)")
            throw error
        }

        // Reentrancy check: during `await VocabularyRescorer.create(...)`
        // another rebuild may have started. If so, our results are
        // stale — drop them rather than clobber the newer state.
        guard ownGeneration == generation else {
            log.info("rebuild \(ownGeneration) superseded by \(self.generation); discarding")
            return
        }

        self.vocabulary = vocab
        self.rescorer = rescorer
        log.info("vocabulary loaded: \(vocab.terms.count) term(s) active")
    }

    /// Run the rescorer over a TDT-produced transcript. Returns the
    /// rescored text on success, `nil` if the rescorer is not ready
    /// (e.g. master toggle is off, vocab empty, models not downloaded).
    ///
    /// Caller MUST treat `nil` and any thrown error the same: fall back
    /// to the raw TDT transcript. This function is a best-effort boost,
    /// never a correctness gate.
    public func rescore(
        transcript: String,
        tokenTimings: [TokenTiming],
        audioSamples: [Float]
    ) async throws -> String? {
        guard let spotter, let vocabulary, let rescorer else {
            return nil
        }
        guard !vocabulary.terms.isEmpty else { return nil }

        let spotResult = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary,
            minScore: nil
        )

        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration
        )

        if output.wasModified {
            log.info("rescored \(output.replacements.count) replacement(s)")
            return output.text
        }
        return transcript
    }
}

public enum VocabularyRescorerError: Error {
    /// `rebuildVocabulary(from:)` was called before the CTC models were
    /// loaded. Call `prepare(vocabularyFileURL:)` first.
    case notPrepared
}
