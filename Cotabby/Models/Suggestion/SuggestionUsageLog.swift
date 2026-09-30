import Combine
import Foundation

/// File overview:
/// An opt-in, on-device record of what happened to each suggestion: what was shown (or why nothing
/// was), and what the writer actually typed next. It exists to build an evaluation set from real
/// writing. The hand-written eval cases score well while real acceptance stays low, and only real
/// contexts paired with what the writer really typed can say why.
///
/// Privacy contract, all enforced here rather than by callers:
/// - Off unless the user turns it on (absent key = off, for fresh installs and existing users).
/// - Nothing is written for secure fields, terminals, or code editors (the same surfaces phrase
///   memory refuses), because those hold passwords, shell history, and pasted keys.
/// - The file stays on this Mac, next to the app's other support files, and is never sent anywhere.
///   Settings shows the record count and deletes the file on request.
/// - Text is bounded per record (a tail before the caret, a head after it), not whole documents.

/// One finished suggestion outcome, one JSON line in the log.
struct SuggestionUsageRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Accepted in full with the accept key(s).
        case accepted
        /// Some words accepted, then the writer went their own way.
        case acceptedPartially
        /// Not accepted, but the writer typed the whole suggestion by hand: it was right.
        case typedThrough
        /// The writer typed something else.
        case ignored
        /// Nothing was typed after it was shown (the writer left, deleted, or sent).
        case abandoned
        /// Nothing was shown; `suppressionReason` says why.
        case suppressed
    }

    var timestamp: Date
    var bundleIdentifier: String
    var applicationName: String
    /// Up to `precedingLimit` characters before the caret when the suggestion was produced.
    var precedingText: String
    /// Up to `trailingLimit` characters after the caret.
    var trailingText: String
    var shownText: String?
    var suppressionReason: String?
    var rawText: String
    var isRetry: Bool
    /// When this outcome came from a retry, the reason its first attempt was unusable.
    var retriedAfter: String?
    var latencyMilliseconds: Int
    var outcome: Outcome
    var acceptedCharacters: Int
    /// What the field gained after the caret position the suggestion was made for.
    var typedAfter: String
    /// Leading characters of `typedAfter` that agree with `shownText` (whitespace-trimmed).
    var matchedCharacters: Int

    static let precedingLimit = 400
    static let trailingLimit = 120
    static let typedAfterLimit = 160
    static let rawLimit = 200

    /// Classifies a finished suggestion. Pure, so the rules are testable without a log file.
    static func outcome(shownText: String?, typedAfter: String, acceptedCharacters: Int) -> Outcome {
        guard let shownText else { return .suppressed }
        let shown = shownText.drop(while: \.isWhitespace)
        if acceptedCharacters > 0 {
            return acceptedCharacters >= shownText.count ? .accepted : .acceptedPartially
        }
        if typedAfter.isEmpty { return .abandoned }
        return matchedCharacters(shownText: shownText, typedAfter: typedAfter) >= shown.count
            ? .typedThrough
            : .ignored
    }

    static func matchedCharacters(shownText: String?, typedAfter: String) -> Int {
        guard let shownText else { return 0 }
        let shown = Array(shownText.drop(while: \.isWhitespace))
        let typed = Array(typedAfter.drop(while: \.isWhitespace))
        var count = 0
        while count < shown.count, count < typed.count, shown[count] == typed[count] {
            count += 1
        }
        return count
    }
}

@MainActor
final class SuggestionUsageLog: ObservableObject {
    static let enabledDefaultsKey = "cotabbySuggestionUsageLogEnabled"
    /// The live file rotates to `previous` beyond this size, so at most about twice this is kept.
    static let rotationBytes = 16 * 1024 * 1024

    @Published private(set) var isEnabled: Bool
    @Published private(set) var recordCount: Int

    let fileURL: URL?
    private let userDefaults: UserDefaults
    private let writeQueue = DispatchQueue(label: "com.jacobfu.tabby.suggestion-usage-log")
    private var pending: Pending?

    private struct Pending {
        var record: SuggestionUsageRecord
        let elementIdentifier: String
        /// The full text before the caret the suggestion was made for.
        let anchor: String
        /// The newest text before the caret that still extends `anchor`.
        var latestPrecedingText: String
    }

    init(userDefaults: UserDefaults = .standard, fileURL: URL? = SuggestionUsageLog.defaultFileURL()) {
        self.userDefaults = userDefaults
        self.fileURL = fileURL
        isEnabled = userDefaults.bool(forKey: Self.enabledDefaultsKey)
        recordCount = fileURL.map(Self.countRecords(in:)) ?? 0
    }

