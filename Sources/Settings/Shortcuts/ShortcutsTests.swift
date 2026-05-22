#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the redesigned Shortcuts pane.
///
/// Two suites:
///   • `ShortcutsRowModelTests` — pin the row catalog and the per-action
///     mapping so a future `SingleKey.Action` rename has to update this
///     file or fail loudly on launch.
///   • `ShortcutsSearchFilterTests` — exercise the substring-token
///     matcher across the documented patterns ("opt /", "esc", "caps").
///
/// Mirrors the `HelpInfraTests` pattern: no XCTest dependency, the suite
/// is called once from `AppDelegate` in DEBUG so misses fire at launch.
@MainActor
enum ShortcutsTests {
    static func runAll() {
        ShortcutsRowModelTests.runAll()
        ShortcutsSearchFilterTests.runAll()
    }
}

enum ShortcutsRowModelTests {
    static func runAll() {
        test_allRows_covers_everyBindableActionPlusCancel()
        test_helpAnchor_perAction()
        test_firingContext_perAction()
        test_groups_perRow()
        test_haystack_lowercased()
    }

    static func test_allRows_covers_everyBindableActionPlusCancel() {
        let allActions = SingleKey.Action.allCases
        let bindableIDs = ShortcutsRow.all.compactMap { row -> SingleKey.Action? in
            if case let .bindable(action) = row.kind { return action }
            return nil
        }
        assert(
            Set(bindableIDs) == Set(allActions),
            "ShortcutsRow.all must cover every SingleKey.Action — missing: \(Set(allActions).subtracting(bindableIDs))"
        )
        assert(
            ShortcutsRow.all.contains(where: { $0.kind == .cancel }),
            "ShortcutsRow.all must include the cancel row"
        )
        assert(
            ShortcutsRow.all.last?.kind == .cancel,
            "Cancel row must appear last in display order"
        )
    }

    static func test_helpAnchor_perAction() {
        let expected: [SingleKey.Action: String] = [
            .toggleRecording: "toggle-recording",
            .pushToTalk: "push-to-talk",
            .pasteLastTranscription: "dictation",
            .rewriteWithVoice: "articulate-custom",
            .rewrite: "articulate-fixed",
        ]
        for (action, anchor) in expected {
            let row = ShortcutsRow.forAction(action)
            assert(
                row.helpAnchor == anchor,
                "\(action) expected anchor '\(anchor)' but got '\(row.helpAnchor)'"
            )
        }
        assert(
            ShortcutsRow.cancelRow.helpAnchor == "cancel-recording",
            "Cancel row anchor drifted"
        )
    }

    static func test_firingContext_perAction() {
        let alwaysActive: Set<SingleKey.Action> = [
            .toggleRecording, .pushToTalk, .pasteLastTranscription,
        ]
        let needsSelection: Set<SingleKey.Action> = [
            .rewriteWithVoice, .rewrite,
        ]
        for action in alwaysActive {
            assert(
                ShortcutsRow.forAction(action).firing == .alwaysActive,
                "\(action) should be alwaysActive"
            )
        }
        for action in needsSelection {
            assert(
                ShortcutsRow.forAction(action).firing == .needsSelection,
                "\(action) should be needsSelection"
            )
        }
        assert(
            ShortcutsRow.cancelRow.firing == .duringCapture,
            "Cancel row should be duringCapture"
        )
    }

    static func test_groups_perRow() {
        let recordingActions: Set<SingleKey.Action> = [
            .toggleRecording, .pushToTalk, .pasteLastTranscription,
        ]
        let rewriteActions: Set<SingleKey.Action> = [
            .rewriteWithVoice, .rewrite,
        ]
        for action in recordingActions {
            assert(
                ShortcutsRow.forAction(action).group == .recording,
                "\(action) should be in Recording group"
            )
        }
        for action in rewriteActions {
            assert(
                ShortcutsRow.forAction(action).group == .rewrite,
                "\(action) should be in Rewrite group"
            )
        }
        assert(
            ShortcutsRow.cancelRow.group == .captureCancel,
            "Cancel row should be in Capture & Cancel group"
        )
    }

    static func test_haystack_lowercased() {
        for row in ShortcutsRow.all {
            assert(
                row.searchHaystack == row.searchHaystack.lowercased(),
                "Haystack for '\(row.title)' should be pre-lowercased so the filter can avoid per-keystroke casing"
            )
        }
    }
}

enum ShortcutsSearchFilterTests {
    static func runAll() {
        test_emptyQuery_returnsEverything()
        test_titleMatch()
        test_keywordMatch_capsLock()
        test_keywordMatch_articulate()
        test_keywordMatch_esc()
        test_multiToken_allMustMatch()
        test_tokenizer_handlesExtraWhitespace()
    }

    static func test_emptyQuery_returnsEverything() {
        let all = ShortcutsRow.all
        assert(ShortcutsSearchFilter.filter(all, query: "") == all)
        assert(ShortcutsSearchFilter.filter(all, query: "   ") == all)
    }

    static func test_titleMatch() {
        let result = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: "rewrite")
        let titles = result.map(\.title)
        assert(titles.contains("Rewrite"), "Title 'Rewrite' should match query 'rewrite'")
        assert(titles.contains("Rewrite with Voice"), "Title 'Rewrite with Voice' should match query 'rewrite'")
    }

    static func test_keywordMatch_capsLock() {
        let result = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: "caps")
        let titles = result.map(\.title)
        assert(
            titles == ["Toggle Recording"],
            "'caps' should only hit Toggle Recording (keyword 'caps lock'). Got: \(titles)"
        )
    }

    static func test_keywordMatch_articulate() {
        let result = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: "articulate")
        let titles = Set(result.map(\.title))
        // Both Rewrite rows keep "articulate" as a legacy search keyword
        // for users who muscle-memory'd the v1.4-v1.5 wording.
        assert(
            titles == ["Rewrite", "Rewrite with Voice"],
            "'articulate' should hit both Rewrite rows. Got: \(titles)"
        )
    }

    static func test_keywordMatch_esc() {
        let result = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: "esc")
        let titles = result.map(\.title)
        assert(
            titles == ["Cancel"],
            "'esc' should only hit Cancel. Got: \(titles)"
        )
    }

    static func test_multiToken_allMustMatch() {
        // "selection" is in both Rewrite rows' keywords; "voice" is only
        // on rewriteWithVoice. Both must match.
        let result = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: "selection voice")
        let titles = result.map(\.title)
        assert(
            titles == ["Rewrite with Voice"],
            "'selection voice' should narrow to Rewrite with Voice. Got: \(titles)"
        )
    }

    static func test_tokenizer_handlesExtraWhitespace() {
        let a = ShortcutsSearchFilter.tokenize("  rewrite   voice  ")
        assert(a == ["rewrite", "voice"], "Tokenizer should strip extra whitespace. Got: \(a)")
        let b = ShortcutsSearchFilter.tokenize("\trewrite\nvoice ")
        assert(b == ["rewrite", "voice"], "Tokenizer should treat all whitespace uniformly. Got: \(b)")
    }
}
#endif
