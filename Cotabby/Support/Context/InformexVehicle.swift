import Foundation

/// File overview:
/// The vehicle on an Informex offer page (`/auction`), and the links that open a search for it in
/// scrapeui (topkoli.com): one for its mobile.bg saved search, one for that search's mobile.de results.
///
/// The page lays its expert data out as label/value pairs of plain text, measured on the live
/// portal: "Merk" "AUDI", "Model" "Q6 e-tron (2024)", "Type" "Q6 e-tron", "Eerste inschr"
/// "26-05-2025", "KM" "75.848 KM". The French interface uses its own labels, so both are accepted.
/// Fuel and gearbox are not on the page, so a search uses make, model, and first-registration year
/// (the writer chose: year +-1, applied by scrapeui).
///
/// Pure. The focus resolver hands it the page's text in reading order; the presentation layer turns
/// the parsed vehicle into links. Nothing here sends anything: a link only opens when the writer
/// clicks it, in their own browser, where they are already signed in to scrapeui.
nonisolated struct InformexVehicle: Equatable, Sendable {
    let make: String
    /// The model as a search wants it: the page's "Type" when present ("Q6 e-tron"), else its
    /// "Model" without the trailing model-year ("Q6 e-tron (2024)" -> "Q6 e-tron").
    let model: String?
    /// Year of first registration ("Eerste inschr").
    let firstRegistrationYear: Int?

    private static let labels: [String: [String]] = [
        "make": ["merk", "marque"],
        "model": ["model", "modèle", "modele"],
        "type": ["type"],
        "firstRegistration": ["eerste inschr", "eerste inschrijving", "1ère immat", "1ere immat", "première immatriculation"],
    ]

    /// The vehicle described by the page text, or nil when the page names no make. The first
    /// occurrence of each label wins (the expert block comes before any later mention).
    static func parse(pageTexts: [String]) -> InformexVehicle? {
        var values: [String: String] = [:]
        let texts = pageTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (index, text) in texts.enumerated() where index + 1 < texts.count {
            let label = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":. "))
            guard let key = labels.first(where: { $0.value.contains(label) })?.key, values[key] == nil else { continue }
            let value = texts[index + 1]
            guard !value.isEmpty, !labels.values.contains(where: { $0.contains(value.lowercased()) }) else { continue }
            values[key] = value
        }
        guard let make = values["make"], !make.isEmpty else { return nil }
        let model = (values["type"].flatMap(nonEmpty) ?? values["model"].map(withoutModelYear).flatMap(nonEmpty))
        return InformexVehicle(make: make, model: model, firstRegistrationYear: values["firstRegistration"].flatMap(year))
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// "Q6 e-tron (2024)" -> "Q6 e-tron".
    static func withoutModelYear(_ model: String) -> String {
        model.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
    }

    /// The four-digit year in "26-05-2025", "2025-05-26", or "05/2025".
    static func year(_ date: String) -> Int? {
        guard let range = date.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(date[range])
    }

    // MARK: - Search links

    enum SearchTarget: String, CaseIterable, Sendable {
        case mobileBG = "mobile-bg"
        case mobileDE = "mobile-de"
    }

    static let scrapeuiBaseURL = URL(string: "https://topkoli.com")!
    /// The scrapeui page that turns plain vehicle details into a saved search (creating it, or reusing
    /// an identical one) and opens it: the saved search itself for mobile.bg, its mobile.de results
    /// for mobile.de. Without a locale prefix: scrapeui adds the signed-in user's own.
    static let fromVehiclePath = "/editown/saved-searches/from-vehicle"

    func searchURL(for target: SearchTarget, base: URL = InformexVehicle.scrapeuiBaseURL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(Self.fromVehiclePath),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "make", value: make)]
        if let model { items.append(URLQueryItem(name: "model", value: model)) }
        if let firstRegistrationYear { items.append(URLQueryItem(name: "year", value: String(firstRegistrationYear))) }
        items.append(URLQueryItem(name: "target", value: target.rawValue))
        items.append(URLQueryItem(name: "source", value: "informex"))
        components?.queryItems = items
        return components?.url
    }
}
