#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only runtime tests for Speaker Labels piece A. Same convention
/// as `HelpInfraTests` — `assert()`-based invariants invoked from
/// `AppDelegate.applicationDidFinishLaunching`. Release builds strip this
/// file entirely.
///
/// What's covered:
/// * EnrolledIdentity `Data` round-trip — encode/decode preserves samples.
/// * EnrolledIdentitiesStore add/delete/cap-enforcement on an in-memory
///   ModelContainer.
/// * SpeakerTimelinePayload Codable round-trip.
/// * SpeakerLabelDetector heuristic — labeled inputs trip the gate;
///   single-line "Note: …" dictation does not.
/// * SortformerHardwareGate sanity — boolean depends on physicalMemory.
enum SpeakerLabelsTests {

    @MainActor
    static func runAll() {
        EnrolledIdentityCodecTests.runAll()
        EnrolledIdentitiesStoreTests.runAll()
        SpeakerTimelinePayloadTests.runAll()
        SpeakerLabelDetectorTests.runAll()
        SortformerHardwareGateTests.runAll()
    }
}

// MARK: - EnrolledIdentity Data round-trip

private enum EnrolledIdentityCodecTests {
    static func runAll() {
        test_encodeDecode_roundTrip()
        test_emptySamples_decodeReturnsEmpty()
        test_primarySamples_returnsFirstClipDecoded()
    }

    static func test_encodeDecode_roundTrip() {
        let original: [Float] = (0..<2_000).map { Float($0) * 0.001 }
        let data = EnrolledIdentity.encode(samples: original)
        let decoded = EnrolledIdentity.decode(clip: data)
        assert(decoded.count == original.count, "decoded count == original count")
        // Float bit-equality across the whole buffer.
        for (a, b) in zip(original, decoded) {
            assert(a.bitPattern == b.bitPattern, "Float round-trip preserves bits")
        }
    }

    static func test_emptySamples_decodeReturnsEmpty() {
        let empty = EnrolledIdentity.encode(samples: [])
        assert(EnrolledIdentity.decode(clip: empty).isEmpty, "empty encode → empty decode")
        assert(EnrolledIdentity.decode(clip: Data()).isEmpty, "Data() decode → empty array")
    }

    static func test_primarySamples_returnsFirstClipDecoded() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let identity = EnrolledIdentity(
            name: "Alex",
            isUser: false,
            voiceClips: [EnrolledIdentity.encode(samples: samples)]
        )
        let primary = identity.primarySamples ?? []
        assert(primary == samples, "primarySamples decodes the first clip")
    }
}

// MARK: - EnrolledIdentitiesStore CRUD

private enum EnrolledIdentitiesStoreTests {
    @MainActor
    static func runAll() {
        test_add_storesRow()
        test_add_capEnforced()
        test_replaceClip_replacesAndRetainsRow()
        test_delete_removesRow()
        test_remainingSlots_reflectsCount()
        test_clipsForWarmup_skipsEmptyBlobs()
    }

    @MainActor
    static func makeStore() -> EnrolledIdentitiesStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // EnrolledIdentity is a SwiftData model; standalone container is
        // sufficient for these tests.
        let container = try! ModelContainer(for: EnrolledIdentity.self, configurations: config)
        return EnrolledIdentitiesStore(context: container.mainContext)
    }

    @MainActor
    static func test_add_storesRow() {
        let store = makeStore()
        let identity = store.add(name: "Vineet", isUser: true, samples: [0.1, 0.2, 0.3])
        assert(identity != nil, "add returned a row")
        assert(store.identities.count == 1, "identities list updated")
        assert(store.hasIdentities, "hasIdentities true after add")
        assert(store.hasOwnerIdentity, "hasOwnerIdentity true for isUser=true add")
    }

    @MainActor
    static func test_add_capEnforced() {
        let store = makeStore()
        for i in 0..<SpeakerLabelsConstants.identityCap {
            _ = store.add(name: "User\(i)", isUser: i == 0, samples: [Float(i)])
        }
        assert(store.identities.count == SpeakerLabelsConstants.identityCap, "filled to cap")
        assert(store.remainingSlots == 0, "remainingSlots == 0 at cap")
        let extra = store.add(name: "Overflow", isUser: false, samples: [9])
        assert(extra == nil, "add beyond cap returns nil")
        assert(store.identities.count == SpeakerLabelsConstants.identityCap, "row count unchanged")
    }

    @MainActor
    static func test_replaceClip_replacesAndRetainsRow() {
        let store = makeStore()
        let identity = store.add(name: "Vineet", isUser: true, samples: [0.1, 0.2])!
        let originalID = identity.id
        store.replaceClip(on: identity, samples: [0.5, 0.6, 0.7])
        assert(store.identities.count == 1, "row count unchanged after replace")
        assert(store.identities.first?.id == originalID, "row id preserved")
        let decoded = store.identities.first?.primarySamples ?? []
        assert(decoded == [0.5, 0.6, 0.7], "clip replaced")
    }

    @MainActor
    static func test_delete_removesRow() {
        let store = makeStore()
        let owner = store.add(name: "Vineet", isUser: true, samples: [0.1])!
        _ = store.add(name: "Alex", isUser: false, samples: [0.2])
        assert(store.identities.count == 2, "two rows after add")
        store.delete(owner)
        assert(store.identities.count == 1, "owner removed")
        assert(store.hasOwnerIdentity == false, "no owner row left")
    }

    @MainActor
    static func test_remainingSlots_reflectsCount() {
        let store = makeStore()
        assert(store.remainingSlots == SpeakerLabelsConstants.identityCap, "empty store has cap slots")
        _ = store.add(name: "Vineet", isUser: true, samples: [0.1])
        assert(store.remainingSlots == SpeakerLabelsConstants.identityCap - 1, "one less after add")
    }

    @MainActor
    static func test_clipsForWarmup_skipsEmptyBlobs() {
        let store = makeStore()
        _ = store.add(name: "Vineet", isUser: true, samples: [0.1, 0.2])
        // Manually shove an identity with an empty clip via direct mutation.
        if let row = store.identities.first {
            row.voiceClips = []
        }
        let clips = store.clipsForWarmup()
        assert(clips.isEmpty, "identity with empty voiceClips is skipped")
    }
}

