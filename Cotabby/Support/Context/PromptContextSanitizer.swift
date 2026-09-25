import Foundation

/// File overview:
/// Sanitizes auxiliary prompt context that Cotabby did not get from the focused text field itself.
///
/// Clipboard text and OCR text can contain terminal separators, Markdown fences, shell prompts,
/// ANSI color escapes, and other prompt-shaped symbols. Those tokens are not useful semantic
/// context for autocomplete, and small local models can copy them back as output. Keeping this as
/// a pure `Support/` helper makes the policy deterministic, shared, and easy to test.
enum PromptContextSanitizer {
    private static let ansiEscapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "@."))
    private static let replacementScalar = UnicodeScalar(" ")

    /// Returns prompt-safe context containing only letters, numbers, whitespace, `@`, and `.`.
    ///
    /// Disallowed scalars become spaces instead of being deleted. That preserves word boundaries:
    /// `raw-output` becomes `raw output`, not `rawoutput`. The final line pass collapses repeated
    /// whitespace so stripped punctuation cannot still dominate the prompt through spacing noise.
    static func sanitize(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let withoutANSIEscapes = rawText.replacingOccurrences(
            of: ansiEscapePattern,
            with: " ",
            options: .regularExpression
        )

        let sanitizedScalars = withoutANSIEscapes.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacementScalar
        }

        let sanitizedText = String(String.UnicodeScalarView(sanitizedScalars))
        let normalizedLines = sanitizedText
            .components(separatedBy: .newlines)
            .map { collapseInlineWhitespace(in: $0) }
            .filter { !$0.isEmpty }

        let normalizedText = normalizedLines.joined(separator: "\n")
        let boundedText = maxCharacters.map {
            String(normalizedText.prefix($0))
        } ?? normalizedText

        return boundedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stricter sanitization for OCR text headed to the prompt excerpt.
    ///
    /// OCR adds a second failure mode beyond ordinary prompt injection: Vision can hallucinate
    /// short mixed-case blobs, repeated glyphs, and stray glyph runs. Those fragments are harmful
    /// because the model may copy them as the next token.
    ///
    /// The judgment is per LINE, not per token, and that is the whole design. Token-by-token
    /// filtering deleted exactly the words worth completing from: a line like
    /// "Invoice 4412 is overdue" lost its invoice number, "Q3 budget review" lost the quarter,
    /// "SCR-482 the importer drops listings" lost the ticket, and "BMW 320d Touring / 24 900 EUR"
    /// was erased down to the city name. Numbers, identifiers, and acronyms are precisely the
    /// vocabulary a reply needs to echo, and in a line that also carries real words they are real
    /// too. So a line is judged as a whole and kept VERBATIM when it carries word signal and is
    /// not mostly junk; otherwise it is dropped entirely.
    static func sanitizeOCR(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let baseSanitized = sanitize(rawText, maxCharacters: nil)
        let filteredLines = baseSanitized
            .components(separatedBy: .newlines)
            .compactMap { filterOCRNoiseLine($0) }

        let joined = filteredLines.joined(separator: "\n")
        let bounded = maxCharacters.map { String(joined.prefix($0)) } ?? joined
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts lowercased tokens of at least `minimumLength` characters, splitting on
    /// non-alphanumeric boundaries. Used by clipboard relevance and distillation logic.
    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        let words = text.lowercased().components(separatedBy: .alphanumerics.inverted)
        return Set(words.filter { $0.count >= minimumLength })
    }

    static func containsAlphanumericSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Common 1-2 character English words that should survive OCR noise filtering.
    private static let preservedShortWords: Set<String> = [
        "a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he",
        "if", "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
        "to", "up", "us", "we"
    ]

    /// Short technical words and acronyms that are semantically valuable even though generic OCR
    /// filters would treat them as too short or vowel-free.
    private static let preservedTechnicalTokens: Set<String> = [
        "ai", "api", "app", "apps", "ax", "bug", "bugs", "ci", "cmd", "css",
        "dom", "git", "gpu", "html", "http", "id", "ids", "io", "json", "llm",
        "ocr", "pdf", "pr", "prs", "qa", "sql", "ui", "url", "ux", "xpc"
    ]

    private static let commonAcronyms: Set<String> = [
        "AI", "API", "AX", "CI", "CPU", "CSS", "DOM", "GPU", "HTML", "HTTP",
        "ID", "IO", "JSON", "LLM", "OCR", "PDF", "PR", "QA", "SQL", "UI",
        "URL", "UX", "XPC"
    ]

    private static let knownWordSignals = [
        "accept", "app", "autocomplete", "button", "chat", "chrome", "class",
        "code", "context", "cotabby", "document", "email", "error", "field",
        "file", "fix", "function", "github", "google", "issue", "jira", "linear",
        "message", "model", "notion", "pane", "prompt", "pull", "request",
        "safari", "screen", "setting", "slack", "summary", "swift", "task",
        "test", "token", "user", "view", "xcode"
    ]

    /// How much a single OCR token says about the line it sits in.
    ///
    /// Three classes, not two, because "keep this token" and "this line is real" are different
    /// questions. `neutral` is the class that matters: a bare number, an identifier like `320d`,
    /// or a two-letter word says nothing about whether the line is genuine, but it is not junk
    /// either, and deleting it costs the completion the very word a reply would reuse.
    private enum OCRTokenClass {
        /// A real word, acronym, email address, domain/file token, or non-Latin text.
        case signal
        /// Carried along when the line qualifies: numbers, alphanumeric identifiers, short words.
        case neutral
        /// What OCR invents: repeated-glyph runs and short mixed-case blobs.
        case noise
    }

    /// Keeps or drops one OCR line. The line qualifies when it carries at least one signal token
    /// and fewer than half its tokens are noise; it then keeps every signal and neutral token in
    /// place — numbers, prices, times and identifiers included — and only the hallucinated tokens
    /// are removed. A line that does not qualify is dropped whole, chrome and all.
    private static func filterOCRNoiseLine(_ line: String) -> String? {
        let tokens = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let classified = tokens.map { (token: $0, class: classifyOCRToken($0)) }
        guard classified.contains(where: { $0.class == .signal }) else { return nil }

        // A majority of hallucinated tokens means the whole line is a hallucination. An even split
        // is not: two real words beside two OCR blobs is a real line with junk in it, and the junk
        // is removed below.
        let noiseCount = classified.filter { $0.class == .noise }.count
        guard noiseCount * 2 <= tokens.count else { return nil }

        let kept = classified.filter { $0.class != .noise }.map(\.token)
        let result = kept.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private static func classifyOCRToken(_ token: String) -> OCRTokenClass {
        let lowercasedToken = token.lowercased()

        // A bare number is neither evidence nor junk on its own. Inside a real line it is a price,
        // a time, a quarter, or an invoice number — the most quotable thing on the screen.
        if token.allSatisfy(\.isNumber) {
            return .neutral
        }

        if isEmailLikeToken(token) || isFileOrDomainLikeToken(token) {
            return .signal
        }

        if preservedTechnicalTokens.contains(lowercasedToken) || commonAcronyms.contains(token) {
            return .signal
        }

        // Short ALL-CAPS runs are currencies, tickers, and product acronyms (EUR, BMW, RTX, PDF):
        // vowel-free by nature, so the Latin heuristics below would sink them and take the whole
        // line with them. Mixed-case blobs are handled separately and stay noise.
        if isShortAllCapsToken(token) {
            return .signal
        }

        if isRepeatedGlyphJunk(token) {
            return .noise
        }

        // Non-Latin scripts (CJK, Cyrillic, Greek, Arabic, Hebrew, Thai, ...) and accented Latin
        // (café, Zürich, naïve) carry real context but have no ASCII vowel and never match the
        // English word lists, so the Latin-tuned heuristics below would strip them to nothing and
        // leave non-English users with no visual context at all.
        if containsNonASCIILetter(token) {
            return .signal
        }

        return classifyLatinToken(token, lowercased: lowercasedToken)
    }

    /// Classifies an ASCII-only token. Reached only after `classifyOCRToken` has handled numbers,
    /// emails, file/domain tokens, acronyms, repeated-glyph junk, and non-ASCII letters.
    private static func classifyLatinToken(_ token: String, lowercased lowercasedToken: String) -> OCRTokenClass {
        // A one or two letter token is never evidence that a line is real prose: a line of nothing
        // but "we go to it" is as likely to be UI chrome as a sentence, and the old filter dropped
        // it for that reason. Known short words ride along; unknown ones do too, since dropping
        // them would break up a line that qualifies on its longer words.
        if token.count <= 2 {
            return .neutral
        }

        // The mixed-case check runs before the alphanumeric one so a hallucinated blob that also
        // carries digits ("54tbdbDX") is still noise, while a short identifier ("Q3", "320d",
        // "RTX5070") has too few letters to trip it.
        if isLikelyShortMixedCaseNoise(token) {
            return .noise
        }

        // Letters and digits together: `Q3`, `320d`, `SCR-482` once the hyphen survives. Real when
        // the line around them is real, which is what `neutral` means.
        if containsLettersAndNumbers(token) {
            return containsKnownWordSignal(token) ? .signal : .neutral
        }

        return hasWordSignal(token) ? .signal : .neutral
    }

    /// True for a 2-6 character token written entirely in capital letters.
    private static func isShortAllCapsToken(_ token: String) -> Bool {
        guard (2...6).contains(token.count) else { return false }
        return token.allSatisfy { $0.isLetter && $0.isUppercase && $0.isASCII }
    }

    /// True when the token carries a letter outside ASCII: CJK, Cyrillic, Greek, Arabic, Hebrew,
    /// Thai, Devanagari, accented Latin, and so on. ASCII letters stay on the Latin-tuned path.
    private static func containsNonASCIILetter(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            scalar.value > 127 && CharacterSet.letters.contains(scalar)
        }
    }

    private static func isEmailLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return containsLetter(String(parts[0])) && isFileOrDomainLikeToken(String(parts[1]))
    }

    private static func isFileOrDomainLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.contains { containsLetter(String($0)) }
    }

    private static func containsLettersAndNumbers(_ token: String) -> Bool {
        containsLetter(token) && token.contains(where: \.isNumber)
    }

    private static func containsLetter(_ token: String) -> Bool {
        token.contains(where: \.isLetter)
    }

    private static func containsKnownWordSignal(_ token: String) -> Bool {
        let lowercasedToken = token.lowercased()
        return knownWordSignals.contains { lowercasedToken.contains($0) }
    }

    private static func hasWordSignal(_ token: String) -> Bool {
        guard containsLetter(token) else { return false }
        let lowercasedToken = token.lowercased()
        if containsKnownWordSignal(lowercasedToken) {
            return true
        }

        return lowercasedToken.unicodeScalars.contains { scalar in
            CharacterSet(charactersIn: "aeiouy").contains(scalar)
        }
    }

    private static func isRepeatedGlyphJunk(_ token: String) -> Bool {
        let scalars = token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard scalars.count >= 4 else { return false }

        var frequencies: [UnicodeScalar: Int] = [:]
        for scalar in scalars {
            frequencies[scalar, default: 0] += 1
        }

        let mostCommonCount = frequencies.values.max() ?? 0
        return mostCommonCount * 2 >= scalars.count
    }

    private static func isLikelyShortMixedCaseNoise(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard token.count <= 12, letters.count >= 4 else { return false }

        let uppercaseCount = letters.filter(\.isUppercase).count
        let lowercaseCount = letters.filter(\.isLowercase).count
        guard uppercaseCount > 0, lowercaseCount > 0 else { return false }

        if containsKnownWordSignal(token) {
            return false
        }

        // A single leading capital is normal prose ("Safari", "Cotabby"). Multiple capitals in
        // a short token without a known technical word is usually OCR garbage ("gLVWrt", "bDokE").
        let firstCharacterIsUppercase = letters.first?.isUppercase == true
        if firstCharacterIsUppercase && uppercaseCount == 1 {
            return false
        }

        return uppercaseCount >= 2 || !firstCharacterIsUppercase
    }

    private static func collapseInlineWhitespace(in line: String) -> String {
        let normalized = line.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
