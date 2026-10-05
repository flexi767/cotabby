import XCTest
@testable import Cotabby

final class CopartFeesTests: XCTestCase {
    func testBuyerFeeFollowsTheStepsAtTheirEdges() {
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 50), 1)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 99.99), 1)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 100), 25)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 1999.99), 270)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 2000), 280)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 9999), 670)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 14999.99), 760)
    }

    func testFromFifteenThousandTheBuyerFeeIsFivePercentWithoutCap() {
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 15000), 750)
        XCTAssertEqual(CopartFees.buyerFee(salePrice: 72250), 3612.5)
    }

    func testOnlineBidFeeSteps() {
        XCTAssertEqual(CopartFees.onlineBidFee(salePrice: 6750.99), 18)
        XCTAssertEqual(CopartFees.onlineBidFee(salePrice: 6751), 25)
        XCTAssertEqual(CopartFees.onlineBidFee(salePrice: 13500.99), 25)
        XCTAssertEqual(CopartFees.onlineBidFee(salePrice: 13501), 31)
    }

    func testABreakdownAddsPickupAndDocumentsWhenListed() throws {
        let withDocuments = try XCTUnwrap(CopartFees.breakdown(salePrice: 12500, listsDocuments: true))
        XCTAssertEqual(withDocuments.fees, 760 + 25 + 45 + 25)
        XCTAssertEqual(withDocuments.total, 12500 + 855)
        XCTAssertEqual(CopartFees.breakdown(salePrice: 12500, listsDocuments: false)?.fees, 830)
        XCTAssertNil(CopartFees.breakdown(salePrice: 0, listsDocuments: true))
    }

    func testReadsTheBidAsThePageShowsIt() {
        XCTAssertEqual(CopartFees.amount(fromBidText: "€12.500"), 12500)
        XCTAssertEqual(CopartFees.amount(fromBidText: "12.500 €"), 12500)
        XCTAssertEqual(CopartFees.amount(fromBidText: "€1.234,50"), Decimal(string: "1234.50"))
        XCTAssertEqual(CopartFees.amount(fromBidText: "€850"), 850)
        XCTAssertNil(CopartFees.amount(fromBidText: "€****"))
    }

    func testDocumentsAreAssumedUnlessTheLotSaysNone() {
        XCTAssertTrue(CopartFees.listsDocuments(pageTexts: ["Fahrzeugdokumente:", "ZB1 , ZB2 , COC (P)"]))
        XCTAssertFalse(CopartFees.listsDocuments(pageTexts: ["Fahrzeugdokumente:", "Keine"]))
        XCTAssertTrue(CopartFees.listsDocuments(pageTexts: ["Kilometerstand:", "43.184 Km"]))
    }

    func testFormatsGermanEuros() {
        XCTAssertEqual(CopartFees.format(1017), "1.017 €")
        XCTAssertEqual(CopartFees.format(3612.5), "3.612,50 €")
    }
}
