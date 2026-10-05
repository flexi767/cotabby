import AppKit
import ApplicationServices
import Foundation

/// Watches Opera for an auction page with a vehicle on it, so the vehicle search buttons (and, on
/// Copart, the fees and total for the current bid) can sit in Opera's address bar while the page is
/// in front. Two pages (`PageKind`): the Informex offer page and a Copart lot page.
///
/// The panel sits in the address bar rather than on the page: it never covers what the writer is
/// reading, and it does not move when the page scrolls, so nothing has to follow the page.
///
/// Runs only while Opera is the frontmost app, the browser these portals are used in (app switches
/// are observed, so no timer runs at all elsewhere, Chrome and other browsers included). Off the
/// pages it looks every `lookInterval` (3 s): it asks Opera for its focused window and reads its
/// title, and only when the title names Informex or Copart finds the page (its web area), checks the
/// page address and reads the vehicle (`AuctionVehicle`). That walk runs once per page; afterwards
/// each tick (`interval`, 1 s) reads the focused window, its title, the page address, the address
/// bar's frame and whether the writer is typing in it, and on Copart the current bid.
///
/// Owned by `CotabbyAppEnvironment`, started by `AppDelegate`, which forwards each change to
/// `VehicleSearchOverlayController`. Reads only; it never writes to the page.
@MainActor
final class VehiclePageWatcher {
    struct Placement: Equatable {
        /// The vehicles on the page, in page order. Copart: each with the fees for its current bid,
        /// nil while no bid is shown (or signed out).
        let lots: [AuctionLot]
        /// Opera's address bar, Cocoa coordinates.
        let addressBarFrame: CGRect
        let browserBundleIdentifier: String?
    }

    /// The pages the watcher recognizes, from the window title down to the vehicle.
    enum PageKind: CaseIterable {
        case informex
        case copart

        /// Matched in the window title (case-insensitive) before any page walk.
        var titleKeyword: String {
            switch self {
            case .informex: "informex"
            case .copart: "copart"
            }
        }

        func applies(toURL url: String) -> Bool {
            switch self {
            case .informex: VATCounterpartRule.applies(toURL: url)
            case .copart: AuctionVehicle.isCopartLotURL(url)
            }
        }

        func vehicle(in texts: [String]) -> AuctionVehicle? {
            switch self {
            case .informex: AuctionVehicle.parse(pageTexts: texts)
            case .copart: AuctionVehicle.parseCopart(pageTexts: texts)
            }
        }
    }

    /// Called with the new placement whenever it changes; nil hides the panel.
    var onChange: ((Placement?) -> Void)?

    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var lastPlacement: Placement?
    private var activationObserver: NSObjectProtocol?
    private var page: CachedPage?

    private struct CachedPage {
        let kind: PageKind
        let processIdentifier: pid_t
        let window: AXUIElement
        let webArea: AXUIElement
        let url: String
        let vehicle: AuctionVehicle
        /// The address bar (its frame places the panel) and the text field inside it (focused while
        /// the writer types an address: the panel then steps aside).
        let addressBar: AXUIElement
        let addressField: AXUIElement
        /// Copart: the text of the current bid (`.bidding-heading`), and whether the lot lists vehicle
        /// documents (the document fee). The bid box renders after the rest of the page and may be
        /// re-rendered, so a missing or dead element is looked for again every few ticks.
        var bidText: AXUIElement?
        var ticksUntilBidSearch = 0
        let listsDocuments: Bool
    }

    /// Ticks between searches for a Copart bid element that is missing (one bounded page walk).
    static let ticksPerBidSearch = 5

