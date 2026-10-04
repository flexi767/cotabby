import ApplicationServices
import Foundation

/// Remembers which attributes (and parameterized attributes) recently seen elements support.
///
/// The focus poll runs every 50 ms while the writer types and asked the focused element for both
/// attribute-name lists on every capture: two cross-process round trips into the host app that
/// return the same answer for the same element. Entries live for `lifetime` so a host that changes
/// an element's attribute set (Chromium enabling accessibility, a field becoming editable) is seen
/// again within a couple of seconds. Elements are matched with `CFEqual`, a local comparison.
final class AXAttributeNameCache {
    struct Names {
        let attributes: Set<String>
        let parameterized: Set<String>
    }

    private struct Entry {
        let element: AXUIElement
        let names: Names
        let storedAt: TimeInterval
    }

    static let lifetime: TimeInterval = 2
    static let capacity = 16

    private var entries: [Entry] = []
    private let now: () -> TimeInterval
    private let fetch: (AXUIElement) -> Names

    // Same isolated-deinit workaround as `FocusSessionScopedCache`.
    nonisolated deinit {}

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        fetch: @escaping (AXUIElement) -> Names = { element in
            Names(
                attributes: Set(AXHelper.attributeNames(on: element)),
                parameterized: Set(AXHelper.parameterizedAttributeNames(on: element))
            )
        }
    ) {
        self.now = now
        self.fetch = fetch
    }

    func names(for element: AXUIElement) -> Names {
        let time = now()
        entries.removeAll { time - $0.storedAt >= Self.lifetime }
        if let hit = entries.first(where: { CFEqual($0.element, element) }) {
            return hit.names
        }
        let names = fetch(element)
        entries.insert(Entry(element: element, names: names, storedAt: time), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        return names
    }
}
