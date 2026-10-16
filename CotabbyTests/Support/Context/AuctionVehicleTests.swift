@testable import Cotabby
import XCTest

final class AuctionVehicleTests: XCTestCase {
    /// The page text in reading order, as measured on the live offer page (abridged).
    private let livePage = [
        "Informex Vehicle Online", "Aanvraag offertes", "SY9523", "AUDI Q6 e-tron (2024)", "Nr Informex", "3266676",
        "Voertuiggegevens van de deskundige", "Merk", "AUDI", "Model", "Q6 e-tron (2024)", "Type", "Q6 e-tron",
        "Nummerplaat", "SY9523", "VIN", "WAUZZZGF7SA062789", "Eerste inschr", "26-05-2025", "KM", "75.848 KM",
        "Mijn offerte (marge)", "Mijn offerte",
    ]

    func testReadsTheExpertVehicleData() {
        XCTAssertEqual(AuctionVehicle.parse(pageTexts: livePage),
                       AuctionVehicle(make: "AUDI", model: "Q6 e-tron", firstRegistrationYear: 2025,
                                      specs: AuctionVehicle.Specs(firstRegistration: "26-05-2025")))
    }

    func testFallsBackToTheModelWithoutItsYearAndReadsFrenchLabels() {
        let french = ["Marque", "BMW", "Modèle", "320d Touring (2019)", "1ère immat", "14/03/2019"]
        XCTAssertEqual(AuctionVehicle.parse(pageTexts: french),
                       AuctionVehicle(make: "BMW", model: "320d Touring", firstRegistrationYear: 2019,
                                      specs: AuctionVehicle.Specs(firstRegistration: "14/03/2019")))
    }

    /// The expert data block with the registration, power, displacement and fuel rows (live labels).
    private let expertData = [
        "Merk", "VOLKSWAGEN", "Model", "Golf (2017)", "Eerste inschr", "28-08-2017", "Laatste inschr", "03-03-2020",
        "Vermogen", "85 kW", "Cilinderinhoud", "1598 cc", "Brandstof", "Diesel", "KM", "75.848 KM",
    ]

    func testShowsTheExpertDataAsShortValues() throws {
        let vehicle = try XCTUnwrap(AuctionVehicle.parse(pageTexts: expertData))
        XCTAssertEqual(vehicle.specs?.summary, "08/17 · 03/20 · 85kW · 1598cc · D")
        XCTAssertEqual(vehicle.fuel, .diesel)
        XCTAssertEqual(vehicle.firstRegistrationYear, 2017)
    }

    func testEveryHybridVariantIsAHybridAndEachFuelHasItsLetter() {
        for brandstof in ["Hybride", "Hybride benzine", "Hybride diesel", "Plug-in hybride", "HYBRIDE ESSENCE"] {
            XCTAssertEqual(AuctionVehicle.Fuel(brandstof: brandstof), .hybrid, brandstof)
        }
        let letters = ["Diesel": "D", "Benzine": "B", "Elektrisch": "E", "LPG": "G", "Essence": "B", "Électrique": "E"]
        for (brandstof, letter) in letters {
            XCTAssertEqual(AuctionVehicle.Fuel(brandstof: brandstof)?.letter, letter, brandstof)
        }
        XCTAssertNil(AuctionVehicle.Fuel(brandstof: "Waterstof"), "an unknown fuel sets no filter")
    }

    func testShortensWhatItCanAndKeepsTheRest() {
        typealias Specs = AuctionVehicle.Specs
        XCTAssertEqual(Specs.monthYear("5.3.2020"), "03/20")
        XCTAssertEqual(Specs.monthYear("onbekend"), "onbekend")
        XCTAssertEqual(Specs.compact("85 kW (116 pk)", unit: "kW"), "85kW")
        XCTAssertEqual(Specs.compact("1.598 cm³", unit: "cc"), "1598cc")
        XCTAssertEqual(Specs(brandstof: "Waterstof").summary, "Waterstof", "an unknown fuel is shown as written")
        XCTAssertEqual(Specs(firstRegistration: "28-08-2017").summary, "08/17", "missing rows are left out")
        XCTAssertNil(Specs().summary)
        XCTAssertNil(AuctionVehicle.parse(pageTexts: livePage.filter { $0 != "Eerste inschr" && $0 != "26-05-2025" })?.specs,
                     "a page without any of these rows shows no details pill")
    }