    /// On a page: how often the panel is refreshed (window moved, bid changed, page left).
    static let interval: TimeInterval = 1
    /// Off the pages: how often Opera's focused window title is read to find one.
    static let lookInterval: TimeInterval = 3

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimerForFrontmostApp() }
        }
        updateTimerForFrontmostApp()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        stopTimer()
        publish(nil)
    }

    /// Runs the timer only while Opera is in front; anywhere else the panel is not wanted, so
    /// nothing is polled and the timer does not wake the app. Activating Opera looks at once.
    private func updateTimerForFrontmostApp() {
        guard BrowserAppDetector.isOpera(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else {
            stopTimer()
            page = nil
            publish(nil)
            return
        }
        guard timer == nil else { return }
        tick()
    }

    /// Arms the timer at `interval`, or leaves it when it already runs at that rate.
    private func scheduleTimer(interval: TimeInterval) {
        guard timer == nil || timerInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerInterval = nil
    }

    private func tick() {
        publish(currentPlacement())
        scheduleTimer(interval: page == nil ? Self.lookInterval : Self.interval)
    }

    private func publish(_ placement: Placement?) {
        guard placement != lastPlacement else { return }
        lastPlacement = placement
        onChange?(placement)
    }

    private func currentPlacement() -> Placement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              BrowserAppDetector.isOpera(bundleIdentifier: app.bundleIdentifier) else {
            page = nil
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = Self.element(kAXFocusedWindowAttribute as CFString, on: appElement),
              let title = AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: window),
              let kind = PageKind.allCases.first(where: { title.localizedCaseInsensitiveContains($0.titleKeyword) })
        else {
            page = nil
            return nil
        }

        // The same page in the same window as last tick: no walk (save a missing Copart bid's).
        if var cached = page, cached.kind == kind, cached.processIdentifier == pid, CFEqual(cached.window, window),
           Self.url(of: cached.webArea) == cached.url {
            if cached.kind == .copart, cached.bidText == nil {
                cached.ticksUntilBidSearch -= 1
                if cached.ticksUntilBidSearch <= 0 {
                    cached.bidText = Self.copartBidText(in: cached.webArea)
                    cached.ticksUntilBidSearch = Self.ticksPerBidSearch
                }
            }
            let result = placement(for: &cached, browser: app.bundleIdentifier)
            page = cached
            return result
        }

        page = nil
        guard let webArea = Self.firstDescendant(of: window, limit: 3000, where: { node in
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXWebArea"
        }), let url = Self.url(of: webArea), kind.applies(toURL: url),
              let (addressBar, addressField) = Self.addressBar(in: window) else { return nil }
        let texts = Self.texts(in: webArea)
        guard let vehicle = kind.vehicle(in: texts) else { return nil }
        let bidText = kind == .copart ? Self.copartBidText(in: webArea) : nil
        var cached = CachedPage(kind: kind, processIdentifier: pid, window: window, webArea: webArea, url: url,
                                vehicle: vehicle, addressBar: addressBar, addressField: addressField,
                                bidText: bidText, ticksUntilBidSearch: Self.ticksPerBidSearch,
                                listsDocuments: CopartFees.listsDocuments(pageTexts: texts))
        let result = placement(for: &cached, browser: app.bundleIdentifier)
        page = cached
        return result
    }

    /// Nil while the writer types in the address bar (the panel would cover the address).
    private func placement(for page: inout CachedPage, browser: String?) -> Placement? {
        guard let bar = AXHelper.rectValue(for: "AXFrame" as CFString, on: page.addressBar), bar.width > 0,
              !Self.isFocused(page.addressField) else { return nil }
        var fees: CopartFees.Breakdown?
        if let bidText = page.bidText {
            if let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: bidText) {
                fees = CopartFees.amount(fromBidText: text)
                    .flatMap { CopartFees.breakdown(salePrice: $0, listsDocuments: page.listsDocuments) }
            } else {
                page.bidText = nil  // re-rendered: look for it again
            }
        }
        return Placement(lots: [AuctionLot(vehicle: page.vehicle, fees: fees)],
                         addressBarFrame: AXHelper.cocoaRect(fromAccessibilityRect: bar),
                         browserBundleIdentifier: browser)
    }

    // MARK: - AX helpers

    /// Opera's address bar: the first text field of the window's toolbar ("Address bar", measured
    /// in Opera 2026: x 154-1546 in a 1920 pt window, Opera's own icons from x 1552), and the text
    /// field inside it that takes focus while an address is typed ("Address field").
    private static func addressBar(in window: AXUIElement) -> (AXUIElement, AXUIElement)? {
        func role(_ node: AXUIElement) -> String? { AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) }
        guard let toolbar = firstDescendant(of: window, limit: 400, where: { role($0) == "AXToolbar" }),
              let bar = firstDescendant(of: toolbar, limit: 200, where: { role($0) == "AXTextField" }) else { return nil }
        let field = firstDescendant(of: bar, limit: 50, where: { role($0) == "AXTextField" }) ?? bar
        return (bar, field)
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    /// The current bid's text on a Copart lot page (`div.bidding-heading`, "€12.500").
    private static func copartBidText(in webArea: AXUIElement) -> AXUIElement? {
        guard let bid = firstDescendant(of: webArea, limit: 4000, where: { node in
            AXHelper.stringArrayValue(for: "AXDOMClassList" as CFString, on: node)?.contains("bidding-heading") == true
        }) else { return nil }
        return AXHelper.childElements(of: bid).first { child in
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: child) == "AXStaticText"
        } ?? bid
    }

    private static func element(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func url(of webArea: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    /// Breadth-first, at most `limit` nodes: the page tree is large and this runs on the main actor.
    private static func firstDescendant(
        of root: AXUIElement, limit: Int, where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < limit {
            let node = queue[index]
            index += 1
            if index > 1, matches(node) { return node }
            queue += AXHelper.childElements(of: node)
        }
        return nil
    }

    /// The page's static text in reading order (bounded).
    private static func texts(in webArea: AXUIElement) -> [String] {
        var texts: [String] = []
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard visited < 3000, depth < 40 else { return }
            visited += 1
            if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXStaticText",
               let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: node), !text.isEmpty {
                texts.append(text)
            }
            for child in AXHelper.childElements(of: node) { walk(child, depth: depth + 1) }
        }
        walk(webArea, depth: 0)
        return texts
    }
}
