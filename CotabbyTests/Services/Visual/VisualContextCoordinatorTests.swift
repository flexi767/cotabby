import CoreGraphics
import XCTest
@testable import Cotabby

/// Covers the mid-typing screen refresh. The excerpt used to be captured once per focused field and
/// then never again, so anything that arrived or scrolled while the writer composed their reply was
/// invisible to the model. These tests pin the two properties that make refreshing safe: it replaces
/// the excerpt with what is on screen NOW, and it never leaves a request without screen context.
@MainActor
final class VisualContextCoordinatorTests: XCTestCase {
    func test_refreshReplacesTheExcerptWithNewlyVisibleText() async throws {
        let capture = SequencedScreenshotCapture(count: 2)
        let extractor = SequencedTextExtractor(texts: [
            "Maria: can you send the deck",
            "Maria: can you send the deck by Thursday please"
        ])
        let coordinator = makeCoordinator(capture: capture, extractor: extractor, stalenessInterval: 0)
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Sure, I will send it")

        coordinator.startSessionIfNeeded(for: snapshot)
        try await waitForExcerpt(coordinator) { $0.contains("send the deck") }
        XCTAssertEqual(capture.captureCount, 1)

        coordinator.refreshIfStale(for: snapshot)
        // The previous excerpt has to stay usable while the recapture runs, or every request in that
        // window silently loses its screen context.
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertNotNil(coordinator.excerpt(for: context(for: snapshot)))

        try await waitForExcerpt(coordinator) { $0.contains("Thursday") }
        XCTAssertEqual(capture.captureCount, 2)
    }

    func test_refreshIsIgnoredWhileTheExcerptIsStillFresh() async throws {
        let capture = SequencedScreenshotCapture(count: 2)
        let coordinator = makeCoordinator(
            capture: capture,
            extractor: SequencedTextExtractor(texts: ["Maria: can you send the deck"]),
            stalenessInterval: VisualContextCoordinator.defaultRefreshStalenessInterval
        )
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()

        coordinator.startSessionIfNeeded(for: snapshot)
        try await waitForExcerpt(coordinator) { $0.contains("send the deck") }

        coordinator.refreshIfStale(for: snapshot)

        XCTAssertEqual(capture.captureCount, 1, "A fresh excerpt must not be recaptured.")
    }

    func test_refreshIsIgnoredForADifferentField() async throws {
        let capture = SequencedScreenshotCapture(count: 2)
        let coordinator = makeCoordinator(
            capture: capture,
            extractor: SequencedTextExtractor(texts: ["Maria: can you send the deck"]),
            stalenessInterval: 0
        )
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "field-a")

        coordinator.startSessionIfNeeded(for: snapshot)
        try await waitForExcerpt(coordinator) { $0.contains("send the deck") }

        coordinator.refreshIfStale(
            for: CotabbyTestFixtures.focusedInputSnapshot(
                elementIdentifier: "field-b",
                focusChangeSequence: 2
            )
        )

        XCTAssertEqual(capture.captureCount, 1)
    }

    func test_refreshIsIgnoredWithoutScreenRecordingPermission() async {
        let capture = SequencedScreenshotCapture(count: 2)
        let coordinator = makeCoordinator(
            capture: capture,
            extractor: SequencedTextExtractor(texts: ["Maria: can you send the deck"]),
            stalenessInterval: 0,
            hasPermission: false
        )

        coordinator.refreshIfStale(for: CotabbyTestFixtures.focusedInputSnapshot())

        XCTAssertEqual(capture.captureCount, 0)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        capture: SequencedScreenshotCapture,
        extractor: SequencedTextExtractor,
        stalenessInterval: TimeInterval,
        hasPermission: Bool = true
    ) -> VisualContextCoordinator {
        VisualContextCoordinator(
            screenshotContextGenerator: ScreenshotContextGenerator(
                screenshotService: capture,
                textExtractor: extractor
            ),
            screenRecordingPermissionProvider: { hasPermission },
            refreshStalenessInterval: stalenessInterval
        )
    }

    private func context(for snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        FocusedInputContext(snapshot: snapshot, generation: 1)
    }

    /// Capture and OCR run in a detached task behind a 250 ms settle delay, so tests poll instead of
    /// reaching into the coordinator's task handles.
    private func waitForExcerpt(
        _ coordinator: VisualContextCoordinator,
        timeout: TimeInterval = 5,
        matching predicate: (String) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let excerpt = coordinator.latestExcerpt, predicate(excerpt) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the expected excerpt (last: \(coordinator.latestExcerpt ?? "nil")).")
    }
}

/// Hands out a different image per call so `ScreenshotContextGenerator`'s pixel-hash cache treats
/// each capture as a changed screen, and counts how many captures the coordinator actually asked for.
private final class SequencedScreenshotCapture: WindowScreenshotCapturing, @unchecked Sendable {
    private let images: [CGImage]
    private(set) var captureCount = 0

    init(count: Int) {
        images = (0..<count).map { Self.makeImage(gray: CGFloat($0) / CGFloat(max(count, 1))) }
    }

    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int
    ) async throws -> CapturedWindowScreenshot {
        let image = images[min(captureCount, images.count - 1)]
        captureCount += 1
        return CapturedWindowScreenshot(image: image, windowTitle: nil)
    }

    private static func makeImage(gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }
}

/// Returns the next OCR text per call, so a refresh can observe a screen that has moved on.
private final class SequencedTextExtractor: ScreenTextExtracting, @unchecked Sendable {
    private let texts: [String]
    private var index = 0

    init(texts: [String]) {
        self.texts = texts
    }

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let text = texts[min(index, texts.count - 1)]
        index += 1
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { OCRTextHygiene.OCRLine(text: String($0), confidence: 0.9) }
        return ExtractedScreenText(text: text, lineCount: lines.count, lines: lines)
    }
}
