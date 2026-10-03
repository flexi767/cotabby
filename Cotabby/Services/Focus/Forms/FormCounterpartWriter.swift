import ApplicationServices
import Foundation
import Logging

/// Writes the computed offer amount into the other offer field (see `VATCounterpartRule`).
///
/// The one place Cotabby sets a field it is not typing into. It uses Accessibility's value
/// attribute, which Chromium applies like user input (the page receives input and change events),
/// so the portal's own scripts see the new amount. The write is checked by reading the value back;
/// a field that refuses the write is left as it was and the failure is logged.
@MainActor
enum FormCounterpartWriter {
    @discardableResult
    static func write(_ value: String, to handle: AXElementHandle) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(handle.element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            CotabbyLogger.focus.info("Offer autofill skipped: the other field is not writable")
            return false
        }
        let status = AXUIElementSetAttributeValue(handle.element, kAXValueAttribute as CFString, value as CFString)
        // Chromium applies the value asynchronously (measured in Opera: an immediate read-back still
        // shows the old value), so the check runs a moment later and only feeds the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let readBack = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: handle.element)
            CotabbyLogger.focus.info(
                "Offer autofill",
                metadata: ["status": .stringConvertible(status.rawValue),
                           "verified": .string(status == .success && readBack == value ? "yes" : "no")]
            )
        }
        return status == .success
    }
}
