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
                aliases: Self.enrichedAliases(text: term.text, aliases: term.aliases),
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

    /// **Merged-word fix.** ASR can collapse a spoken multi-word term into ONE
    /// word ("Ramaa Nathan" heard as "Ramanathan"). FluidAudio's matcher only
    /// compares multi-word term forms against multi-word ASR spans, so without
    /// help the term never even competes for the merged word — and a shorter
    /// term ("Ramaa") wins it by default. Feeding the space-stripped form as an
    /// extra alias gives the matcher a single-word form ("RamaaNathan" →
    /// normalized "ramaanathan") that scores ~0.9 against any merged rendering.
    /// Injected at FEED time only — the user's vocabulary.txt is never rewritten.
    ///
    /// Ported from jot-mobile (`VocabularyRescorerHolder.enrichedAliases`).
    static func enrichedAliases(text: String, aliases: [String]?) -> [String]? {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return aliases }
        let merged = words.joined()
        var out = aliases ?? []
        let mergedLower = merged.lowercased()
        if !out.contains(where: { $0.lowercased() == mergedLower }) {
            out.append(merged)
        }
        return out.isEmpty ? nil : out
    }

    /// One de-duplicated applied correction, surfaced out of `rescore(...)` for
    /// the future pill / review UX (design §6/§7). Built by the adapter from the
    /// gate's per-occurrence `proposals` (filtered to `outcome == "applied"`,
    /// collapsed by `(from, to)`). `notable` is the **derived** anti-annoyance
    /// flag, defined in ONE place (`notable(_:)` below) — NOT a gate field.
    public struct UXCorrection: Sendable, Equatable {
        public let from: String     // what TDT wrote ("Jamie")
        public let to: String       // the vocab term ("Jamy")
        public let notable: Bool
        /// Slice D (ask-before-paste, §9 Option B). When `true`, the delivery
        /// bridge should HOLD the paste and surface the "Did you mean X?" pill
        /// for this correction before delivering. Additive metadata carried from
        /// the gate's `Proposal.askCandidate` — it never changes whether the gate
        /// applied or blocked the swap. For an APPLIED ask candidate, `to` is the
        /// term already spliced into the gated text (keep-original = replace
        /// `to`→`from`); for a BLOCKED ask candidate, `from` is what's in the
        /// text today and `to` is the term offered on confirm.
        public let askCandidate: Bool
    }

    /// The result of a gated rescore: the gated text plus the de-duped applied
    /// set for the UX. Slice A returns this so the correction set is never
    /// dropped; the pill/delivery wiring (feedback-ux.md) consumes it later.
    public struct RescoreResult: Sendable {
        public let text: String
        public let corrections: [UXCorrection]
    }

    /// Run the rescorer over a TDT-produced transcript and **gate** the result.
    /// Returns the GATED text plus the de-duped applied-correction set, or `nil`
    /// if the rescorer is not ready (e.g. master toggle is off, vocab empty,
    /// models not downloaded).
    ///
    /// Caller MUST treat `nil` and any thrown error the same: fall back to the
    /// raw TDT transcript. This function is a best-effort boost, never a
    /// correctness gate.
    ///
    /// - Parameter language: the resolved transcription language, threaded from
    ///   `Transcriber`. Drives the gate's per-language common-word brake
    ///   (`CommonWords(forLanguage:)`). `nil` → English default; a language whose
    ///   common-word list isn't bundled skips only that one guard (never crashes).
    /// - Parameter recordsProvenance: when `true`, the gate stashes its fresh
    ///   proposals into the shared `CorrectionProvenance` pending slot for a
    ///   later `commit(transcriptID:)`. Only saving callers (recorder dictation,
    ///   Library detail re-transcribe) pass `true`. When `false` the gate still
    ///   runs and returns gated text — it just must not touch the provenance
    ///   actor (else a non-saving voice flow racing a real dictation's transform
    ///   window would clobber that dictation's pending proposals).
    public func rescore(
        transcript: String,
        tokenTimings: [TokenTiming],
        audioSamples: [Float],
        language: LanguageChoice?,
        recordsProvenance: Bool
    ) async throws -> RescoreResult? {
        guard let spotter, let vocabulary, let rescorer else {
            return nil
        }
        guard !vocabulary.terms.isEmpty else { return nil }

        let spotResult = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary,
            minScore: nil
        )

        return try await finishRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            spotResult: spotResult,
            rescorer: rescorer,
            vocabulary: vocabulary,
            language: language,
            recordsProvenance: recordsProvenance
        )
    }

    /// **No-fork Nemotron entry point.** Nemotron's stream returns a plain
    /// `String` with NO per-word timings and NO confidence, so the timing-
    /// dependent `VocabularyRescorer.ctcTokenRescore` is inert there (it
    /// hard-returns on empty timings). Instead we run the CTC keyword SPOTTER on
    /// the audio — which acoustically detects each vocab term and its audio TIME
    /// RANGE without needing transcript timings — and place each detected term
    /// onto the Nemotron transcript ourselves, then apply the SAME
    /// `VocabularyGate`.
    ///
    /// Returns the GATED text plus the de-duped applied-correction set (mirroring
    /// `rescore(...)`), or `nil` if the spotter/vocabulary aren't ready (master
    /// toggle off / empty vocab / models not downloaded) — caller treats `nil`
    /// exactly like the TDT path and keeps the raw transcript. NOTE: the spotter
    /// is NOT run when not ready (no wasted ANE).
    ///
    /// Stock FluidAudio only: `spotKeywordsWithLogProbs` is the same stock API
    /// the TDT path uses. No FluidAudio fork. The transcript is already produced
    /// by the caller (concurrently with the spotter via `async let` in
    /// `Transcriber.transcribeWithNemotron`); we only do placement + gate here.
    ///
    /// - Parameter language: threaded from `Transcriber`. Nemotron is
    ///   English-only, so this resolves to the English common-word brake.
    /// - Parameter recordsProvenance: same contract as `rescore(...)` — only
    ///   saving callers (recorder dictation, Library re-transcribe) pass `true`.
    /// Spotted vocabulary terms ready for placement onto a transcript. Carries
    /// the gate `Detection`s plus the total audio duration the proportional-
    /// position placement needs. `nil` (from `spotDetections`) means the rescorer
    /// wasn't ready — the spotter was NOT run.
    public struct SpotPayload: Sendable {
        let detections: [VocabularyGate.Detection]
        let totalAudioDuration: TimeInterval
    }

    /// **Phase 1 (transcript-INDEPENDENT, ANE-heavy).** Run the CTC keyword
    /// spotter on the audio alone. Returns `nil` WITHOUT running the spotter when
    /// the rescorer isn't ready (toggle off / empty vocab / models not
    /// downloaded) — so a vocab-off dictation burns no extra ANE. Because this
    /// depends only on `audioSamples`, the caller runs it CONCURRENTLY with the
    /// Nemotron decode via `async let`; placement (`gateDetections`) happens after
    /// the decode lands.
    public func spotDetections(audioSamples: [Float]) async throws -> SpotPayload? {
        guard let spotter, let vocabulary, !vocabulary.terms.isEmpty else {
            return nil
        }
        let spotResult = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary,
            minScore: nil
        )
        return Self.makeSpotPayload(
            spotResult: spotResult, vocabulary: vocabulary, totalSamples: audioSamples.count)
    }

    /// Map FluidAudio spot detections → gate detections (attaching the SAME
    /// enriched aliases the spotter/rescorer used). `nonisolated static` so the
    /// streaming spotter — which finalizes off-actor — produces a byte-identical
    /// `SpotPayload` to the one-shot path above.
    nonisolated static func makeSpotPayload(
        spotResult: CtcKeywordSpotter.SpotKeywordsResult,
        vocabulary: CustomVocabularyContext,
        totalSamples: Int
    ) -> SpotPayload {
        var termAliasMap: [String: [String]] = [:]
        for t in vocabulary.terms {
            termAliasMap[t.text.lowercased(), default: []] += (t.aliases ?? [])
        }
        let detections: [VocabularyGate.Detection] = spotResult.detections.map { d in
            VocabularyGate.Detection(
                term: d.term.text,
                aliases: termAliasMap[d.term.text.lowercased()] ?? (d.term.aliases ?? []),
                score: d.score,
                startTime: d.startTime,
                endTime: d.endTime
            )
        }
        return SpotPayload(
            detections: detections,
            totalAudioDuration: TimeInterval(totalSamples) / AudioFormat.sampleRate)
    }

    // MARK: - Streaming CTC (run the spotter DURING recording, not after stop)

    /// Vend a streaming spotter for the current vocabulary, or `nil` when the
    /// spotter / vocabulary isn't ready (caller then skips streaming and the
    /// Nemotron path runs the one-shot `spotDetections` as before).
    func makeStreamingSpotter() -> StreamingCtcSpotter? {
        guard let spotter, let vocabulary, !vocabulary.terms.isEmpty else { return nil }
        return StreamingCtcSpotter(spotter: spotter, vocabulary: vocabulary)
    }

    /// Hand-off slot for a streamed `SpotPayload`: the recording pipeline sets it
    /// at stop (after the streaming spotter finalizes), and the Nemotron transcribe
    /// path consumes it (consume-once) instead of running the one-shot spot.
    /// `nil` means "no streamed payload" → the Nemotron path falls back to the
    /// one-shot `spotDetections`.
    private var pendingStreamedPayload: SpotPayload?

    public func setPendingStreamedPayload(_ payload: SpotPayload?) {
        pendingStreamedPayload = payload
    }

    public func takePendingStreamedPayload() -> SpotPayload? {
        defer { pendingStreamedPayload = nil }
        return pendingStreamedPayload
    }

    /// **Phase 2 (placement + gate).** Place the phase-1 detections onto the
    /// (now-known) Nemotron transcript via the gate's plausibility metric +
    /// proportional position, run the SAME `VocabularyGate`, and emit the verdict
    /// tail (provenance + UX payload) shared with the TDT path. Returns the gated
    /// text + de-duped corrections, or a byte-identical pass-through when there's
    /// nothing to place.
    ///
    /// - Parameter language: threaded from `Transcriber`. Nemotron is
    ///   English-only, so this resolves to the English common-word brake.
    /// - Parameter recordsProvenance: same contract as `rescore(...)`.
    public func gateDetections(
        transcript: String,
        payload: SpotPayload,
        language: LanguageChoice?,
        recordsProvenance: Bool
    ) async -> RescoreResult {
        guard !payload.detections.isEmpty else {
            return RescoreResult(text: transcript, corrections: [])
        }
        let overrides = await CorrectionStore.shared.snapshot()
        let commonWords = CommonWords.forLanguage(language)

        let gated = VocabularyGate.applyFromDetections(
            originalTranscript: transcript,
            detections: payload.detections,
            totalAudioDuration: payload.totalAudioDuration,
            commonWords: commonWords,
            overrides: overrides
        )
        log.info("spot-gated \(payload.detections.count) detection(s) → applied \(gated.applied), blocked \(gated.blocked.count)")

        return await emitVerdicts(gated: gated, recordsProvenance: recordsProvenance)
    }

    /// Shared tail of the TDT `rescore` path: takes the already-
    /// computed CTC spot result + transcript, runs `ctcTokenRescore`, the gate,
    /// provenance, and builds the UX payload. Extracted verbatim from the
    /// original `rescore(...)` body so the TDT path's behavior is byte-identical.
    private func finishRescore(
        transcript: String,
        tokenTimings: [TokenTiming],
        spotResult: CtcKeywordSpotter.SpotKeywordsResult,
        rescorer: VocabularyRescorer,
        vocabulary: CustomVocabularyContext,
        language: LanguageChoice?,
        recordsProvenance: Bool
    ) async throws -> RescoreResult? {
        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration
        )

        guard output.wasModified else {
            return RescoreResult(text: transcript, corrections: [])
        }

        // v1a — the GATE: re-check every proposed replacement so a custom term
        // can never silently overwrite a confident, correct word.
        // v1b — pass the owner's confirmed-mapping snapshot so a verdict ("when I
        // say Jamie I mean Jamy") overrides the guard for that pair. Snapshot
        // fetched once here (off the gate's synchronous hot loop).
        let overrides = await CorrectionStore.shared.snapshot()
        // Alias map for the gate's plausibility guard — a user alias ("Vinny" for
        // "Vineet") is the user vouching that the pair is acoustically plausible,
        // so the guard must measure against it. Built from the ENRICHED terms, so
        // the auto merged-form alias of multi-word terms is included.
        var termAliases: [String: [String]] = [:]
        for t in vocabulary.terms {
            if let a = t.aliases, !a.isEmpty {
                termAliases[t.text.lowercased(), default: []] += a
            }
        }
        // Resolve the per-language common-word set. Non-English (or any language
        // whose list isn't bundled) resolves to `.empty` → the common-word brake
        // is a clean no-op; the gate never crashes.
        let commonWords = CommonWords.forLanguage(language)

        let gated = VocabularyGate.apply(
            originalTranscript: transcript,
            output: output,
            tokenTimings: tokenTimings,
            commonWords: commonWords,
            overrides: overrides,
            termAliases: termAliases
        )
        log.info("rescored \(output.replacements.count) proposal(s) → applied \(gated.applied), blocked \(gated.blocked.count)")

        return await emitVerdicts(gated: gated, recordsProvenance: recordsProvenance)
    }

    /// Shared verdict tail for BOTH gate paths (TDT `finishRescore` and the
    /// Nemotron `gateDetections`): logs each verdict, records provenance when owned,
    /// and maps the gate's per-occurrence proposals into the de-duped
    /// `UXCorrection` payload. Extracted verbatim from the original
    /// `finishRescore` body so the TDT path stays byte-identical.
    private func emitVerdicts(
        gated: VocabularyGate.Result,
        recordsProvenance: Bool
    ) async -> RescoreResult {
        // v1: log-only — record each verdict to the cross-cutting ErrorLog
        // (DiagnosticsLog severed, design §6/V4). Off the gate's hot loop.
        for p in gated.proposals {
            await ErrorLog.shared.info(
                component: "VocabularyGate",
                message: "\(p.originalWord) → \(p.term)",
                context: [
                    "decision": p.decision,
                    "outcome": p.outcome,
                    "conf": String(format: "%.3f", p.confidence),
                    "margin": String(format: "%.2f", p.margin),
                ]
            )
        }

        // v1b — stash the proposals so the pipeline can persist them against the
        // transcript id once it's minted (CorrectionProvenance.commit). gated.text
        // rides along as the anchor baseline: it's the ONLY text the proposals'
        // publishedStart offsets are valid for — downstream transforms shift the
        // text, and the provenance reconcile absorbs that drift by diffing here.
        //
        // Gated on `recordsProvenance`: only saving callers own the shared
        // pending slot. A non-saving voice flow (Ask Jot / Rewrite) firing
        // during a real dictation's async transform window must NOT write here,
        // or its proposals would be committed under the dictation's id.
        if recordsProvenance {
            await CorrectionProvenance.shared.record(gated.proposals, gatedText: gated.text)
        }

        // Map the gate's per-occurrence proposals into the UX payload, de-duped
        // by (from, to). `notable` derived in ONE place below.
        //
        // Two kinds of correction ride the payload:
        //   * APPLIED corrections (outcome == "applied") — the term is already in
        //     the gated text. These feed both the post-hoc review surface and,
        //     when `askCandidate`, the live ask (§9 (i) silent-OOV).
        //   * BLOCKED ask-candidates (outcome == "kept" AND askCandidate) — the
        //     common-word near-miss the gate refused to auto-apply (§9 (ii)
        //     "did you mean Lisa?"). The text still holds the original word;
        //     the live ask offers the term on confirm. We surface ONLY blocked
        //     proposals that are ask-candidates so the payload doesn't carry
        //     every routine block.
        var seen = Set<String>()
        var corrections: [UXCorrection] = []
        for p in gated.proposals where p.outcome == "applied" || p.askCandidate {
            let dedupKey = "\(p.originalWord)|\(p.term)"
            guard seen.insert(dedupKey).inserted else { continue }
            corrections.append(
                UXCorrection(
                    from: p.originalWord,
                    to: p.term,
                    notable: Self.notable(p),
                    askCandidate: p.askCandidate
                )
            )
        }

        return RescoreResult(text: gated.text, corrections: corrections)
    }

    /// Derived "notable" flag for an APPLIED correction (design §6). Defined in
    /// ONE place. A correction is notable when it's a multi-word term, won by a
    /// decisive margin, was applied to a genuinely-unsure word, or is a learned
    /// override — i.e. anything beyond a trivial swap. In v1 the gate already
    /// BLOCKs trivial high-confidence single-word swaps, so essentially every
    /// applied correction is already notable; the flag becomes load-bearing once
    /// learned overrides allow confident applies.
    private static func notable(_ p: VocabularyGate.Proposal) -> Bool {
        p.term.contains(" ")
            || p.margin >= VocabularyGate.earnedMargin
            || p.confidence <= VocabularyGate.lowConfidence
            || p.decision == "OVERRIDE"
    }
}

public enum VocabularyRescorerError: Error {
    /// `rebuildVocabulary(from:)` was called before the CTC models were
    /// loaded. Call `prepare(vocabularyFileURL:)` first.
    case notPrepared
}
