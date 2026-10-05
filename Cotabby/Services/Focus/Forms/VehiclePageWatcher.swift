import AppKit
import ApplicationServices
import Foundation

/// Watches for an auction page with a vehicle in the frontmost browser, so the vehicle search
/// buttons can sit beside it as soon as the page is in front, without the writer clicking anything.
/// Two pages (`PageKind`): the Informex offer page, where the buttons sit beside the "Mijn offerte"
/// field, and a Copart lot page, where they sit beside the lot title.
///
/// The focus tracker only describes the focused text field, which is why this is its own small
/// watcher. It runs only while Opera is the frontmost app, the browser these portals are used in
/// (app switches are observed, so no timer runs at all elsewhere, Chrome and other browsers
/// included). Off the pages it looks every `lookInterval` (3 s): it asks Opera for its focused
/// window and reads its title, and only when the title names Informex or Copart finds the page (its
/// web area), checks the page address, finds the anchor element and reads the vehicle
/// (`AuctionVehicle`). The page walk runs once per page; afterwards the timer runs at `interval`
/// and each tick reads only the focused window, its title and the anchor's position; the address
/// is re-checked about once a second and the visible area is recomputed only when the anchor moves.
///
/// Owned by `CotabbyAppEnvironment`, started by `AppDelegate`, which forwards each change to
/// `VehicleSearchOverlayController`. Reads only; it never writes to the page.
@MainActor
final class VehiclePageWatcher {
    struct Placement: Equatable {
        let vehicle: AuctionVehicle
        /// The element the buttons sit beside (the offer field, the lot title), Cocoa coordinates.
        let anchorFrame: CGRect
        let browserBundleIdentifier: String?
    }

    /// The pages the watcher recognizes, from the window title down to the anchor element.
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

