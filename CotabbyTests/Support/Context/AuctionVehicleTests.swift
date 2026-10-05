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
                       AuctionVehicle(make: "AUDI", model: "Q6 e-tron", firstRegistrationYear: 2025))
    }

    func testFallsBackToTheModelWithoutItsYearAndReadsFrenchLabels() {
        let french = ["Marque", "BMW", "Modèle", "320d Touring (2019)", "1ère immat", "14/03/2019"]
        XCTAssertEqual(AuctionVehicle.parse(pageTexts: french),
                       AuctionVehicle(make: "BMW", model: "320d Touring", firstRegistrationYear: 2019))
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
