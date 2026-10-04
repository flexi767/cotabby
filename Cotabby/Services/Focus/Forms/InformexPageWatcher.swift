import AppKit
import ApplicationServices
import Foundation

/// Watches for the Informex offer page in the frontmost browser, so the vehicle search buttons can
/// sit beside "Mijn offerte" as soon as the page is in front, without the writer clicking a field.
///
/// The focus tracker only describes the focused text field, which is why this is its own small
/// watcher. It runs only while a Chromium browser is the frontmost app (app switches are observed,
/// so no timer runs at all elsewhere): about once a second it asks the browser for its focused window and, only
/// when that window's title names Informex, finds the page (its web area), checks the page address
/// (`VATCounterpartRule.applies`: the portal host and the `/auction` path), finds the "Mijn offerte"
/// field (DOM id `bidI`) and reads the vehicle (`InformexVehicle`). The page walk runs once per page;
/// afterwards each 0.15 s tick reads only the field's position (one attribute read); the address is
/// re-checked about once a second and the visible area is recomputed only when the field moves.
/// Other pages in the browser cost one title read a second; other apps cost nothing.
///
/// Owned by `CotabbyAppEnvironment`, started by `AppDelegate`, which forwards each change to
/// `VehicleSearchOverlayController`. Reads only; it never writes to the page.
@MainActor
final class InformexPageWatcher {
    struct Placement: Equatable {
        let vehicle: InformexVehicle
        /// The "Mijn offerte" field, Cocoa coordinates.
        let fieldFrame: CGRect
        let browserBundleIdentifier: String?
    }

    /// Called with the new placement whenever it changes; nil hides the buttons.
    var onChange: ((Placement?) -> Void)?

    private var timer: Timer?
    private var lastPlacement: Placement?
    /// Ticks to skip before looking again while no offer page is in front. Each look asks the
    /// browser for its focused window and title (two cross-process calls); at the full rate that was
    /// the largest steady cost in the profile while browsing any other page.
    private var ticksUntilNextLook = 0
    static let ticksPerLookWithoutPage = 6
    /// On the page, the address is re-read every this many ticks; leaving the page also invalidates
    /// the field element, whose frame read then fails at once, so this only bounds a same-tab
    /// navigation that keeps the element alive.
    static let ticksPerAddressCheck = 6
    private var ticksUntilAddressCheck = 0
    /// The visible area computed for `visibleAreaFieldFrame`; recomputed only when the field moves.
    private var visibleArea: CGRect?
    private var visibleAreaFieldFrame: CGRect?
    private var activationObserver: NSObjectProtocol?
    private var page: CachedPage?
    /// The field's frame on the previous tick and since when it has not moved: while it moves (the
    /// page is scrolling) the buttons hide, and they return once it has settled.
    private var lastFieldFrame: CGRect?
    private var fieldStillSince: Date?
    /// The field's full height on this page. Opera reports a partly scrolled-out field with a frame
    /// clipped to the visible part (measured: 76 pt tall in view, a 6 pt or 1 pt sliver pinned to the
    /// top edge under the toolbar), so only the full height counts as in view.
    private var fullFieldHeight: CGFloat = 0

    private struct CachedPage {
        let processIdentifier: pid_t
        let window: AXUIElement
        let webArea: AXUIElement
        let url: String
        let netField: AXUIElement
        let vehicle: InformexVehicle
        /// The page's containers up to the window. Their frames' overlap is the part of the page
        /// actually visible: the web area itself spans the whole scrollable document (measured in
        /// Opera), so it cannot say whether the field has scrolled under the toolbar.
        let containers: [AXUIElement]
    }

    /// Room the buttons need to the right of the field (two 26 pt buttons, spacing, gap).
    static let buttonsWidth: CGFloat = 26 * 2 + 6 + 8

    /// Fast enough to hide the buttons as soon as scrolling starts. A tick on the page reads the focused
    /// window, its title and the field's frame (three attribute reads; formerly about twenty).
    static let interval: TimeInterval = 0.15
    /// How long the field must stay put before the buttons come back after a scroll.
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