// MARK: - SpeakerTimelinePayload Codable

private enum SpeakerTimelinePayloadTests {
    static func runAll() {
        test_payload_roundTrip()
        test_payload_emptySegments_roundTrip()
        test_renderLabeled_outputsExpectedFormat()
    }

    static func test_payload_roundTrip() {
        let payload = SpeakerTimelinePayload(segments: [
            SpeakerTimelineSegment(speakerLabel: "You", startSec: 0, endSec: 2.5, text: "Hello"),
            SpeakerTimelineSegment(speakerLabel: "Alex", startSec: 2.5, endSec: 5.0, text: "Hi")
        ])
        let data = try! JSONEncoder().encode(payload)
        let decoded = try! JSONDecoder().decode(SpeakerTimelinePayload.self, from: data)
        assert(decoded.version == SpeakerTimelinePayload.currentVersion, "version preserved")
        assert(decoded.segments.count == 2, "two segments preserved")
        assert(decoded.segments[0] == payload.segments[0], "first segment round-trips")
        assert(decoded.segments[1] == payload.segments[1], "second segment round-trips")
    }

    static func test_payload_emptySegments_roundTrip() {
        let payload = SpeakerTimelinePayload(segments: [])
        let data = try! JSONEncoder().encode(payload)
        let decoded = try! JSONDecoder().decode(SpeakerTimelinePayload.self, from: data)
        assert(decoded.segments.isEmpty, "empty segments round-trips")
    }

    static func test_renderLabeled_outputsExpectedFormat() {
        let payload = SpeakerTimelinePayload(segments: [
            SpeakerTimelineSegment(speakerLabel: "You", startSec: 0, endSec: 2, text: "Hello there"),
            SpeakerTimelineSegment(speakerLabel: "Alex", startSec: 2, endSec: 4, text: "Hi"),
            SpeakerTimelineSegment(speakerLabel: "Speaker 2", startSec: 4, endSec: 6, text: "")
        ])
        let rendered = SpeakerTimelineBuilder.renderLabeled(payload: payload)
        assert(rendered == "You: Hello there\nAlex: Hi", "renderLabeled drops empty-text segments")
    }
}

// MARK: - SpeakerLabelDetector

private enum SpeakerLabelDetectorTests {
    static func runAll() {
        test_labeledMultiSpeaker_isDetected()
        test_singleLineNote_isNotLabeled()
        test_twoDistinctLabels_isLabeled()
        test_emptyInput_isNotLabeled()
    }

    static func test_labeledMultiSpeaker_isDetected() {
        let text = """
        You: I think we should ship it on Tuesday.
        Alex: That gives QA only one day.
        You: Fair, let's revisit on Thursday.
        """
        assert(SpeakerLabelDetector.looksLabeled(text), "Multi-line labeled transcript detected")
    }

    static func test_singleLineNote_isNotLabeled() {
        let text = "Note: this is a single-line dictation note about something."
        assert(!SpeakerLabelDetector.looksLabeled(text), "Single-line 'Note:' is not flagged")
    }

    static func test_twoDistinctLabels_isLabeled() {
        // Only two lines, but two distinct labels.
        let text = """
        You: Hello.
        Alex: Hi.
        """
        assert(SpeakerLabelDetector.looksLabeled(text), "Two distinct labels detected")
    }

    static func test_emptyInput_isNotLabeled() {
        assert(!SpeakerLabelDetector.looksLabeled(""), "Empty string is not labeled")
        assert(!SpeakerLabelDetector.looksLabeled("\n\n  \n"), "Whitespace-only input is not labeled")
    }
}

// MARK: - Hardware gate

private enum SortformerHardwareGateTests {
    static func runAll() {
        test_hardwareGate_matchesPhysicalMemory()
    }

    static func test_hardwareGate_matchesPhysicalMemory() {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let expected = bytes >= UInt64(16) * 1_073_741_824
        assert(SortformerHardwareGate.isSupported == expected, "Hardware gate matches physicalMemory ≥ 16 GB")
    }
}

#endif
