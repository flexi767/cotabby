import AppKit
import Foundation
import Logging

/// The vehicle search panel in Opera's address bar: for each vehicle on the page (one on a lot or
/// offer page, one per board on Copart's live auction dashboard) two small buttons that open a
/// search for it (its mobile.bg saved search in scrapeui, and that search's mobile.de results) and,
/// on Copart, the fees and total for the current bid (`CopartFees`).
///
/// A borderless, non-activating panel, like the ghost-text panel: clicking a button never takes
/// focus away from the browser. It sits at the right end of the address bar, so it never covers the
/// page and does not move when the page scrolls. The link opens in the same browser as the page
/// (where the writer is signed in to scrapeui), not in whatever the default browser is.
///
/// The brand icons are the sites' own favicons, fetched once and cached on disk. They are not
/// shipped with Cotabby (a public repository should not redistribute other companies' logos);
/// until they arrive, or if they cannot be fetched, the buttons show the site names as text.
///
/// Owned by `CotabbyAppEnvironment`, driven by `AppDelegate` from `VehiclePageWatcher`: shown while
/// such a page is in front in Opera, hidden otherwise (and while an address is being typed).
@MainActor
final class VehicleSearchOverlayController: NSObject {
    private var panel: NSPanel?
    private var stack: NSStackView?
    private var lots: [AuctionLot] = []
    /// Every button, with the vehicle index and target it opens, so arriving icons reach them all.
    private var buttons: [(button: NSButton, target: AuctionVehicle.SearchTarget)] = []
    private var hostBundleIdentifier: String?
    private var icons: [AuctionVehicle.SearchTarget: NSImage] = [:]
    private var iconFetchStarted = false

    private static let buttonSize = NSSize(width: 22, height: 22)
    private static let spacing: CGFloat = 4
    private static let groupSpacing: CGFloat = 14
    /// Gap between the panel and the address bar's right end.
    private static let insetFromBarEnd: CGFloat = 8

    private static let faviconURLs: [AuctionVehicle.SearchTarget: URL] = [
        .mobileBG: URL(string: "https://www.mobile.bg/favicon.ico")!,
        .mobileDE: URL(string: "https://www.mobile.de/favicon.ico")!,
    ]

    private static let tooltips: [AuctionVehicle.SearchTarget: String] = [
        .mobileBG: "Search this vehicle: mobile.bg saved search in scrapeui",
        .mobileDE: "Search this vehicle: mobile.de results in scrapeui",
    ]

    /// Shows the panel for `lots` at the right end of `addressBarFrame` (Cocoa coordinates), or
    /// hides it.
    func update(lots: [AuctionLot], addressBarFrame: CGRect?, hostBundleIdentifier: String?) {
        guard !lots.isEmpty, let addressBarFrame, addressBarFrame.width > 0 else {
            hide()
            return
        }
        BackgroundCursor.enable()
        self.hostBundleIdentifier = hostBundleIdentifier
        let panel = panel ?? makePanel()
        if lots != self.lots { rebuild(for: lots) }
        guard let stack else { return }
        let size = stack.frame.size
        let origin = NSPoint(x: addressBarFrame.maxX - Self.insetFromBarEnd - size.width,
                             y: addressBarFrame.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        fetchIconsIfNeeded()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    /// One group per vehicle, in page order: its fees (when known), then its two buttons. A fresh
    /// stack each time: a reused one is measured against its previous frame, and a smaller earlier
    /// panel then clipped the new content (measured: 48 pt wide, the fee label cut off).
    private func rebuild(for lots: [AuctionLot]) {
        self.lots = lots
        buttons.removeAll()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Self.groupSpacing
        stack.alignment = .centerY
        stack.setClippingResistancePriority(.required, for: .horizontal)
        stack.setHuggingPriority(.required, for: .horizontal)
        for (index, lot) in lots.enumerated() {
            let group = NSStackView()
            group.setClippingResistancePriority(.required, for: .horizontal)
            group.orientation = .horizontal
            group.spacing = Self.spacing
            group.alignment = .centerY
            if let fees = lot.fees { group.addArrangedSubview(feeLabel(fees)) }
            for target in [AuctionVehicle.SearchTarget.mobileDE, .mobileBG] {
                group.addArrangedSubview(searchButton(target: target, vehicleIndex: index))
            }
            stack.addArrangedSubview(group)
        }
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        panel?.contentView = stack
        self.stack = stack
    }

    private func searchButton(target: AuctionVehicle.SearchTarget, vehicleIndex: Int) -> NSButton {
        let button = PointingHandButton(title: target == .mobileDE ? "de" : "bg", target: self, action: #selector(openSearch(_:)))
        button.tag = vehicleIndex * 2 + (target == .mobileDE ? 0 : 1)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = Self.textFallbackBackground
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = Self.tooltips[target]
        button.setAccessibilityLabel(Self.tooltips[target])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
        if let icon = icons[target] { show(icon, on: button) }
        buttons.append((button, target))
        return button
    }

    /// "855€ · 13.355€": the total fee, then the total price, net like Copart's bids; for a lot sold
    /// plus VAT a third number, the total price with VAT ("· 15.892€"). The parts are in the tooltip.
    private func feeLabel(_ fees: CopartFees.Breakdown) -> NSView {
        var numbers = [CopartFees.format(fees.fees), CopartFees.format(fees.total)]
        if let gross = fees.totalIncludingVAT { numbers.append(CopartFees.format(gross)) }
        let label = NSTextField(labelWithString: numbers.joined(separator: " · "))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        var parts = [
            "Gebot \(CopartFees.format(fees.salePrice))",
            "Käufergebühr \(CopartFees.format(fees.buyerFee))",
            "Onlinegebotsgebühr \(CopartFees.format(fees.onlineBidFee))",
            "Bereitstellungsgebühr \(CopartFees.format(fees.pickupFee))",
        ]
        if fees.documentFee > 0 { parts.append("Dokumentengebühr \(CopartFees.format(fees.documentFee))") }
        if let gross = fees.totalIncludingVAT {
            parts.append("Gesamt inkl. 19% MwSt. \(CopartFees.format(gross)) (Verkauf zzgl. MwSt.)")
        }
        parts.append("Gebühren netto (Copart, Stand Januar 2025)")
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.layer?.backgroundColor = Self.textFallbackBackground
        pill.toolTip = parts.joined(separator: "\n")
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.buttonSize.height),
        ])
        return pill
    }