    /// Runs the timer only while a Chromium browser is in front; anywhere else the buttons cannot
    /// apply, so nothing is polled and the timer does not wake the app.
    private func updateTimerForFrontmostApp() {
        let browserInFront = BrowserAppDetector.isChromiumBrowser(
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        guard browserInFront else {
            stopTimer()
            page = nil
            publish(nil)
            return
        }
        guard timer == nil else { return }
        ticksUntilNextLook = 0
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Following the field on the offer page needs the full rate; finding the page does not.
        if page == nil {
            guard ticksUntilNextLook <= 0 else {
                ticksUntilNextLook -= 1
                return
            }
            ticksUntilNextLook = Self.ticksPerLookWithoutPage - 1
        }
        publish(currentPlacement())
    }

    private func publish(_ placement: Placement?) {
        guard placement != lastPlacement else { return }
        lastPlacement = placement
        onChange?(placement)
    }

    private func currentPlacement() -> Placement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              BrowserAppDetector.isChromiumBrowser(bundleIdentifier: app.bundleIdentifier) else {
            page = nil
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = Self.element(kAXFocusedWindowAttribute as CFString, on: appElement),
              AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: window)?
                .localizedCaseInsensitiveContains("informex") == true else {
            page = nil
            return nil
        }

        // Fast path: the same page in the same window as last tick. Reads the field position, and the
        // address about once a second.
        if let cached = page, cached.processIdentifier == pid, CFEqual(cached.window, window) {
            ticksUntilAddressCheck -= 1
            if ticksUntilAddressCheck > 0 || Self.url(of: cached.webArea) == cached.url {
                if ticksUntilAddressCheck <= 0 { ticksUntilAddressCheck = Self.ticksPerAddressCheck }
                return placement(for: cached, browser: app.bundleIdentifier)
            }
        }

        page = nil
        fullFieldHeight = 0
        visibleArea = nil
        visibleAreaFieldFrame = nil
        ticksUntilAddressCheck = Self.ticksPerAddressCheck
        guard let webArea = Self.firstDescendant(of: window, limit: 3000, where: { node in
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == "AXWebArea"
        }), let url = Self.url(of: webArea), VATCounterpartRule.applies(toURL: url),
              let netField = Self.firstDescendant(of: webArea, limit: 4000, where: { node in
                  AXHelper.stringValue(for: "AXDOMIdentifier" as CFString, on: node) == "bidI"
              }),
              let vehicle = InformexVehicle.parse(pageTexts: Self.texts(in: webArea)) else { return nil }
        var containers: [AXUIElement] = []
        var node = webArea
        while containers.count < 20, let parent = AXHelper.parentElement(of: node) {
            containers.append(parent)
            if CFEqual(parent, window) { break }
            node = parent
        }
        let cached = CachedPage(processIdentifier: pid, window: window, webArea: webArea, url: url, netField: netField,
                                vehicle: vehicle, containers: containers)
        page = cached
        return placement(for: cached, browser: app.bundleIdentifier)
    }

    /// The field's frame, or nil unless the field and the buttons beside it are fully in view and the
    /// page is not scrolling.
    private func placement(for page: CachedPage, browser: String?) -> Placement? {
        guard let field = AXHelper.rectValue(for: "AXFrame" as CFString, on: page.netField), field.width > 0 else { return nil }
        let now = Date()
        if field != lastFieldFrame {
            lastFieldFrame = field
            fieldStillSince = now
        }
        guard let still = fieldStillSince, now.timeIntervalSince(still) >= Self.settleTime else { return nil }
        fullFieldHeight = max(fullFieldHeight, field.height)
        guard field.height >= fullFieldHeight - 1 else { return nil }
        if visibleAreaFieldFrame != field {
            let frames = page.containers.compactMap { AXHelper.rectValue(for: "AXFrame" as CFString, on: $0) }
                .filter { $0.width > 0 && $0.height > 0 }
            visibleArea = frames.first.map { first in frames.dropFirst().reduce(first) { $0.intersection($1) } }
            visibleAreaFieldFrame = field
        }
        guard let visible = visibleArea else { return nil }
        let needed = CGRect(x: field.minX, y: field.minY, width: field.width + Self.buttonsWidth, height: field.height)
        guard visible.contains(needed) else { return nil }
        return Placement(vehicle: page.vehicle,
                         fieldFrame: AXHelper.cocoaRect(fromAccessibilityRect: field),
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
