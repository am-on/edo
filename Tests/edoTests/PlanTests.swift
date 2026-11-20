import XCTest

@testable import edo

final class PlanTests: XCTestCase {
    private let plan = Plan(segments: [
        Segment(start: 0, end: 2, speed: 1, note: "speech"),
        Segment(start: 2, end: 4, speed: 2, note: "quiet"),
        Segment(start: 4, end: 6, speed: 0),
        Segment(start: 6, end: 8, speed: 1),
    ])

    func testSerializedPlanParsesBackUnchanged() throws {
        XCTAssertEqual(try Plan.parse(plan.serialized()), plan)
    }

    func testOutputDurationSkipsCutsAndScalesSpeed() {
        XCTAssertEqual(plan.outputDuration, 2 + 1 + 0 + 2)
    }

    func testTimeMappingRoundTripsOutsideCuts() {
        XCTAssertEqual(plan.outputTime(forSource: 3), 2.5)
        XCTAssertEqual(plan.sourceTime(forOutput: 2.5), 3)
        XCTAssertEqual(plan.outputTime(forSource: 7), 4)
        XCTAssertEqual(plan.sourceTime(forOutput: 4), 7)
    }

    func testSourceTimeInsideCutMapsToStartOfNextKeptSegment() {
        XCTAssertEqual(plan.outputTime(forSource: 5), 3)
        XCTAssertEqual(plan.sourceTime(forOutput: 3), 6)
    }

    func testGapsBetweenLinesBecomeCuts() throws {
        let parsed = try Plan.parse("1 2 1\n3 4 1.5 # clicks\n")
        XCTAssertEqual(parsed.segments, [
            Segment(start: 0, end: 1, speed: 0, note: "gap"),
            Segment(start: 1, end: 2, speed: 1),
            Segment(start: 2, end: 3, speed: 0, note: "gap"),
            Segment(start: 3, end: 4, speed: 1.5, note: "clicks"),
        ])
    }

    func testParseRejectsOverlapsAndMalformedLines() {
        XCTAssertThrowsError(try Plan.parse("0 2 1\n1 3 1\n")) { error in
            XCTAssertEqual(error as? PlanError, .overlap(2))
        }
        XCTAssertThrowsError(try Plan.parse("# header\n0 2\n")) { error in
            XCTAssertEqual(error as? PlanError, .badLine(2, "0 2"))
        }
        XCTAssertThrowsError(try Plan.parse("2 1 1\n"))
    }

    func testZeroLengthLinesAreSkipped() throws {
        XCTAssertEqual(try Plan.parse("0 2 1\n2 2 1\n").segments, [Segment(start: 0, end: 2, speed: 1)])
    }

    func testSplitKeepsSpeedOnBothHalves() {
        var edited = plan
        XCTAssertTrue(edited.split(at: 3))
        XCTAssertEqual(edited.segments[1], Segment(start: 2, end: 3, speed: 2, note: "quiet"))
        XCTAssertEqual(edited.segments[2], Segment(start: 3, end: 4, speed: 2, note: "quiet"))
        XCTAssertFalse(edited.split(at: 3.05), "too close to an existing boundary")
    }

    func testMergeTakesFirstSegmentsSpeed() {
        var edited = plan
        XCTAssertTrue(edited.mergeWithNext(0))
        XCTAssertEqual(edited.segments[0], Segment(start: 0, end: 4, speed: 1, note: "speech"))
        XCTAssertFalse(edited.mergeWithNext(2))
    }

    func testMoveBoundaryClampsToNeighbours() {
        var edited = plan
        edited.moveBoundary(after: 0, to: 3.333)
        XCTAssertEqual(edited.segments[0].end, 3.33)
        XCTAssertEqual(edited.segments[1].start, 3.33)
        edited.moveBoundary(after: 0, to: 10)
        XCTAssertEqual(edited.segments[0].end, 3.9)
    }
}
