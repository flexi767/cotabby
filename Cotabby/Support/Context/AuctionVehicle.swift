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
    /// The fuel the search filters on (Informex "Brandstof"), nil when the page names none or one
    /// the search does not know.
    var fuel: Fuel?
    /// The expert data the address-bar panel shows in short (Informex only).
    var specs: Specs?

    /// The fuels scrapeui's search knows, by the code its link carries.
    enum Fuel: String, Sendable {
        case diesel, petrol, hybrid, electric, lpg

        /// One letter for the panel: D, B (Benzine), H, E, G (gas).
        var letter: String {
            switch self {
            case .diesel: "D"
            case .petrol: "B"
            case .hybrid: "H"
            case .electric: "E"
            case .lpg: "G"
            }
        }

        /// Reads Informex's "Brandstof" ("Diesel", "Benzine", "Elektrisch", "LPG", French
        /// "Essence", "Électrique", "GPL"). Every hybrid variant ("Hybride", "Hybride benzine",
        /// "Hybride diesel", "Plug-in hybride") is a hybrid, checked first, since "Hybride diesel"
        /// also names diesel.
        init?(brandstof: String) {
            let value = brandstof.lowercased()
            if value.contains("hybr") { self = .hybrid }
            else if value.contains("elektr") || value.contains("électr") || value.contains("electr") { self = .electric }
            else if value.contains("diesel") { self = .diesel }
            else if value.contains("benzine") || value.contains("essence") || value.contains("petrol") { self = .petrol }
            else if value.contains("lpg") || value.contains("gpl") { self = .lpg }
            else { return nil }
        }
    }

    /// Informex's expert data, as the page shows it: "28-08-2017", "85 kW", "1598 cc", "Diesel".
    struct Specs: Equatable, Sendable {
        var firstRegistration: String?
        var lastRegistration: String?
        var power: String?
        var displacement: String?
        var brandstof: String?

        /// Only the values, short: "08/17 · 03/20 · 85kW · 1598cc · D" (the writer's choice: no day,
        /// no label, one letter for the fuel, and no space before a unit). Empty parts are left
        /// out; nil when nothing is known.
        var summary: String? {
            let parts = [
                firstRegistration.map(Self.monthYear),
                lastRegistration.map(Self.monthYear),
                power.map { Self.compact($0, unit: "kW") },
                displacement.map { Self.compact($0, unit: "cc") },
                brandstof.map { Fuel(brandstof: $0)?.letter ?? $0 },
            ].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// "28-08-2017" (or "28.08.2017", "28/08/2017") -> "08/17"; anything else as shown.
        static func monthYear(_ date: String) -> String {
            let pattern = #"^\s*\d{1,2}[-./](\d{1,2})[-./](?:19|20)(\d{2})\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: date, range: NSRange(date.startIndex..., in: date)),
                  let month = Range(match.range(at: 1), in: date), let year = Range(match.range(at: 2), in: date)
            else { return date.trimmingCharacters(in: .whitespaces) }
            let monthText = String(date[month])
            return "\(monthText.count == 1 ? "0" + monthText : monthText)/\(date[year])"
        }

        /// "85 kW" -> "85kW", "1.598 cc" -> "1598cc": the first number with the unit; the value as
        /// shown when it has no number.
        static func compact(_ value: String, unit: String) -> String {
            guard let range = value.range(of: #"\d[\d.]*"#, options: .regularExpression) else {
                return value.trimmingCharacters(in: .whitespaces)
            }
            return value[range].replacingOccurrences(of: ".", with: "") + unit
        }
    }

    private static let informexLabels: [String: [String]] = [
        "make": ["merk", "marque"],
        "model": ["model", "modèle", "modele"],
        "type": ["type"],
        "firstRegistration": ["eerste inschr", "eerste inschrijving", "1ère immat", "1ere immat", "première immatriculation"],
        "lastRegistration": ["laatste inschr", "laatste inschrijving", "dernière immat", "derniere immat"],
        "power": ["vermogen", "puissance"],
        "displacement": ["cilinderinhoud", "cylindrée", "cylindree"],
        "fuel": ["brandstof", "carburant"],
    ]

    private static let copartLabels: [String: [String]] = [
        "make": ["hersteller", "marke", "make"],
        "model": ["modell", "model"],
        "year": ["jahr", "year"],
        "firstRegistration": ["erstzulassung", "erstzulassungsdatum", "first registration", "registration date"],
    ]

    /// Makes whose name is two words in a Copart title ("2019 Land Rover Discovery ..."); any other
    /// make is the title's first word after the year.
    private static let twoWordMakes: Set<String> = [
        "land rover", "alfa romeo", "aston martin", "rolls royce", "lynk &", "great wall",
    ]

    /// The vehicle on an Informex offer page, or nil when the page names no make.
    static func parse(pageTexts: [String]) -> AuctionVehicle? {
        let values = labeledValues(in: pageTexts, labels: informexLabels)
        guard let make = values["make"], !make.isEmpty else { return nil }
        let model = (values["type"].flatMap(nonEmpty) ?? values["model"].map(withoutModelYear).flatMap(nonEmpty))
        let specs = Specs(firstRegistration: values["firstRegistration"], lastRegistration: values["lastRegistration"],
                          power: values["power"], displacement: values["displacement"], brandstof: values["fuel"])
        return AuctionVehicle(make: make, model: model, firstRegistrationYear: values["firstRegistration"].flatMap(year),
                              fuel: values["fuel"].flatMap(Fuel.init(brandstof:)),
                              specs: specs.summary == nil ? nil : specs)
    }

    /// The vehicle on a Copart lot page, or nil when the page names no make.
    static func parseCopart(pageTexts: [String]) -> AuctionVehicle? {
        let values = labeledValues(in: pageTexts, labels: copartLabels)
        guard let make = values["make"], !make.isEmpty else { return nil }
        let year = values["firstRegistration"].flatMap(year) ?? values["year"].flatMap(year)
        return AuctionVehicle(make: make, model: values["model"].flatMap(nonEmpty), firstRegistrationYear: year,
                              source: .copart)
    }

    /// The car on one board of Copart's live auction dashboard, which shows a title ("2025 Toyota
    /// Corolla Touring Sports Hybrid Teamplayer") and a details list with
    /// "Erstzulassungsdatum" "29/09/2025" but no make or model fields: the make is the title's
    /// first word after the year (two for `twoWordMakes`), the model the word after it. The year is
    /// the first registration's, else the title's model year.
    static func parseCopartBoard(title: String, detailTexts: [String]) -> AuctionVehicle? {
        var words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        var titleYear: Int?
        if let first = words.first, first.count == 4, let year = Int(first), year > 1900 {
            titleYear = year
            words.removeFirst()
        }
        guard !words.isEmpty else { return nil }
        let makeLength = words.count > 1 && twoWordMakes.contains("\(words[0]) \(words[1])".lowercased()) ? 2 : 1
        let make = words.prefix(makeLength).joined(separator: " ")
        let model = words.count > makeLength ? words[makeLength] : nil
        let values = labeledValues(in: detailTexts, labels: copartLabels)
        return AuctionVehicle(make: make, model: model,
                              firstRegistrationYear: values["firstRegistration"].flatMap(year) ?? titleYear,
                              source: .copart)
    }

    /// True for Copart's live auction dashboard (`copart.<tld>/auctionDashboard`).
    static func isCopartDashboardURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              host.split(separator: ".").contains("copart") else { return false }
        return url.path.lowercased().hasPrefix("/auctiondashboard")
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
        if let fuel { items.append(URLQueryItem(name: "fuel", value: fuel.rawValue)) }
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
