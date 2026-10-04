import CoreGraphics
import Foundation
import Logging
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is bounded semantic extraction for autocomplete context. This pass favors useful text
/// recovery over minimum latency because refresh runs independently of prediction generation.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
    /// Per-line OCR text paired with Vision's recognition confidence, in reading order. Carries the
    /// confidence that the joined `text` discards, so `OCRTextHygiene.dropLowConfidence` can filter on
    /// real values instead of a synthesized constant. Defaults to empty for callers (and tests) that
    /// only supply joined text.
    let lines: [OCRTextHygiene.OCRLine]

    init(text: String, lineCount: Int, lines: [OCRTextHygiene.OCRLine] = []) {
        self.text = text
        self.lineCount = lineCount
        self.lines = lines
    }
}

/// Test seam for screenshot OCR.
///
/// `ScreenshotContextGenerator` owns orchestration, while this protocol lets tests inject
/// deterministic OCR without depending on Vision, Screen Recording permission, or real pixels.
protocol ScreenTextExtracting {
    func extractText(from image: CGImage) async throws -> ExtractedScreenText
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "No usable visible text was recognized in the screenshot."
        case let .ocrFailed(message):
            return "Screenshot OCR failed: \(message)"
        }
    }
}

struct ScreenTextExtractor: ScreenTextExtracting {
    /// Vision cannot produce useful text from near-zero-sized request images. Treating those as
    /// empty OCR keeps degenerate screenshots on the same unavailable-context path as blank windows.
    private static let minimumOCRImageDimension = 4

    let maxImageDimension: Int
    let maxRecognizedCharacters: Int

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let startedAt = Date()
        // Resizing a full Retina window is CPU work too; do not do it on the caller's main actor.
        let preparedImage = await Task.detached(priority: .utility) {
            downsampledImageIfNeeded(image)
        }.value
        try Task.checkCancellation()
        let wasDownsampled = preparedImage.width != image.width || preparedImage.height != image.height

        log(
            "ocr-start input=\(image.width)x\(image.height) prepared=\(preparedImage.width)x\(preparedImage.height) " +
                "downsampled=\(wasDownsampled)"
        )

        guard preparedImage.width >= Self.minimumOCRImageDimension,
              preparedImage.height >= Self.minimumOCRImageDimension else {
            log(
                "ocr-skipped-too-small input=\(image.width)x\(image.height) " +
                    "prepared=\(preparedImage.width)x\(preparedImage.height)"
            )
            throw ScreenTextExtractionError.noRecognizedText
        }

        return try await withCheckedThrowingContinuation { continuation in
            // One recognizer for the app's lifetime, used from one serial queue. A fresh
            // `VNRecognizeTextRequest` per screenshot made Vision rebuild its Neural Engine program
            // and leave image buffers and CoreImage contexts behind on every refresh (measured:
            // about 330 MB of VisionCore allocations within minutes). The autorelease pool drains
            // each run's temporaries before the next one, which GCD's shared queues do not promise.
            Self.recognitionQueue.async {
                autoreleasepool {
                    let result = Self.recognize(preparedImage)
                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    switch result {
                    case let .failure(error):
                        self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                        continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription))
                    case let .success(recognizedLines):
                        let joinedText = recognizedLines.map(\.text).joined(separator: "\n")
                        let cappedText = String(joinedText.prefix(maxRecognizedCharacters))
                        guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            self.log("ocr-empty elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count)")
                            continuation.resume(throwing: ScreenTextExtractionError.noRecognizedText)
                            return
                        }
                        self.log(
                            "ocr-success elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count) " +
                                "chars=\(cappedText.count) preview=\(self.preview(cappedText))"
                        )
                        continuation.resume(returning: ExtractedScreenText(
                            text: cappedText,
                            lineCount: recognizedLines.count,
                            lines: recognizedLines
                        ))
                    }
                }
            }
        }
    }

    /// Serial: the shared request below is not safe to perform concurrently.
    private static let recognitionQueue = DispatchQueue(label: "com.cotabby.ocr", qos: .userInitiated)

    /// Accurate OCR is slower, but visual context refresh is throttled independently of typing and
    /// the result can materially improve autocomplete relevance. Language correction is on for the
    /// same reason: it cuts garbled recognitions at the source, which matters because this text
    /// conditions the prompt and the downstream hygiene filters can only drop junk, not repair it.
    /// Only touched on `recognitionQueue`.
    nonisolated(unsafe) private static let sharedRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        return request
    }()

    /// Runs the shared request on `image`. Call only on `recognitionQueue`.
    private static func recognize(_ image: CGImage) -> Result<[OCRTextHygiene.OCRLine], Error> {
        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([sharedRequest])
        } catch {
            return .failure(error)
        }
        let observations = sharedRequest.results ?? []
        // Keep each line's confidence (from its top candidate) so the hygiene pass can drop the
        // recognizer's weakest guesses; the joined text is for logging and the title fallback only.
        let lines = observations
            .sorted {
                if Swift.abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                    return $0.boundingBox.minY > $1.boundingBox.minY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            .compactMap { observation -> OCRTextHygiene.OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return OCRTextHygiene.OCRLine(text: trimmed, confidence: candidate.confidence, boundingBox: observation.boundingBox)
            }
        return .success(lines)
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    nonisolated private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func log(_ message: String) {
        // OCR log messages include preview text from the user's screen. Route them through
        // the debug gate so they only appear when the developer explicitly opts in.
        CotabbyDebugOptions.log(message)
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
