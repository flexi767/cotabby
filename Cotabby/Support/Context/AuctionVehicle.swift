import Foundation

/// File overview:
/// The vehicle on an auction page the writer works from, and the links that open a search for it in
/// scrapeui (topkoli.com): one for its mobile.bg saved search, one for that search's mobile.de
/// results. Two sources:
///
/// - The Informex offer page (`/auction`) lays its expert data out as label/value pairs of plain
///   text, measured on the live portal: "Merk" "AUDI", "Model" "Q6 e-tron (2024)", "Type"
///   "Q6 e-tron", "Eerste inschr" "26-05-2025". The French interface uses its own labels.
/// - A Copart lot page (`copart.de/lot/<number>`) does the same with colon labels, measured on the
///   live site: "Hersteller:" "BMW", "Modell:" "i7", "Jahr:" "2025", "Erstzulassung:" "26.05.2025".
///
/// A search uses make, model, and first-registration year (the writer chose: year +-1, applied by
/// scrapeui); Copart's model year stands in when a lot has no first registration.
///
/// Pure. The page watcher hands it the page's text in reading order; the presentation layer turns
/// the parsed vehicle into links. Nothing here sends anything: a link only opens when the writer
/// clicks it, in their own browser, where they are already signed in to scrapeui.
nonisolated struct AuctionVehicle: Equatable, Sendable {
    enum Source: String, Sendable {
        case informex
        case copart
    }

    let make: String
    /// The model as a search wants it. Informex: its "Type" when present ("Q6 e-tron"), else its
    /// "Model" without the trailing model-year ("Q6 e-tron (2024)" -> "Q6 e-tron"). Copart: "Modell".
    let model: String?
    /// Year of first registration (Copart: the model year when the lot shows no registration).
    let firstRegistrationYear: Int?
    var source: Source = .informex

    private static let informexLabels: [String: [String]] = [
        "make": ["merk", "marque"],
        "model": ["model", "modèle", "modele"],
        "type": ["type"],
        "firstRegistration": ["eerste inschr", "eerste inschrijving", "1ère immat", "1ere immat", "première immatriculation"],
    ]

    private static let copartLabels: [String: [String]] = [
        "make": ["hersteller", "marke", "make"],
        "model": ["modell", "model"],
        "year": ["jahr", "year"],
        "firstRegistration": ["erstzulassung", "first registration", "registration date"],
    ]

    /// The vehicle on an Informex offer page, or nil when the page names no make.
    static func parse(pageTexts: [String]) -> AuctionVehicle? {
        let values = labeledValues(in: pageTexts, labels: informexLabels)
        guard let make = values["make"], !make.isEmpty else { return nil }
        let model = (values["type"].flatMap(nonEmpty) ?? values["model"].map(withoutModelYear).flatMap(nonEmpty))
        return AuctionVehicle(make: make, model: model, firstRegistrationYear: values["firstRegistration"].flatMap(year))
    }

    /// The vehicle on a Copart lot page, or nil when the page names no make.
    static func parseCopart(pageTexts: [String]) -> AuctionVehicle? {
        let values = labeledValues(in: pageTexts, labels: copartLabels)
        guard let make = values["make"], !make.isEmpty else { return nil }
        let year = values["firstRegistration"].flatMap(year) ?? values["year"].flatMap(year)
        return AuctionVehicle(make: make, model: values["model"].flatMap(nonEmpty), firstRegistrationYear: year,
                              source: .copart)
    }

    /// True for a Copart lot page (any Copart country site): the host is copart.<tld> or a
    /// subdomain of it, and the path is `/lot/<number>`.
    static func isCopartLotURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              host.split(separator: ".").contains("copart") else { return false }
        return url.path.range(of: #"^/lot/\d+"#, options: .regularExpression) != nil
    }

    /// The value after each label (the text that follows it in reading order); the first occurrence
    /// of each label wins (the details block comes before any later mention). A label is matched
    /// without case and without a trailing colon or period.
    private static func labeledValues(in pageTexts: [String], labels: [String: [String]]) -> [String: String] {
        var values: [String: String] = [:]
        let texts = pageTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (index, text) in texts.enumerated() where index + 1 < texts.count {
            let label = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":. "))
            guard let key = labels.first(where: { $0.value.contains(label) })?.key, values[key] == nil else { continue }
            let value = texts[index + 1]
            let valueAsLabel = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":. "))
            guard !value.isEmpty, !labels.values.contains(where: { $0.contains(valueAsLabel) }) else { continue }
            values[key] = value
        }
        return values
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// "Q6 e-tron (2024)" -> "Q6 e-tron".
    static func withoutModelYear(_ model: String) -> String {
        model.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
    }

    /// The four-digit year in "26-05-2025", "2025-05-26", "26.05.2025", or "05/2025".
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

    func searchURL(for target: SearchTarget, base: URL = AuctionVehicle.scrapeuiBaseURL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(Self.fromVehiclePath),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "make", value: make)]
        if let model { items.append(URLQueryItem(name: "model", value: model)) }
        if let firstRegistrationYear { items.append(URLQueryItem(name: "year", value: String(firstRegistrationYear))) }
        items.append(URLQueryItem(name: "target", value: target.rawValue))
        items.append(URLQueryItem(name: "source", value: source.rawValue))
        components?.queryItems = items
        return components?.url
    }
}

/// One vehicle the panel shows: what it is (for the search links) and, on Copart, the fees for its
/// current bid. One per lot or offer page, one per board on Copart's live auction dashboard.
nonisolated struct AuctionLot: Equatable, Sendable {
    let vehicle: AuctionVehicle
    let fees: CopartFees.Breakdown?
}
