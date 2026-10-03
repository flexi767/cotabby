import AppKit
import Foundation
import Logging

/// Two small buttons beside the Informex "Mijn offerte" field that open a search for the vehicle on
/// the page: its mobile.bg saved search in scrapeui, and that search's mobile.de results.
///
/// A borderless, non-activating panel, like the ghost-text panel: clicking a button never takes
/// focus away from the browser, and the panel floats over the page instead of living in it. The
/// link opens in the same browser as the page (where the writer is signed in to scrapeui), not in
/// whatever the default browser is.
///
/// The brand icons are the sites' own favicons, fetched once and cached on disk. They are not
/// shipped with Cotabby (a public repository should not redistribute other companies' logos);
/// until they arrive, or if they cannot be fetched, the buttons show the site names as text.
///
/// Owned by `CotabbyAppEnvironment`, driven by `AppDelegate` from `InformexPageWatcher`: shown while
/// the offer page is in front and its "Mijn offerte" field is visible, hidden otherwise.
@MainActor
final class VehicleSearchOverlayController: NSObject {
    private var panel: NSPanel?
    private var buttons: [InformexVehicle.SearchTarget: NSButton] = [:]
    private var vehicle: InformexVehicle?
    private var hostBundleIdentifier: String?
    private var icons: [InformexVehicle.SearchTarget: NSImage] = [:]
    private var iconFetchStarted = false

    private static let buttonSize = NSSize(width: 26, height: 26)
    private static let spacing: CGFloat = 6
    private static let gapFromField: CGFloat = 8

    private static let faviconURLs: [InformexVehicle.SearchTarget: URL] = [
        .mobileBG: URL(string: "https://www.mobile.bg/favicon.ico")!,
        .mobileDE: URL(string: "https://www.mobile.de/favicon.ico")!,
    ]

    private static let tooltips: [InformexVehicle.SearchTarget: String] = [
        .mobileBG: "Search this vehicle: mobile.bg saved search in scrapeui",
        .mobileDE: "Search this vehicle: mobile.de results in scrapeui",
    ]

    /// Shows the buttons beside `fieldFrame` (Cocoa coordinates) for `vehicle`, or hides them.
    func update(vehicle: InformexVehicle?, fieldFrame: CGRect?, hostBundleIdentifier: String?) {
        guard let vehicle, let fieldFrame, fieldFrame.width > 0 else {
            hide()
            return
        }
        self.vehicle = vehicle
        self.hostBundleIdentifier = hostBundleIdentifier
        let panel = panel ?? makePanel()
        let size = NSSize(width: Self.buttonSize.width * 2 + Self.spacing, height: Self.buttonSize.height)
        let origin = NSPoint(x: fieldFrame.maxX + Self.gapFromField, y: fieldFrame.midY - size.height / 2)
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

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        for target in [InformexVehicle.SearchTarget.mobileDE, .mobileBG] {
            let button = NSButton(title: target == .mobileDE ? "de" : "bg", target: self, action: #selector(openSearch(_:)))
            button.tag = target == .mobileDE ? 0 : 1
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = Self.textFallbackBackground
            button.font = .systemFont(ofSize: 10, weight: .semibold)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = Self.tooltips[target]
            button.setAccessibilityLabel(Self.tooltips[target])
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
            stack.addArrangedSubview(button)
            buttons[target] = button
            if let icon = icons[target] { show(icon, on: button) }
        }
        panel.contentView = stack
        self.panel = panel
        return panel
    }

    @objc private func openSearch(_ sender: NSButton) {
        let target: InformexVehicle.SearchTarget = sender.tag == 0 ? .mobileDE : .mobileBG
        guard let url = vehicle?.searchURL(for: target) else { return }
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

    private func apply(_ image: NSImage, to target: InformexVehicle.SearchTarget) {
        let trimmed = Self.trimmingTransparentMargins(image)
        icons[target] = trimmed
        guard let button = buttons[target] else { return }
        show(trimmed, on: button)
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