    @objc private func openSearch(_ sender: NSButton) {
        let target: AuctionVehicle.SearchTarget = sender.tag % 2 == 0 ? .mobileDE : .mobileBG
        let index = sender.tag / 2
        guard lots.indices.contains(index), let url = lots[index].vehicle.searchURL(for: target) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        if let bundle = hostBundleIdentifier,
           let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
        CotabbyLogger.app.info("Opened vehicle search", metadata: ["target": .string(target.rawValue)])
    }

    // MARK: - Brand icons

    private static var iconDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cotabby", isDirectory: true)
            .appendingPathComponent("brand-icons", isDirectory: true)
    }

    private func fetchIconsIfNeeded() {
        guard !iconFetchStarted else { return }
        iconFetchStarted = true
        for (target, url) in Self.faviconURLs {
            let cached = Self.iconDirectory?.appendingPathComponent("\(target.rawValue).ico")
            if let cached, let image = NSImage(contentsOf: cached) {
                apply(image, to: target)
                continue
            }
            Task { [weak self] in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else { return }
                if let cached {
                    try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: cached)
                }
                self?.apply(image, to: target)
            }
        }
    }

    private static let textFallbackBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

    private func apply(_ image: NSImage, to target: AuctionVehicle.SearchTarget) {
        let trimmed = Self.trimmingTransparentMargins(image)
        icons[target] = trimmed
        for entry in buttons where entry.target == target { show(trimmed, on: entry.button) }
    }

    /// A real icon fills the button on its own: the grey fallback backing would show through any
    /// transparent part of it (mobile.bg's favicon is a logo inside a transparent margin).
    private func show(_ image: NSImage, on button: NSButton) {
        button.image = image
        button.imagePosition = .imageOnly
        button.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// `image` cropped to its non-transparent pixels, so a favicon drawn inside a transparent margin
    /// fills the button like one drawn edge to edge. Unchanged when it has no margin or no bitmap.
    static func trimmingTransparentMargins(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              (maxX - minX + 1, maxY - minY + 1) != (bitmap.pixelsWide, bitmap.pixelsHigh),
              let cropped = cgImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

/// Lets Cotabby set the mouse cursor while another app is active. The window server otherwise
/// ignores cursor changes from a background app, and Cotabby is always in the background while the
/// writer points at its panel (the browser stays active), so without this the pointing hand never
/// appeared. `SetsCursorInBackground` is a private window-server connection property (no public
/// API exists); it is looked up at run time, so a system without it simply keeps the arrow.
@MainActor
enum BackgroundCursor {
    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(mainSymbol, to: MainConnection.self)()
        _ = unsafeBitCast(setSymbol, to: SetProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

/// A button that shows the pointing-hand cursor while the mouse is over it. Cursor rects only work in
/// the key window of the active app, and this panel never becomes key (the browser stays active), so
/// the cursor is set from an always-active tracking area instead (with `BackgroundCursor` enabled).
/// Moves re-assert it, because the browser underneath may set its own cursor between events.
final class PointingHandButton: NSButton {
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }
}
