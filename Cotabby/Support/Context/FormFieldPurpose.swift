import Foundation

/// What a form field asks for, read from its own words: the placeholder and its accessible name
/// (the label a page ties to it, `aria-label`, or the DOM id). Pure; the coordinator uses it to
/// offer the email the writer just entered in a field that asks for it again
/// (`RecentEmailMemory`), and to stay silent in fields that want a code the writer must read off
/// something else (a CAPTCHA image, an SMS, an authenticator), where any suggestion is a guess.
nonisolated enum FormFieldPurpose: Equatable, Sendable {
    /// "Confirm email", "Repeat e-mail", `email2`, "E-Mail wiederholen".
    case repeatEmail
    case email
    /// CAPTCHA, one-time or verification code.
    case verificationCode
    case other

    static func classify(placeholder: String?, name: String?) -> FormFieldPurpose {
        let words = normalized([placeholder, name].compactMap { $0 }.joined(separator: " "))
        guard !words.isEmpty else { return .other }
        // Codes first: "verify" and "security" also appear in email and password wording.
        if codePhrases.contains(where: { words.contains($0) }) || hasWord(codeWords, in: words) {
            return .verificationCode
        }
        guard words.range(of: #"\be ?mail(?!ing)"#, options: .regularExpression) != nil
            || hasWord(emailWords, in: words) else { return .other }
        if repeatPhrases.contains(where: { words.contains($0) }) || hasWord(repeatWords, in: words)
            || words.range(of: #"\be ?mail ?(2|02)\b"#, options: .regularExpression) != nil {
            return .repeatEmail
        }
        return .email
    }

    /// Lowercased words separated by single spaces, with camelCase and snake_case ids split
    /// (`confirmEmail`, `email_confirm` → "confirm email", "email confirm").
    static func normalized(_ text: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in text {
            if character.isUppercase, let previous, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func hasWord(_ candidates: Set<String>, in words: String) -> Bool {
        words.split(separator: " ").contains { candidates.contains(String($0)) }
    }

    private static let codePhrases = [
        "captcha", "verification code", "verify code", "security code", "confirmation code",
        "one time", "authentication code", "auth code", "sms code", "login code", "access code",
        "enter the code", "enter code", "characters shown", "characters you see", "characters in the",
        "text in the image", "text shown", "letters shown",
        "bestätigungscode", "sicherheitscode", "verifizierungscode", "einmalcode", "zahlencode",
        "verificatiecode", "beveiligingscode", "bevestigingscode", "code de vérification",
        "code de sécurité", "code de confirmation", "código de verificación", "código de seguridad",
        "codice di verifica", "код подтверждения", "код за потвърждение", "проверочный код",
    ]
    private static let codeWords: Set<String> = ["otp", "totp", "2fa", "mfa", "tan", "pin"]
    private static let emailWords: Set<String> = [
        "courriel", "correo", "почта", "имейл", "емейл", "emailadres", "emailadresse", "mailadres",
        "mailadresse",
    ]
    private static let repeatPhrases = ["re enter", "type again", "enter again", "nochmals", "noch einmal"]
    private static let repeatWords: Set<String> = [
        "confirm", "confirmation", "repeat", "retype", "reenter", "again", "verify", "verification",
        "wiederholen", "wiederholung", "bestätigen", "bestätigung", "herhaal", "herhalen", "bevestig",
        "bevestigen", "bevestiging", "confirmer", "répéter", "confirmar", "repetir", "conferma",
        "ripeti", "повторите", "подтвердите", "повторете", "потвърдете",
    ]
}
