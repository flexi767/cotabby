import Combine
import Foundation

/// Owns the writer's `PersonalWordModel`: loads it, feeds it, persists it, and forgets it.
///
/// Lives beside `PhraseMemoryStore` and shares its switch ("Learn from what I type", the phrase
/// memory setting): both remember the writer's own finished text, so one consent covers both, and
/// switching it off stops both. The coordinator is the only writer (it sees commits and accepted
/// suggestions); the Context settings pane reads the count and offers "forget".
///
/// Stored as JSON in Application Support/<bundle id>/personal-words.json, mode 0600, rather than in
/// UserDefaults like the phrases: a vocabulary of thousands of entries would bloat the preferences
/// plist that every settings write rewrites. Encoding happens on the main actor at a commit (rare);
/// the disk write runs on a serial queue.
@MainActor
final class PersonalWordStore: ObservableObject {
    @Published private(set) var wordCount: Int

    let fileURL: URL?
    private(set) var model: PersonalWordModel
    private let writeQueue = DispatchQueue(label: "com.jacobfu.tabby.personal-words")

    init(fileURL: URL? = PersonalWordStore.defaultFileURL()) {
        self.fileURL = fileURL
        let loaded = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decoder.decode(PersonalWordModel.self, from: $0) }
        model = loaded ?? PersonalWordModel()
        wordCount = model.wordCount
        hasStoredModel = loaded != nil
    }

    /// False until the model has been written once, so a first launch can seed it.
    private(set) var hasStoredModel: Bool

    nonisolated static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cotabby", isDirectory: true)
            .appendingPathComponent("personal-words.json")
    }

    /// One-time start from the phrases already learned, weighted by how often each was typed, so the
    /// feature is useful on its first day instead of after weeks of fresh commits.
    func seedIfEmpty(from phrases: PhraseMemorySnapshot) {
        guard !hasStoredModel, model.isEmpty, !phrases.isEmpty else { return }
        for phrase in phrases.phrases {
            model.learn(phrase.text, weight: Double(phrase.count), now: phrase.lastUsedAt)
        }
        save()
    }

    /// Learns from a block of text the writer finished (sent, or left the field with).
    func record(committedText: String, now: Date = Date()) {
        model.learn(committedText, weight: 1, now: now)
        save()
    }

    /// Extra weight for words the writer accepted from a suggestion, in the context they were
    /// accepted in. They will also arrive with the finished text later; accepting is the second vote.
    func recordAccepted(precedingText: String, acceptedText: String, now: Date = Date()) {
        let sentence = PhraseFastPath.currentSentence(in: precedingText)
        let contextTail = sentence.split(whereSeparator: \.isWhitespace).suffix(2).joined(separator: " ")
        // Mid-word accepts glue onto the partial word ("tomo" + "rrow"), which the tail already ends with.
        let separator = acceptedText.first?.isLetter == true && sentence.last?.isLetter == true ? "" : " "
        model.learn(contextTail + separator + acceptedText.trimmingCharacters(in: .whitespaces), weight: 1, now: now)
        save()
    }

    func forgetAll() {
        model = PersonalWordModel()
        wordCount = 0
        hasStoredModel = false
        guard let fileURL else { return }
        writeQueue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    private func save() {
        wordCount = model.wordCount
        hasStoredModel = true
        guard let fileURL, let data = try? Self.encoder.encode(model) else { return }
        writeQueue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
