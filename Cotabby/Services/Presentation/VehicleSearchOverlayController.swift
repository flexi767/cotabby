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
/// Owned by `CotabbyAppEnvironment`, driven by `AppDelegate` from every focus snapshot: shown while
/// an offer field on the offer page is focused and the page names a vehicle, hidden otherwise.
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
            button.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            button.font = .systemFont(ofSize: 10, weight: .semibold)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = Self.tooltips[target]
            button.setAccessibilityLabel(Self.tooltips[target])
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
            if let icon = icons[target] { button.image = icon; button.imagePosition = .imageOnly }
            stack.addArrangedSubview(button)
            buttons[target] = button
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

    private func apply(_ image: NSImage, to target: InformexVehicle.SearchTarget) {
        icons[target] = image
        guard let button = buttons[target] else { return }
        button.image = image
        button.imagePosition = .imageOnly
    }
}
