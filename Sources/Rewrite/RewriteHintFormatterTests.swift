#if DEBUG
import Foundation

/// DEBUG-only runtime tests for `RewriteHintFormatter` — the parser that turns
/// a prompt's `voiceAugmentHint` into the typed panel's question line + field
/// placeholder. Same launch-assert pattern as the other `*Tests` here; the
/// shipping target carries no XCTest dependency.
///
/// Invoked from `AppDelegate.applicationDidFinishLaunching` alongside the rest.
enum RewriteHintFormatterTests {

    static func runAll() {
        testSplitWithExample()
        testSplitWithoutExample()
        testFieldPlaceholder()
    }

    static func testSplitWithExample() {
        let parts = RewriteHintFormatter.split("Say the target language (e.g. \"to Japanese\")")
        assert(parts.question == "Say the target language",
               "question is the text before the (e.g. marker")
        assert(parts.example == "to Japanese",
               "example is the quoted text inside (e.g. …), quotes stripped")

        // Example containing its own punctuation must survive intact.
        let commaed = RewriteHintFormatter.split("Specify a focus or length (e.g. \"one paragraph, focus on decisions\")")
        assert(commaed.question == "Specify a focus or length")
        assert(commaed.example == "one paragraph, focus on decisions")
    }

    static func testSplitWithoutExample() {
        // No (e.g. marker → the whole hint is the question, no example.
        let parts = RewriteHintFormatter.split("Add priority, labels, or constraints")
        assert(parts.question == "Add priority, labels, or constraints")
        assert(parts.example == nil, "a hint with no (e.g. marker has no example")

        let apostrophe = RewriteHintFormatter.split("Optionally say why you're declining")
        assert(apostrophe.question == "Optionally say why you're declining")
        assert(apostrophe.example == nil)
    }

    static func testFieldPlaceholder() {
        assert(RewriteHintFormatter.fieldPlaceholder(for: "Say the target language (e.g. \"to Japanese\")")
               == "e.g. to Japanese",
               "an example seeds an 'e.g. …' placeholder")
        assert(RewriteHintFormatter.fieldPlaceholder(for: "Add priority, labels, or constraints")
               == "Type or say it",
               "an example-less hint falls back to the generic placeholder")
    }
}
#endif
