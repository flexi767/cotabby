import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Tells `FocusTracker` when the focused field may have changed, so it can re-read at once instead
/// of polling fast. Sources: app activation (NSWorkspace) and the frontmost app's own Accessibility
/// notifications for focus and window changes (one `AXObserver`, re-bound on every activation).
///
/// An event is only a hint: it carries no state, and the tracker answers it with the same full
/// capture a poll tick performs, so an event that arrives late, twice, or out of order costs one
/// capture and cannot leave a wrong snapshot behind. Apps that send no notifications are still
/// covered by the tracker's slow backup poll and by click and keystroke refreshes.
///
/// Text value and selection notifications are deliberately not observed: keystrokes already refresh
/// the field, and web content posts them continuously (tickers, live regions), which would turn
/// this source into a poll of its own.
@MainActor
final class FocusEventSource {
    /// Called on the main thread for each hint. The tracker coalesces bursts.
    var onEvent: (() -> Void)?

    private static let notifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    /// Short, like the poll's: registering talks to the app, and a hung app must not stall the
    /// main thread for the system's default six seconds.
    private static let registrationMessagingTimeout: Float = 0.1

    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private var activationObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedProcessIdentifier: pid_t?

    /// Starts listening. `permissionGranted` is read on each activation, so a grant made later
    /// takes effect on the next app switch without a restart.
    func start(permissionGranted: @escaping @MainActor () -> Bool) {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observe(processIdentifier: permissionGranted() ? application?.processIdentifier : nil)
                self.onEvent?()
            }
        }
        observe(processIdentifier: permissionGranted() ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil)
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        observe(processIdentifier: nil)
    }

    /// The process currently observed, for tests and diagnostics.
    var observedProcess: pid_t? { observedProcessIdentifier }

    /// Moves the single observer to `processIdentifier` (nil: observe nothing). Cotabby's own
    /// process is never observed: its panels must not wake the tracker.
    private func observe(processIdentifier: pid_t?) {
        let target = processIdentifier.flatMap { $0 > 0 && $0 != ownProcessIdentifier ? $0 : nil }
        guard target != observedProcessIdentifier else { return }
        removeObserver()
        guard let target else { return }

        var created: AXObserver?
        guard AXObserverCreate(target, Self.callback, &created) == .success, let created else {
            CotabbyLogger.focus.debug("Focus events: no observer for pid \(target)")
            return
        }
        let application = AXUIElementCreateApplication(target)
        AXUIElementSetMessagingTimeout(application, Self.registrationMessagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.notifications where
            AXObserverAddNotification(created, application, name as CFString, refcon) == .success {
            registered += 1
        }
        guard registered > 0 else {
            CotabbyLogger.focus.debug("Focus events: pid \(target) accepted no notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedApplication = application
        observedProcessIdentifier = target
        CotabbyLogger.focus.debug("Focus events: observing pid \(target) (\(registered) notifications)")
    }

    private func removeObserver() {
        if let observer {
            if let observedApplication {
                for name in Self.notifications {
                    AXObserverRemoveNotification(observer, observedApplication, name as CFString)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedApplication = nil
        observedProcessIdentifier = nil
    }

    /// Runs on the main run loop, where the observer's source is installed. The refcon is the
    /// source itself, which outlives its registration (`stop` removes it first).
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let source = Unmanaged<FocusEventSource>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            source.onEvent?()
        }
    }

    nonisolated deinit {}
}
