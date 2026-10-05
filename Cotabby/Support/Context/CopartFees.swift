import Foundation

/// File overview:
/// What a Copart Germany purchase costs on top of the hammer price, from Copart's own fee table
/// ("Gebührenübersicht Copart Deutschland GmbH, Stand: Januar 2025", on copart.de under Hilfe >
/// Gebühren und Zahlungen). Every amount there is net, like the bids on the site.
///
/// Counted for a purchase:
/// - the buyer fee (Käufergebühr), stepped by the net sale price, 5% from 15,000 € with no cap;
/// - the online bid fee (Onlinegebotsgebühr), because the writer bids on copart.de (a bid placed at
///   the yard's kiosk would not pay it);
/// - the pickup fee (Bereitstellungsgebühr), due for every vehicle;
/// - the document fee (Bearbeitungsgebühr für Dokumente), when the lot lists vehicle documents.
/// Not counted, because they depend on what happens after the sale: storage after five working
/// days, late payment, relisting. The annual membership is not per purchase.
///
/// Pure. `VehiclePageWatcher` reads the current bid off a Copart lot page and
/// `PriceFeeOverlayController` shows the result beside it.
nonisolated enum CopartFees {
    struct Breakdown: Equatable, Sendable {
        let salePrice: Decimal
        let buyerFee: Decimal
        let onlineBidFee: Decimal
        let pickupFee: Decimal
        let documentFee: Decimal

        var fees: Decimal { buyerFee + onlineBidFee + pickupFee + documentFee }
        var total: Decimal { salePrice + fees }
    }

    /// Buyer fee steps: from this net sale price (inclusive) up to the next step, this fee.
    private static let buyerFeeSteps: [(from: Decimal, fee: Decimal)] = [
        (0.01, 1), (100, 25), (200, 50), (300, 75), (350, 100), (400, 110), (450, 120), (500, 130),
        (550, 140), (600, 150), (700, 160), (800, 170), (900, 180), (1000, 200), (1200, 210), (1300, 220),
        (1400, 230), (1500, 240), (1600, 250), (1700, 260), (1800, 270), (2000, 280), (2400, 290),
        (2500, 310), (3000, 350), (3500, 400), (4000, 440), (4500, 480), (5000, 500), (5500, 540),
        (6000, 580), (6500, 600), (7000, 620), (7500, 640), (8000, 650), (8500, 660), (9000, 670),
        (10000, 680), (10500, 690), (11000, 700), (11500, 720), (12000, 740), (12500, 760),
    ]
    /// From here the buyer fee is a share of the price, with no maximum.
    static let percentageFrom: Decimal = 15000
    static let percentage: Decimal = 0.05
    static let pickupFee: Decimal = 45
    static let documentFee: Decimal = 25

    static func buyerFee(salePrice: Decimal) -> Decimal {
        if salePrice >= percentageFrom { return rounded(salePrice * percentage) }
        return buyerFeeSteps.last { salePrice >= $0.from }?.fee ?? 0
    }

    /// 18 € up to 6,750.99 €, 25 € up to 13,500.99 €, 31 € above.
    static func onlineBidFee(salePrice: Decimal) -> Decimal {
        if salePrice < Decimal(string: "6751")! { return 18 }
        if salePrice < Decimal(string: "13501")! { return 25 }
        return 31
    }

    /// The fees for buying at `salePrice` (net), or nil for no price.
    static func breakdown(salePrice: Decimal, listsDocuments: Bool) -> Breakdown? {
        guard salePrice > 0 else { return nil }
        return Breakdown(salePrice: salePrice, buyerFee: buyerFee(salePrice: salePrice),
                         onlineBidFee: onlineBidFee(salePrice: salePrice), pickupFee: pickupFee,
                         documentFee: listsDocuments ? documentFee : 0)
    }

    /// The amount in a bid as the page shows it ("€12.500", "12.500 €", "€1.234,50"), or nil when it
    /// shows none (signed out it reads "€****").
    static func amount(fromBidText text: String) -> Decimal? {
        let kept = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard kept.contains(where: \.isNumber) else { return nil }
        var digits = kept
        var cents = ""
        // A comma (or a period) followed by exactly two digits at the end is the decimal mark.
        if let last = kept.lastIndex(where: { $0 == "," || $0 == "." }),
           kept.distance(from: last, to: kept.endIndex) == 3 {
            cents = String(kept[kept.index(after: last)...])
            digits = String(kept[..<last])
        }
        let whole = digits.filter(\.isNumber)
        guard !whole.isEmpty else { return nil }
        return Decimal(string: cents.isEmpty ? whole : "\(whole).\(cents)")
    }

    /// True unless the lot's "Fahrzeugdokumente" (a dashboard board's "Dokumente") says it has none.
    static func listsDocuments(pageTexts: [String]) -> Bool {
        let texts = pageTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let index = texts.firstIndex(where: {
            ["fahrzeugdokumente", "dokumente"].contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
        }), index + 1 < texts.count else { return true }
        let value = texts[index + 1].lowercased()
        return !(value.isEmpty || value == "-" || value.hasPrefix("keine") || value.hasPrefix("nein"))
    }

    /// "1.017 €", or "1.017,50 €" when there are cents.
    static func format(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        let hasCents = amount != rounded(amount, scale: 0)
        formatter.minimumFractionDigits = hasCents ? 2 : 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)") + " €"
    }

    private static func rounded(_ value: Decimal, scale: Int = 2) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }
}