    nonisolated static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cotabby", isDirectory: true)
            .appendingPathComponent("suggestion-usage.jsonl")
    }

    var previousFileURL: URL? {
        fileURL?.deletingPathExtension().appendingPathExtension("previous.jsonl")
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        // Switching off stops observation at once; the unfinished record is dropped, not written.
        if !enabled { pending = nil }
    }

    /// Removes every stored record, the rotated file included.
    func deleteAll() {
        pending = nil
        let urls = [fileURL, previousFileURL].compactMap { $0 }
        writeQueue.sync {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        recordCount = 0
    }

    /// Whether this field may be logged at all.
    static func isLoggable(bundleIdentifier: String, isSecure: Bool, isIntegratedTerminal: Bool) -> Bool {
        guard !isSecure else { return false }
        switch AppSurfaceClassifier.classify(bundleIdentifier: bundleIdentifier, isIntegratedTerminal: isIntegratedTerminal) {
        case .terminal, .codeEditor:
            return false
        case .email, .chat, .browser, .other:
            return true
        }
    }

    /// Starts tracking one generation outcome at the caret it was made for. `shownText` is nil when
    /// nothing was shown. A retry at the same caret replaces the unusable first attempt it followed.
    func recordGeneration(
        context: FocusedInputContext,
        shownText: String?,
        suppressionReason: String?,
        rawText: String,
        isRetry: Bool,
        latency: TimeInterval,
        now: Date = Date()
    ) {
        guard isEnabled,
              Self.isLoggable(bundleIdentifier: context.bundleIdentifier, isSecure: context.isSecure,
                              isIntegratedTerminal: context.isIntegratedTerminal) else { return }
        var retriedAfter: String?
        if isRetry, let pending, pending.elementIdentifier == context.elementIdentifier,
           pending.anchor == context.precedingText, pending.record.shownText == nil {
            retriedAfter = pending.record.suppressionReason
            self.pending = nil
        } else {
            finishPending()
        }
        let record = SuggestionUsageRecord(
            timestamp: now,
            bundleIdentifier: context.bundleIdentifier,
            applicationName: context.applicationName,
            precedingText: String(context.precedingText.suffix(SuggestionUsageRecord.precedingLimit)),
            trailingText: String(context.trailingText.prefix(SuggestionUsageRecord.trailingLimit)),
            shownText: shownText,
            suppressionReason: shownText == nil ? suppressionReason : nil,
            rawText: String(rawText.prefix(SuggestionUsageRecord.rawLimit)),
            isRetry: isRetry,
            retriedAfter: retriedAfter,
            latencyMilliseconds: Int((latency * 1000).rounded()),
            outcome: shownText == nil ? .suppressed : .abandoned,
            acceptedCharacters: 0,
            typedAfter: "",
            matchedCharacters: 0
        )
        pending = Pending(
            record: record,
            elementIdentifier: context.elementIdentifier,
            anchor: context.precedingText,
            latestPrecedingText: context.precedingText
        )
    }

    /// Credits accepted characters to the suggestion being tracked.
    func recordAccepted(characters: Int) {
        guard characters > 0, pending?.record.shownText != nil else { return }
        pending?.record.acceptedCharacters += characters
    }

    /// Called for every focus snapshot. Follows the writer's typing past the tracked caret and
    /// finishes the record once they leave the field, delete back into the anchor, or send.
    func observe(elementIdentifier: String?, precedingText: String?) {
        guard var current = pending else { return }
        guard let elementIdentifier, let precedingText, elementIdentifier == current.elementIdentifier,
              precedingText.hasPrefix(current.anchor) else {
            finishPending()
            return
        }
        guard precedingText != current.latestPrecedingText else { return }
        current.latestPrecedingText = precedingText
        pending = current
    }

    /// Writes the tracked record now (app quit, logging switched to another field).
    func finishPending() {
        guard let current = pending else { return }
        pending = nil
        var record = current.record
        let typedAfter = String(current.latestPrecedingText.dropFirst(current.anchor.count)
            .prefix(SuggestionUsageRecord.typedAfterLimit))
        record.typedAfter = typedAfter
        record.matchedCharacters = SuggestionUsageRecord.matchedCharacters(shownText: record.shownText, typedAfter: typedAfter)
        record.outcome = SuggestionUsageRecord.outcome(
            shownText: record.shownText,
            typedAfter: typedAfter,
            acceptedCharacters: record.acceptedCharacters
        )
        append(record)
    }

    private func append(_ record: SuggestionUsageRecord) {
        guard let fileURL, let previousURL = previousFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        recordCount += 1
        writeQueue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil,
               size > Self.rotationBytes {
                try? manager.removeItem(at: previousURL)
                try? manager.moveItem(at: fileURL, to: previousURL)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Blocks until queued writes land. Tests and app termination use it.
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    private static func countRecords(in url: URL) -> Int {
        let previous = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
        return [url, previous].reduce(0) { total, file in
            guard let data = try? Data(contentsOf: file) else { return total }
            return total + data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
    }
}
