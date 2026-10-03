import ApplicationServices
import Foundation

/// What the focus resolver found next to a focused offer field (see `VATCounterpartRule`): which
/// field this is, the other field's value when focus arrived, and a handle to that other field so
/// the coordinator can fill it after the writer leaves this one. Carried on `FocusedInputSnapshot`;
/// nil for every other field.
nonisolated struct FormCounterpartReading: Equatable, Sendable {
    let targetRole: VATCounterpartRule.Role
    let counterpartValue: String
    let counterpartElement: AXElementHandle?

    init(targetRole: VATCounterpartRule.Role, counterpartValue: String, counterpartElement: AXElementHandle? = nil) {
        self.targetRole = targetRole
        self.counterpartValue = counterpartValue
        self.counterpartElement = counterpartElement
    }
}

/// An `AXUIElement` that can ride inside an Equatable snapshot. Two handles are equal when they
/// point at the same accessibility element (`CFEqual`), which is how AX identity is defined.
/// `@unchecked Sendable`: an AXUIElement reference is immutable; every read or write through it
/// happens on the main actor like the rest of Cotabby's Accessibility access.
nonisolated final class AXElementHandle: Equatable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementHandle, rhs: AXElementHandle) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
