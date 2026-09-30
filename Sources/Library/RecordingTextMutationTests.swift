#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only runtime tests for the one text writer (`RecordingTextMutation`),
/// its pure helpers (`WholeWord`, `TextOffsetMap`, draft rebasing), and the
/// search-chunk lifecycle (`ChunkStore` deletion + orphan filtering). Same
/// `assert()`-in-`#if DEBUG` idiom as `SpeakerTimelineTextEditTests`; runs once
/// at startup via `runAll()` (before the app's object graph exists, so
/// `RecordingIndexer.shared` is nil and nothing is indexed) against an
/// in-memory SwiftData container. Stripped from release builds.
@MainActor
enum RecordingTextMutationTests {

    static func runAll() {
        test_wholeWord_matchesWholeWordsOnly()
        test_wholeWord_anchoredRangeIsStrict()
        test_rebasing_carriesSpanIntoDraft()
        test_rebasing_leavesAUserEditedWordAlone()
        test_replace_refusedWhenWordsMoved()
        test_replace_recomputesAutoTitleOnly()
        test_replace_carriesSpeakerSegmentsAndMarksSummaryStale()
        test_handEdit_stampsEdited_machineTextResets()
        test_apply_postsChangeNotification()
        test_editSession_spanChangeCarriedIntoDraft()
        test_editSession_machineTextNeverDiscardsDraft()
        test_editSession_draftSurvivesRelaunch()
        test_chunks_deletedWithRecording_andOrphansFiltered()
    }

    // MARK: - Helpers