        /// The element the buttons sit beside. Informex: the "Mijn offerte" field (DOM id `bidI`).
        /// Copart: the lot title (`h1.ldp-header-title`), or rather its text, whose frame ends where
        /// the title does; the heading itself spans the whole column.
        func anchor(in webArea: AXUIElement) -> AXUIElement? {
            switch self {
            case .informex:
                return VehiclePageWatcher.firstDescendant(of: webArea, limit: 4000) { node in
                    AXHelper.stringValue(for: "AXDOMIdentifier" as CFString, on: node) == "bidI"
                }
            case .copart:
                guard let heading = VehiclePageWatcher.firstDescendant(of: webArea, limit: 4000, where: { node in
                    AXHelper.stringArrayValue(for: "AXDOMClassList" as CFString, on: node)?
                        .contains("ldp-header-title") == true
                }) else { return nil }
                return AXHelper.childElements(of: heading).first { child in
                    AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: child) == "AXStaticText"
                } ?? heading
            }
        }
    }

    /// Called with the new placement whenever it changes; nil hides the buttons.
    var onChange: ((Placement?) -> Void)?

    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var lastPlacement: Placement?
    /// On the page, the address is re-read every this many ticks; leaving the page also invalidates
    /// the anchor element, whose frame read then fails at once, so this only bounds a same-tab
    /// navigation that keeps the element alive.
    static let ticksPerAddressCheck = 6
    private var ticksUntilAddressCheck = 0
    /// The visible area computed for `visibleAreaAnchorFrame`; recomputed only when the anchor moves.
    private var visibleArea: CGRect?
    private var visibleAreaAnchorFrame: CGRect?
    private var activationObserver: NSObjectProtocol?
    private var page: CachedPage?
    /// The anchor's frame on the previous tick and since when it has not moved: while it moves (the
    /// page is scrolling) the buttons hide, and they return once it has settled.
    private var lastAnchorFrame: CGRect?
    private var anchorStillSince: Date?
    /// The anchor's full height on this page. Opera reports a partly scrolled-out element with a
    /// frame clipped to the visible part (measured: a 76 pt field in view, a 6 pt or 1 pt sliver
    /// pinned to the top edge under the toolbar), so only the full height counts as in view.
    private var fullAnchorHeight: CGFloat = 0

    private struct CachedPage {
        let kind: PageKind
        let processIdentifier: pid_t
        let window: AXUIElement
        let webArea: AXUIElement
        let url: String
        let anchor: AXUIElement
        let vehicle: AuctionVehicle
        /// The page's containers up to the window. Their frames' overlap is the part of the page
        /// actually visible: the web area itself spans the whole scrollable document (measured in
        /// Opera), so it cannot say whether the anchor has scrolled under the toolbar.
        let containers: [AXUIElement]
    }

    /// Room the buttons need to the right of the anchor (two 26 pt buttons, spacing, gap).
    static let buttonsWidth: CGFloat = 26 * 2 + 6 + 8

    /// On a page: fast enough to hide the buttons as soon as scrolling starts. A tick reads the
    /// focused window, its title and the anchor's frame (three attribute reads).
    static let interval: TimeInterval = 0.15
    /// Off the pages: how often Opera's focused window title is read to find one.
    static let lookInterval: TimeInterval = 3
    /// How long the anchor must stay put before the buttons come back after a scroll.
    static let settleTime: TimeInterval = 0.3

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

    /// Runs the timer only while Opera is in front; anywhere else the buttons are not wanted, so
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
        // Generous off the page (a look may come a little late), tight on it (scroll tracking).
        timer.tolerance = interval == Self.interval ? 0.05 : 0.5
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
        // Following the anchor on a page needs the full rate; finding a page does not.
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

        // Fast path: the same page in the same window as last tick. Reads the anchor position, and
        // the address about once a second.
        if let cached = page, cached.kind == kind, cached.processIdentifier == pid, CFEqual(cached.window, window) {
            ticksUntilAddressCheck -= 1
            if ticksUntilAddressCheck > 0 || Self.url(of: cached.webArea) == cached.url {
                if ticksUntilAddressCheck <= 0 { ticksUntilAddressCheck = Self.ticksPerAddressCheck }
                return placement(for: cached, browser: app.bundleIdentifier)
            }
        }

        page = nil
        fullAnchorHeight = 0
        visibleArea = nil
        visibleAreaAnchorFrame = nil
        ticksUntilAddressCheck = Self.ticksPerAddressCheck
        guard let webArea = Self.firstDescendant(of: window, limit: 3000, where: { node in
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXWebArea"
        }), let url = Self.url(of: webArea), kind.applies(toURL: url),
              let anchor = kind.anchor(in: webArea),
              let vehicle = kind.vehicle(in: Self.texts(in: webArea)) else { return nil }
        var containers: [AXUIElement] = []
        var node = webArea
        while containers.count < 20, let parent = AXHelper.parentElement(of: node) {
            containers.append(parent)
            if CFEqual(parent, window) { break }
            node = parent
        }
        let cached = CachedPage(kind: kind, processIdentifier: pid, window: window, webArea: webArea, url: url,
                                anchor: anchor, vehicle: vehicle, containers: containers)
        page = cached
        return placement(for: cached, browser: app.bundleIdentifier)
    }

    /// The anchor's frame, or nil unless the anchor and the buttons beside it are fully in view and
    /// the page is not scrolling.
    private func placement(for page: CachedPage, browser: String?) -> Placement? {
        guard let anchor = AXHelper.rectValue(for: "AXFrame" as CFString, on: page.anchor), anchor.width > 0 else { return nil }
        let now = Date()
        if anchor != lastAnchorFrame {
            lastAnchorFrame = anchor
            anchorStillSince = now
        }
        guard let still = anchorStillSince, now.timeIntervalSince(still) >= Self.settleTime else { return nil }
        fullAnchorHeight = max(fullAnchorHeight, anchor.height)
        guard anchor.height >= fullAnchorHeight - 1 else { return nil }
        if visibleAreaAnchorFrame != anchor {
            let frames = page.containers.compactMap { AXHelper.rectValue(for: "AXFrame" as CFString, on: $0) }
                .filter { $0.width > 0 && $0.height > 0 }
            visibleArea = frames.first.map { first in frames.dropFirst().reduce(first) { $0.intersection($1) } }
            visibleAreaAnchorFrame = anchor
        }
        guard let visible = visibleArea else { return nil }
        let needed = CGRect(x: anchor.minX, y: anchor.minY, width: anchor.width + Self.buttonsWidth, height: anchor.height)
        guard visible.contains(needed) else { return nil }
        return Placement(vehicle: page.vehicle,
                         anchorFrame: AXHelper.cocoaRect(fromAccessibilityRect: anchor),
                         browserBundleIdentifier: browser)
    }

    // MARK: - AX helpers

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
    fileprivate static func firstDescendant(
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
