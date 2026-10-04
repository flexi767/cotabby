import ApplicationServices
import Foundation

/// The focused field's accessible name and DOM id, read once per field instead of on every capture.
///
/// A field's label does not change while it has focus, and these are three cross-process reads
/// (`AXTitle`, `AXDescription`, `AXDOMIdentifier`) that the focus poll would otherwise repeat for
/// the same element. One entry is enough: only the focused field is asked. Matched with `CFEqual`,
/// a local comparison. Owned by `FocusSnapshotResolver`.
final class AXFieldNameCache {
    private var entry: (element: AXUIElement, name: String?)?
    private let fetch: (AXUIElement) -> String?

    // Same isolated-deinit workaround as `AXAttributeNameCache`.
    nonisolated deinit {}

    init(fetch: @escaping (AXUIElement) -> String? = { AXFieldNameCache.readName(of: $0) }) {
        self.fetch = fetch
    }

    func name(of element: AXUIElement) -> String? {
        if let entry, CFEqual(entry.element, element) { return entry.name }
        let name = fetch(element)
        entry = (element, name)
        return name
    }

    /// Title, description and DOM id joined with spaces; nil when all are empty.
    static func readName(of element: AXUIElement) -> String? {
        let parts = [kAXTitleAttribute as String, kAXDescriptionAttribute as String, "AXDOMIdentifier"]
            .compactMap { AXHelper.stringValue(for: $0 as CFString, on: element) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : String(parts.joined(separator: " ").prefix(200))
    }
}
