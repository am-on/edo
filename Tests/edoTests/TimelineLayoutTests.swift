import XCTest

@testable import edo

final class TimelineLayoutTests: XCTestCase {
    private let plan = Plan(segments: [
        Segment(start: 0, end: 50, speed: 1),
        Segment(start: 50, end: 50.5, speed: 1.2),
        Segment(start: 50.5, end: 100, speed: 1),
    ])

    func testShortSegmentGetsMinimumWidth() {
        let layout = TimelineLayout(plan: plan, duration: 100, width: 1000, minWidth: 28)
        XCTAssertEqual(layout.x(50.5) - layout.x(50), 28, accuracy: 0.001)
        XCTAssertEqual(layout.x(100), 1000, accuracy: 0.001)
    }

    func testLongSegmentsShareTheRestProportionally() {
        let layout = TimelineLayout(plan: plan, duration: 100, width: 1000, minWidth: 28)
        XCTAssertEqual(layout.x(50), (1000 - 28) * 50 / 99.5, accuracy: 0.001)
        XCTAssertEqual(layout.x(25), layout.x(50) / 2, accuracy: 0.001)
    }

    func testTimeAndPositionRoundTrip() {
        let layout = TimelineLayout(plan: plan, duration: 100, width: 1000, minWidth: 28)
        for time in [0, 12.3, 50, 50.25, 50.5, 77, 100] {
            XCTAssertEqual(layout.time(layout.x(time)), time, accuracy: 0.001)
        }
    }

    func testWithoutRoomForMinimumsTheLayoutIsProportional() {
        let layout = TimelineLayout(plan: plan, duration: 100, width: 60, minWidth: 28)
        XCTAssertEqual(layout.x(50), 30, accuracy: 0.001)
    }

    func testRoundingSliverAtTheEndDoesNotTakeASlot() {
        let layout = TimelineLayout(plan: plan, duration: 100.004, width: 1000, minWidth: 28)
        XCTAssertEqual(layout.x(100), 1000, accuracy: 0.1)
    }

    func testEmptyPlanIsLinearOverTheVideo() {
        let layout = TimelineLayout(plan: Plan(segments: []), duration: 10, width: 500)
        XCTAssertEqual(layout.x(5), 250, accuracy: 0.001)
    }
}
