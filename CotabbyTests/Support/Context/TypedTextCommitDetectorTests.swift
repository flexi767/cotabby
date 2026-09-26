import XCTest
@testable import Cotabby

/// Covers when the writer counts as having *finished* a piece of text. Both directions matter: a sent
/// message must be noticed, and a draft that a flapping focus keeps revisiting must not be counted
/// again and again (that would turn a one-off into a fake habit).
final class TypedTextCommitDetectorTests: XCTestCase {
    func test_commitsWhenTheFieldIsClearedAfterASend() {
        var detector = TypedTextCommitDetector()

        XCTAssertNil(observe(&detector, "Thanks for the update, I will send it"))
        let commit = observe(&detector, "")

        XCTAssertEqual(commit?.text, "Thanks for the update, I will send it")
        XCTAssertEqual(commit?.bundleIdentifier, "com.example.Chat")
    }

    func test_commitsTheSameTextTwiceWhenItIsSentTwice() {
        var detector = TypedTextCommitDetector()

        _ = observe(&detector, "sounds good, talk tomorrow")
        let first = observe(&detector, "")
        _ = observe(&detector, "sounds good, talk tomorrow")
        let second = observe(&detector, "")

        XCTAssertEqual(first?.text, "sounds good, talk tomorrow")
        XCTAssertEqual(second?.text, "sounds good, talk tomorrow")
    }

    func test_commitsTheDraftWhenFocusMovesToAnotherField() {
        var detector = TypedTextCommitDetector()

        _ = observe(&detector, "I will look at the numbers tonight")
        let commit = observe(&detector, "", identityKey: "field-b")

        XCTAssertEqual(commit?.text, "I will look at the numbers tonight")
    }

    /// Chromium and Electron hosts drop and re-acquire the focused element while the draft sits
    /// untouched. Committing on every bounce would inflate an unsent sentence into a habit.
    func test_doesNotRecommitTheSameDraftWhenFocusFlaps() {
        var detector = TypedTextCommitDetector()

        _ = observe(&detector, "I will look at the numbers tonight")
        let first = observe(&detector, "", identityKey: "field-b")
        _ = observe(&detector, "I will look at the numbers tonight")
        let second = observe(&detector, "", identityKey: "field-b")

        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    /// Backspacing shrinks the tracked text one observation at a time, so nothing long enough
    /// survives to be committed — deleting your own sentence is not finishing it.
    func test_doesNotCommitTextDeletedGradually() {
        var detector = TypedTextCommitDetector()
        let text = "I will look at the numbers tonight"

        _ = observe(&detector, text)
        var commits = 0
        var remaining = text
        while !remaining.isEmpty {
            remaining.removeLast()
            if observe(&detector, remaining) != nil { commits += 1 }
        }

        XCTAssertEqual(commits, 0)
    }

    func test_ignoresFieldsThatNeverHeldEnoughText() {
        var detector = TypedTextCommitDetector()

        _ = observe(&detector, "ok")
        XCTAssertNil(observe(&detector, ""))
        XCTAssertNil(detector.flush())
    }

    func test_flushCommitsTheTrackedDraftOnce() {
        var detector = TypedTextCommitDetector()

        _ = observe(&detector, "the revised timeline works for us")

        XCTAssertEqual(detector.flush()?.text, "the revised timeline works for us")
        XCTAssertNil(detector.flush())
    }

    private func observe(
        _ detector: inout TypedTextCommitDetector,
        _ text: String,
        identityKey: String = "field-a",
        bundleIdentifier: String = "com.example.Chat"
    ) -> TypedTextCommitDetector.Commit? {
        detector.observe(identityKey: identityKey, text: text, bundleIdentifier: bundleIdentifier)
    }
}