    func testTheSearchLinkCarriesTheFuel() throws {
        let vehicle = try XCTUnwrap(AuctionVehicle.parse(pageTexts: expertData.map { $0 == "Diesel" ? "Hybride benzine" : $0 }))
        let items = URLComponents(url: try XCTUnwrap(vehicle.searchURL(for: .mobileBG)), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "fuel" }?.value, "hybrid")
        XCTAssertFalse(try XCTUnwrap(AuctionVehicle.parse(pageTexts: livePage)?.searchURL(for: .mobileBG))
            .absoluteString.contains("fuel="), "no Brandstof, no fuel filter")
    }

    func testNoMakeNoVehicle() {
        XCTAssertNil(AuctionVehicle.parse(pageTexts: ["Model", "Q6", "Eerste inschr", "2025"]))
        XCTAssertNil(AuctionVehicle.parse(pageTexts: ["Merk", "Model", "Q6"]), "an empty value is not the next label")
    }

    /// The Copart lot page's text in reading order, as measured on copart.de/lot/50708766 (abridged).
    private let copartLot = [
        "Ein Fahrzeug finden", "Modelle", "2025 BMW i7 eDrive 50 Design Pure Excellence", "Motor startet",
        "FIN:", "WBY41EJ070C******", "Kilometerstand:", "43.184 Km", "Kraftstoff:", "Elektrisch",
        "Erstzulassung:", "26.05.2025", "Vollständige Fahrzeugdetails", "FIN:", "WBY41EJ070C******",
        "Hersteller:", "BMW", "Modell:", "i7", "Jahr:", "2025", "Ausführung:", "eDrive 50 Design Pure Excellence",
    ]

    func testReadsACopartLot() {
        XCTAssertEqual(AuctionVehicle.parseCopart(pageTexts: copartLot),
                       AuctionVehicle(make: "BMW", model: "i7", firstRegistrationYear: 2025, source: .copart))
    }

    func testACopartLotWithoutRegistrationUsesItsModelYear() {
        let lot = ["Hersteller:", "AUDI", "Modell:", "A4", "Jahr:", "2019", "Erstzulassung:", "-"]
        XCTAssertEqual(AuctionVehicle.parseCopart(pageTexts: lot)?.firstRegistrationYear, 2019)
    }

    func testRecognizesCopartLotAddresses() {
        XCTAssertTrue(AuctionVehicle.isCopartLotURL("https://www.copart.de/lot/50708766"))
        XCTAssertTrue(AuctionVehicle.isCopartLotURL("https://www.copart.de/lot/50708766?_gl=1*qc0neg"))
        XCTAssertTrue(AuctionVehicle.isCopartLotURL("https://www.copart.co.uk/lot/123/2019-bmw"))
        XCTAssertFalse(AuctionVehicle.isCopartLotURL("https://www.copart.de/lotSearchResults?query=bmw"))
        XCTAssertFalse(AuctionVehicle.isCopartLotURL("https://notcopart.example.com/lot/1"))
    }

    /// A board of the live auction dashboard, as measured (abridged): title, then details.
    func testReadsADashboardBoard() {
        let details = ["Standort", "Berlin", "Erstzulassungsdatum", "29/09/2025", "Tachostand", "46.745 km",
                       "Dokumente", "ZB1, ZB2, Konformitätsbescheinigung"]
        XCTAssertEqual(AuctionVehicle.parseCopartBoard(title: "2025 Toyota Corolla Touring Sports Hybrid Teamplayer",
                                                       detailTexts: details),
                       AuctionVehicle(make: "Toyota", model: "Corolla", firstRegistrationYear: 2025, source: .copart))
        XCTAssertEqual(AuctionVehicle.parseCopartBoard(title: "2019 Land Rover Discovery Sport", detailTexts: [])?.make,
                       "Land Rover")
        XCTAssertEqual(AuctionVehicle.parseCopartBoard(title: "2024 Opel Movano C Kasten", detailTexts: [])?
            .firstRegistrationYear, 2024, "no registration listed: the title's model year")
        XCTAssertNil(AuctionVehicle.parseCopartBoard(title: "2024", detailTexts: []))
    }

    func testRecognizesTheAuctionDashboard() {
        XCTAssertTrue(AuctionVehicle.isCopartDashboardURL("https://www.copart.de/auctionDashboard"))
        XCTAssertTrue(AuctionVehicle.isCopartDashboardURL("https://www.copart.de/auctionDashboard?auctionDetails=x"))
        XCTAssertFalse(AuctionVehicle.isCopartDashboardURL("https://www.copart.de/lot/50708766"))
    }

    func testACopartLinkNamesItsSource() throws {
        let url = try XCTUnwrap(AuctionVehicle(make: "BMW", model: "i7", firstRegistrationYear: 2025, source: .copart)
            .searchURL(for: .mobileDE))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "source" }?.value, "copart")
    }

    func testBuildsTheScrapeuiLinks() throws {
        let vehicle = AuctionVehicle(make: "AUDI", model: "Q6 e-tron", firstRegistrationYear: 2025)
        let url = try XCTUnwrap(vehicle.searchURL(for: .mobileBG))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "topkoli.com")
        XCTAssertEqual(url.path, "/editown/saved-searches/from-vehicle")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["make": "AUDI", "model": "Q6 e-tron", "year": "2025", "target": "mobile-bg", "source": "informex"])
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(vehicle.searchURL(for: .mobileDE)), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "target" }?.value, "mobile-de")
        XCTAssertFalse(AuctionVehicle(make: "VW", model: nil, firstRegistrationYear: nil)
            .searchURL(for: .mobileBG)!.absoluteString.contains("model="), "absent details are left out")
    }
}

@MainActor
final class VehicleSearchIconTrimTests: XCTestCase {
    /// A 32x32 image with an opaque 20x20 square inside a transparent margin, like mobile.bg's favicon.
    private func paddedIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.white.setFill()
        NSRect(x: 6, y: 6, width: 20, height: 20).fill()
        image.unlockFocus()
        return image
    }

    func testTransparentMarginsAreTrimmedSoNoBackgroundShowsAround() throws {
        let trimmed = VehicleSearchOverlayController.trimmingTransparentMargins(paddedIcon())
        let cg = try XCTUnwrap(trimmed.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let original = try XCTUnwrap(paddedIcon().cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThan(cg.width, original.width)
        XCTAssertEqual(Double(cg.width) / Double(original.width), 20.0 / 32.0, accuracy: 0.05)
    }
}