    private static func container() -> ModelContainer {
        try! ModelContainer(
            for: Recording.self, RecordingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func insert(_ text: String, in context: ModelContext,
                               title: String? = nil) -> Recording {
        let r = Recording(
            title: title ?? Recording.defaultTitle(from: text), durationSeconds: 1,
            transcript: text, rawTranscript: text, audioFileName: "test-\(UUID().uuidString).wav",
            modelIdentifier: "test")
        context.insert(r)
        try? context.save()
        return r
    }

    private static func range(of word: String, in text: String) -> NSRange {
        NSRange(WholeWord.firstRange(of: word, in: text)!, in: text)
    }

    // MARK: - WholeWord

    static func test_wholeWord_matchesWholeWordsOnly() {
        let text = "Lisbon and lisa met Lisa."
        let hits = WholeWord.ranges(of: "lisa", in: text).map { String(text[$0]) }
        assert(hits == ["lisa", "Lisa"], "whole words only, case-insensitive, got \(hits)")
        assert(WholeWord.firstRange(of: "sri ram", in: "call sri ram now") != nil, "multi-word phrase matches")
    }

    static func test_wholeWord_anchoredRangeIsStrict() {
        let text = "cloud one, cloud two"
        assert(WholeWord.range(of: "cloud", at: 11, in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) } == 11,
               "the occurrence at the anchor")
        assert(WholeWord.range(of: "cloud", at: 5, in: text) == nil, "no guessing a nearby repeat")
    }

    // MARK: - Draft rebasing

    private static func change(old: String, replacing word: String, with replacement: String) -> RecordingTextMutation.Change {
        let r = range(of: word, in: old)
        return RecordingTextMutation.Change(
            recordingID: UUID(), oldText: old,
            newText: (old as NSString).replacingCharacters(in: r, with: replacement),
            span: .init(range: r, replacement: replacement), isMachineText: false)
    }

    static func test_rebasing_carriesSpanIntoDraft() {
        let c = change(old: "I asked cloud today.", replacing: "cloud", with: "Claude")
        let draft = "Yesterday I asked cloud today, twice."
        let out = c.rebasing(draft: draft)
        assert(out == "Yesterday I asked Claude today, twice.", "the other writer's change lands in the draft, got \(out)")
    }

    static func test_rebasing_leavesAUserEditedWordAlone() {
        let c = change(old: "I asked cloud today.", replacing: "cloud", with: "Claude")
        let draft = "I asked Claudia today."
        assert(c.rebasing(draft: draft) == draft, "the user's own edit of that word wins")
    }

    // MARK: - apply

    static func test_replace_refusedWhenWordsMoved() {
        let context = ModelContext(container())
        let r = insert("I asked cloud today.", in: context)
        let stale = NSRange(location: 0, length: 5)
        let out = try? RecordingTextMutation.apply(.replace(stale, with: "Claude", expecting: "cloud"), to: r, in: context)
        assert(out == nil && r.transcript == "I asked cloud today.", "a range that no longer holds the word is refused")
    }

    static func test_replace_recomputesAutoTitleOnly() {
        let context = ModelContext(container())
        let auto = insert("I asked cloud today.", in: context)
        _ = try? RecordingTextMutation.apply(.replace(range(of: "cloud", in: auto.transcript), with: "Claude", expecting: "cloud"),
                                    to: auto, in: context)
        assert(auto.title == "I asked Claude today.", "an auto-title follows the text, got \(auto.title)")

        let renamed = insert("I asked cloud today.", in: context, title: "Standup")
        _ = try? RecordingTextMutation.apply(.replace(range(of: "cloud", in: renamed.transcript), with: "Claude", expecting: "cloud"),
                                    to: renamed, in: context)
        assert(renamed.title == "Standup", "a user rename is never touched")

        let pending = insert("", in: context)
        _ = try? RecordingTextMutation.apply(.machineText("Recovered words", raw: "recovered words"), to: pending, in: context)
        assert(pending.title == "Recovered words", "a re-transcribed pending row gets a real title, got \(pending.title)")
    }

    static func test_replace_carriesSpeakerSegmentsAndMarksSummaryStale() {
        let context = ModelContext(container())
        let r = insert("we met jamie\n\njamie said hi", in: context)
        r.speakerTimeline = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: [
            SpeakerTimelineSegment(speakerLabel: "A", startSec: 0, endSec: 1, text: "we met jamie"),
            SpeakerTimelineSegment(speakerLabel: "B", startSec: 1, endSec: 2, text: "jamie said hi"),
        ]))
        r.summaryText = "They met."
        try? context.save()
        // The SECOND "jamie" (speaker B's).
        let second = NSRange(location: 14, length: 5)
        _ = try? RecordingTextMutation.apply(.replace(second, with: "Jamy", expecting: "jamie"), to: r, in: context)
        let segments = (try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: r.speakerTimeline ?? Data()))?.segments
        assert(segments?.map(\.text) == ["we met jamie", "Jamy said hi"],
               "the edit lands in the segment that owns it, got \(String(describing: segments?.map(\.text)))")
        assert(r.summaryIsStale == true, "an existing summary is marked stale")
    }

    static func test_handEdit_stampsEdited_machineTextResets() {
        let context = ModelContext(container())
        let r = insert("first draft", in: context)
        r.speakerTimeline = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: [
            SpeakerTimelineSegment(speakerLabel: "A", startSec: 0, endSec: 1, text: "first draft"),
        ]))
        _ = try? RecordingTextMutation.apply(.handEdit("first final draft"), to: r, in: context)
        assert(r.editedAt != nil, "a hand edit is stamped")
        let segments = (try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: r.speakerTimeline ?? Data()))?.segments
        assert(segments?.first?.text == "first final draft", "a hand edit carries into the segments")

        r.pendingSince = .now
        _ = try? RecordingTextMutation.apply(.machineText("fresh text", raw: "fresh text raw"), to: r, in: context, timeline: .clear)
        assert(r.transcript == "fresh text" && r.rawTranscript == "fresh text raw", "machine text + raw land")
        assert(r.editedAt == nil && r.pendingSince == nil, "machine text is neither edited nor pending")
        assert(r.speakerTimeline == nil, "re-transcribe clears the old segments")
    }

    static func test_apply_postsChangeNotification() {
        let context = ModelContext(container())
        let r = insert("I asked cloud today.", in: context)
        var seen: RecordingTextMutation.Change?
        let token = NotificationCenter.default.addObserver(
            forName: RecordingTextMutation.didChangeNotification, object: nil, queue: nil
        ) { note in
            MainActor.assumeIsolated { seen = RecordingTextMutation.change(in: note) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try? RecordingTextMutation.apply(.replace(range(of: "cloud", in: r.transcript), with: "Claude", expecting: "cloud"),
                                    to: r, in: context)
        assert(seen?.recordingID == r.id && seen?.newText == "I asked Claude today."
                && seen?.span?.replacement == "Claude",
               "open views are told what changed")
    }

    // MARK: - Edit sessions

    static func test_editSession_spanChangeCarriedIntoDraft() {
        let context = ModelContext(container())
        let r = insert("I asked cloud today.", in: context)
        let sessions = TranscriptEditSessions(fileURL: nil)
        sessions.begin(r)
        sessions.updateDraft("I asked cloud today. More.", for: r.id)
        guard let change = try? RecordingTextMutation.apply(
                .replace(range(of: "cloud", in: r.transcript), with: "Claude", expecting: "cloud"),
                to: r, in: context)
        else { return assertionFailure("the pick applies") }
        sessions.recordingTextChanged(change)
        assert(sessions.session(for: r.id) == .init(baseline: "I asked Claude today.",
                                                    draft: "I asked Claude today. More."),
               "a pick lands in the draft and the baseline, got \(String(describing: sessions.session(for: r.id)))")
    }

    static func test_editSession_machineTextNeverDiscardsDraft() {
        let context = ModelContext(container())
        let r = insert("whole file text", in: context)
        let sessions = TranscriptEditSessions(fileURL: nil)
        sessions.begin(r)
        sessions.updateDraft("whole file text, edited", for: r.id)
        guard let change = try? RecordingTextMutation.apply(
                .machineText("whole file\n\ntext", raw: nil), to: r, in: context)
        else { return assertionFailure("the diarize text applies") }
        sessions.recordingTextChanged(change)
        assert(sessions.session(for: r.id) == .init(baseline: "whole file text",
                                                    draft: "whole file text, edited"),
               "late machine text keeps the draft and the user's baseline")
    }

    static func test_editSession_draftSurvivesRelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-edit-drafts-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = ModelContext(container())
        let r = insert("typed before the crash", in: context)
        let sessions = TranscriptEditSessions(fileURL: url)
        sessions.begin(r)
        sessions.updateDraft("typed before the crash, and more", for: r.id)
        sessions.flush()
        let relaunched = TranscriptEditSessions(fileURL: url)
        assert(relaunched.session(for: r.id)?.draft == "typed before the crash, and more",
               "a draft written while typing is restored after a quit")
        assert(relaunched.begin(r).draft == "typed before the crash, and more", "Edit resumes the kept draft")
        relaunched.end(r.id)
        assert(!FileManager.default.fileExists(atPath: url.path), "ending the last session clears the file")
    }

    // MARK: - Search chunks

    static func test_chunks_deletedWithRecording_andOrphansFiltered() {
        let container = container()
        let context = ModelContext(container)
        let kept = insert("kept recording", in: context)
        let deleted = insert("deleted recording", in: context)
        let version = "test-v1"
        for id in [kept.id, deleted.id, UUID()] {
            try? ChunkStore.replaceChunks(
                recordingID: id, chunks: [(0, "text", [1, 0], 0, 4)], modelVersion: version,
                createdAt: .now, durationSeconds: 1, container: container)
        }
        assert(ChunkStore.allChunks(modelVersion: version, container: container).count == 2,
               "a chunk whose recording doesn't exist is never returned")
        RecordingStore.delete(deleted, from: context)
        let live = ChunkStore.allChunks(modelVersion: version, container: container).map(\.recordingID)
        assert(live == [kept.id], "deleting a recording deletes its chunks, got \(live)")
        assert(ChunkStore.purgeOrphanedChunks(container: container) == 1, "the orphan left from before is purged")
        assert(ChunkStore.purgeOrphanedChunks(container: container) == 0, "nothing left to purge")
        assert(ChunkStore.count(modelVersion: version, container: container) == 1, "only the live recording's chunk remains")
    }
}
#endif
