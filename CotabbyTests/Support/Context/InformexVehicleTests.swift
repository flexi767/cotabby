@testable import Cotabby
import XCTest

final class InformexVehicleTests: XCTestCase {
    /// The page text in reading order, as measured on the live offer page (abridged).
    private let livePage = [
        "Informex Vehicle Online", "Aanvraag offertes", "SY9523", "AUDI Q6 e-tron (2024)", "Nr Informex", "3266676",
        "Voertuiggegevens van de deskundige", "Merk", "AUDI", "Model", "Q6 e-tron (2024)", "Type", "Q6 e-tron",
        "Nummerplaat", "SY9523", "VIN", "WAUZZZGF7SA062789", "Eerste inschr", "26-05-2025", "KM", "75.848 KM",
        "Mijn offerte (marge)", "Mijn offerte",
    ]

    func testReadsTheExpertVehicleData() {
        XCTAssertEqual(InformexVehicle.parse(pageTexts: livePage),
                       InformexVehicle(make: "AUDI", model: "Q6 e-tron", firstRegistrationYear: 2025))
    }

    func testFallsBackToTheModelWithoutItsYearAndReadsFrenchLabels() {
        let french = ["Marque", "BMW", "Modèle", "320d Touring (2019)", "1ère immat", "14/03/2019"]
        XCTAssertEqual(InformexVehicle.parse(pageTexts: french),
                       InformexVehicle(make: "BMW", model: "320d Touring", firstRegistrationYear: 2019))
    }

    func testNoMakeNoVehicle() {
        XCTAssertNil(InformexVehicle.parse(pageTexts: ["Model", "Q6", "Eerste inschr", "2025"]))
        XCTAssertNil(InformexVehicle.parse(pageTexts: ["Merk", "Model", "Q6"]), "an empty value is not the next label")
    }

    func testBuildsTheScrapeuiLinks() throws {
        let vehicle = InformexVehicle(make: "AUDI", model: "Q6 e-tron", firstRegistrationYear: 2025)
        let url = try XCTUnwrap(vehicle.searchURL(for: .mobileBG))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "topkoli.com")
        XCTAssertEqual(url.path, "/editown/saved-searches/from-vehicle")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["make": "AUDI", "model": "Q6 e-tron", "year": "2025", "target": "mobile-bg", "source": "informex"])
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(vehicle.searchURL(for: .mobileDE)), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "target" }?.value, "mobile-de")
        XCTAssertFalse(InformexVehicle(make: "VW", model: nil, firstRegistrationYear: nil)
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
