import XCTest

@testable import edo

final class ScriptFontSizeTests: XCTestCase {
    private let panel = CGSize(width: 520, height: 180)

    func testShortScriptStopsAtLargestSize() {
        XCTAssertEqual(ScriptPanelView.fittingFontSize("Show the login page.", in: panel), ScriptPanelView.maxFontSize)
    }

    func testLongerScriptGetsSmaller() {
        let short = ScriptPanelView.fittingFontSize(Array(repeating: "A line to read.", count: 5).joined(separator: "\n"), in: panel)
        let long = ScriptPanelView.fittingFontSize(Array(repeating: "A longer line of the script to read out loud.", count: 8)
            .joined(separator: "\n"), in: panel)
        XCTAssertLessThan(long, short)
        XCTAssertLessThan(short, ScriptPanelView.maxFontSize)
    }

    func testScriptTooLongForPanelStopsAtSmallestSize() {
        let huge = Array(repeating: "Line", count: 200).joined(separator: "\n")
        XCTAssertEqual(ScriptPanelView.fittingFontSize(huge, in: panel), ScriptPanelView.minFontSize)
        XCTAssertEqual(ScriptPanelView.fittingFontSize("Text", in: .zero), ScriptPanelView.minFontSize)
    }
}
