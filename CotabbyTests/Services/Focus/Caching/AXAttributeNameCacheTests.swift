import ApplicationServices
import XCTest
@testable import Cotabby

final class AXAttributeNameCacheTests: XCTestCase {
    private let first = AXUIElementCreateApplication(101)
    private let second = AXUIElementCreateApplication(202)

    func test_namesAreFetchedOncePerElementWithinTheLifetime() {
        var time: TimeInterval = 10
        var fetched: [pid_t] = []
        let cache = AXAttributeNameCache(now: { time }) { element in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            fetched.append(pid)
            return .init(attributes: ["AXValue"], parameterized: ["AXBoundsForRange"])
        }

        XCTAssertEqual(cache.names(for: first).attributes, ["AXValue"])
        _ = cache.names(for: first)
        _ = cache.names(for: second)
        time += 1
        _ = cache.names(for: first)
        XCTAssertEqual(fetched, [101, 202], "Repeat reads within the lifetime are served locally")

        time += AXAttributeNameCache.lifetime
        _ = cache.names(for: first)
        XCTAssertEqual(fetched, [101, 202, 101], "An expired entry is read again from the host")
    }

    func test_capacityKeepsTheMostRecentElements() {
        var fetchCount = 0
        let cache = AXAttributeNameCache(now: { 0 }) { _ in
            fetchCount += 1
            return .init(attributes: [], parameterized: [])
        }
        for pid in 1...(AXAttributeNameCache.capacity + 1) {
            _ = cache.names(for: AXUIElementCreateApplication(pid_t(pid)))
        }
        _ = cache.names(for: AXUIElementCreateApplication(pid_t(AXAttributeNameCache.capacity + 1)))
        XCTAssertEqual(fetchCount, AXAttributeNameCache.capacity + 1)
        _ = cache.names(for: AXUIElementCreateApplication(1))
        XCTAssertEqual(fetchCount, AXAttributeNameCache.capacity + 2, "The oldest entry was evicted")
    }
}
