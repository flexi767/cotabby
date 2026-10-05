import ApplicationServices
import Foundation

/// Reads the cars on Copart's live auction dashboard (`copart.de/auctionDashboard`): one per joined
/// board (lane A, lane B, ...), each with its title, details and live bid, so the vehicle panel can
/// show search buttons and fees per car.
///
/// Measured on the live dashboard (Opera, "Groß" view), per board: `#lotDesc-<sale><lane>` holds the
/// title ("2025 Toyota Corolla Touring Sports Hybrid Teamplayer"), `#lot-details-wrapper-<sale><lane>`
/// the label/value details ("Erstzulassungsdatum" "29/09/2025", "Dokumente" "ZB1, ZB2, ..."), and a
/// `.auctionrunningdiv-*` box the live bid among a few status words ("€12.600" "Bieten!" "Litauen").
/// Each board also lists upcoming lots, which reuse the `lotDesc-` id inside
/// `.megaFutureLotAreaWrapper`; that whole area is skipped. (`lot-description-watching` is not a
/// marker of upcoming lots: it marks any lot the writer watches, measured on board A's own title.)
///
/// The elements are found once (a bounded walk of the page that skips upcoming lots and the footer)
/// and kept: each tick then reads a board's title (to notice the next car) and walks only its small
/// bid box. A title that no longer reads means the board was re-rendered or left, and the elements
/// are looked for again; with no boards joined the walk repeats every few ticks.
///
/// Owned by `VehiclePageWatcher`, which resets it for every new page. Reads only.
@MainActor
final class CopartDashboardReader {
    private struct Board {
        let titleText: AXUIElement
        let details: AXUIElement?
        let bidBox: AXUIElement?
        var title = ""
        var vehicle: AuctionVehicle?
        var listsDocuments = true
        var addsVAT = false
    }

    private var boards: [Board] = []
    private var ticksUntilSearch = 0
    /// Ticks between page walks while no board is found (no auction joined yet).
    static let ticksPerSearch = 3

    nonisolated deinit {}

    func reset() {
        boards = []
        ticksUntilSearch = 0
    }

    /// The cars on the boards, in page order, each with the fees for its current bid.
    func lots(in webArea: AXUIElement) -> [AuctionLot] {
        if boards.isEmpty || !refreshTitles() {
            ticksUntilSearch -= 1
            guard ticksUntilSearch <= 0 else { return [] }
            ticksUntilSearch = Self.ticksPerSearch
            boards = Self.findBoards(in: webArea)
            guard refreshTitles() else { boards = []; return [] }
        }
        return boards.compactMap { board in
            guard let vehicle = board.vehicle else { return nil }
            let fees = board.bidBox.flatMap(Self.bid(in:))
                .flatMap { CopartFees.breakdown(salePrice: $0, listsDocuments: board.listsDocuments, addsVAT: board.addsVAT) }
            return AuctionLot(vehicle: vehicle, fees: fees)
        }
    }

    /// Re-reads every board's title, and its details when the car changed. False when a title no
    /// longer reads (the board was re-rendered or closed).
    private func refreshTitles() -> Bool {
        for index in boards.indices {
            guard let title = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: boards[index].titleText) else {
                return false
            }
            guard title != boards[index].title else { continue }
            let details = boards[index].details.map { Self.texts(in: $0, limit: 400) } ?? []
            boards[index].title = title
            boards[index].vehicle = AuctionVehicle.parseCopartBoard(title: title, detailTexts: details)
            boards[index].listsDocuments = CopartFees.listsDocuments(pageTexts: details)
            boards[index].addsVAT = CopartFees.addsVAT(pageTexts: details)
        }
        return true
    }

    /// The live bid in a board's bid box: its first text with an amount ("€12.600").
    private static func bid(in box: AXUIElement) -> Decimal? {
        for text in texts(in: box, limit: 40) where text.contains("€") {
            if let amount = CopartFees.amount(fromBidText: text) { return amount }
        }
        return nil
    }

    // MARK: - Finding the boards

    /// One walk of the page, in document order: the boards' title blocks, details lists and bid
    /// boxes, paired by order (each board has exactly one of each).
    private static func findBoards(in webArea: AXUIElement) -> [Board] {
        var titles: [AXUIElement] = []
        var details: [AXUIElement] = []
        var bidBoxes: [AXUIElement] = []
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard visited < 6000, depth < 60 else { return }
            visited += 1
            let identifier = AXHelper.stringValue(for: "AXDOMIdentifier" as CFString, on: node) ?? ""
            let classes = AXHelper.stringArrayValue(for: "AXDOMClassList" as CFString, on: node) ?? []
            if classes.contains(where: skippedClasses.contains) { return }
            if identifier.hasPrefix("lotDesc-") {
                if let title = firstStaticText(in: node) { titles.append(title) }
                return
            }
            if identifier.hasPrefix("lot-details-wrapper-") {
                details.append(node)
                return
            }
            if classes.contains(where: { $0.hasPrefix("auctionrunningdiv") }) {
                bidBoxes.append(node)
                return
            }
            for child in AXHelper.childElements(of: node) { walk(child, depth: depth + 1) }
        }
        walk(webArea, depth: 0)
        return titles.enumerated().map { index, title in
            Board(titleText: title,
                  details: details.indices.contains(index) ? details[index] : nil,
                  bidBox: bidBoxes.indices.contains(index) ? bidBoxes[index] : nil)
        }
    }

    /// Subtrees with no board in them: upcoming lots, the footer, the image strips.
    private static let skippedClasses: Set<String> = [
        "megaFutureLotAreaWrapper", "futureLot", "footer-container", "img-thumbnail-item",
    ]

    private static func firstStaticText(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < 30 {
            let node = queue[index]
            index += 1
            if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXStaticText" { return node }
            queue += AXHelper.childElements(of: node)
        }
        return nil
    }

    /// The static text under `root` in reading order, at most `limit` nodes visited.
    private static func texts(in root: AXUIElement, limit: Int) -> [String] {
        var texts: [String] = []
        var visited = 0
        func walk(_ node: AXUIElement) {
            guard visited < limit else { return }
            visited += 1
            if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXStaticText",
               let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: node), !text.isEmpty {
                texts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            for child in AXHelper.childElements(of: node) { walk(child) }
        }
        walk(root)
        return texts
    }
}
