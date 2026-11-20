import XCTest

@testable import edo

final class SpeechDetectorTests: XCTestCase {
    private let window = 0.05
    private let loud: Float = -20
    private let quiet: Float = -60

    private func levels(_ runs: [(Float, Double)]) -> [Float] {
        runs.flatMap { level, seconds in Array(repeating: level, count: Int((seconds / window).rounded())) }
    }

    private func plan(_ runs: [(Float, Double)], words: [Word]? = nil, settings: DetectionSettings? = nil) -> Plan {
        var fixed = DetectionSettings()
        fixed.thresholdDB = -35
        let levels = levels(runs)
        return SpeechDetector.plan(levels: levels, window: window, duration: Plan.round(Double(levels.count) * window),
                                   settings: settings ?? fixed, words: words)
    }

    func testLongPauseBetweenSpeechKeepsMarginAroundWords() {
        XCTAssertEqual(plan([(loud, 2), (quiet, 1.5), (loud, 2)]).segments, [
            Segment(start: 0, end: 2.2, speed: 1, note: "speech"),
            Segment(start: 2.2, end: 3.3, speed: 1.2, note: "quiet"),
            Segment(start: 3.3, end: 5.5, speed: 1, note: "speech"),
        ])
    }

    func testPausesShorterThanASecondStayAtNormalSpeed() {
        XCTAssertEqual(plan([(loud, 1), (quiet, 0.8), (loud, 1)]).segments, [
            Segment(start: 0, end: 2.8, speed: 1, note: "speech"),
        ])
    }

    func testQuietAtStartAndEndHasNoMarginAtFileEdges() {
        XCTAssertEqual(plan([(quiet, 1.5), (loud, 1), (quiet, 1.5)]).segments, [
            Segment(start: 0, end: 1.3, speed: 0, note: "quiet"),
            Segment(start: 1.3, end: 2.7, speed: 1, note: "speech"),
            Segment(start: 2.7, end: 4, speed: 0, note: "quiet"),
        ])
    }

    func testEntirelyQuietRecordingStaysPlayable() {
        XCTAssertEqual(plan([(quiet, 3)]).segments, [Segment(start: 0, end: 3, speed: 1.2, note: "quiet")])
    }

    func testClickInsideAPauseIsIgnored() {
        let segments = plan([(loud, 1), (quiet, 1), (loud, 0.1), (quiet, 1), (loud, 1)]).segments
        XCTAssertEqual(segments.map(\.note), ["speech", "quiet", "speech"])
        XCTAssertEqual(segments[1].start, 1.2)
        XCTAssertEqual(segments[1].end, 2.9)
    }

    func testSpeechFadingJustBelowTheThresholdStaysSpeech() {
        let segments = plan([(loud, 1), (-38, 0.6), (quiet, 1.5), (loud, 1)]).segments
        XCTAssertEqual(segments[1].start, 1.8, "the -38 dB tail is inside the 6 dB hysteresis")
    }

    func testLoudPartWithoutAWordIsQuiet() {
        let words = [Word(start: 0.1, end: 0.9, text: "Hello"), Word(start: 3.1, end: 3.8, text: "there.")]
        let segments = plan([(loud, 1), (quiet, 0.5), (loud, 0.5), (quiet, 1), (loud, 1)], words: words).segments
        XCTAssertEqual(segments, [
            Segment(start: 0, end: 1.2, speed: 1, note: "Hello"),
            Segment(start: 1.2, end: 2.8, speed: 1.2, note: "quiet"),
            Segment(start: 2.8, end: 4, speed: 1, note: "there."),
        ])
    }

    func testLoudTailRightAfterAWordStaysSpeech() {
        let words = [Word(start: 0.1, end: 1.9, text: "too.")]
        let segments = plan([(loud, 1), (quiet, 0.1), (loud, 0.3), (quiet, 1.6)], words: words).segments
        XCTAssertEqual(segments, [
            Segment(start: 0, end: 1.6, speed: 1, note: "too."),
            Segment(start: 1.6, end: 3, speed: 0, note: "quiet"),
        ])
    }

    func testSoftWordBelowTheThresholdStillCountsAsSpeech() {
        let words = [Word(start: 2, end: 2.3, text: "um")]
        let segments = plan([(quiet, 4)], words: words).segments
        XCTAssertEqual(segments.map(\.note), ["quiet", "um", "quiet"])
    }

    func testAutomaticThresholdFallsBetweenNoiseAndVoice() {
        let threshold = SpeechDetector.automaticThreshold(levels([(-58, 10), (-26, 5), (-55, 5)]))
        XCTAssertGreaterThan(threshold, -55)
        XCTAssertLessThan(threshold, -26)
        XCTAssertEqual(SpeechDetector.automaticThreshold(levels([(-30, 5), (-32, 5)])), SpeechDetector.fallbackThreshold)
    }

    func testLastSegmentEndsExactlyAtTheVideoEnd() {
        let levels = levels([(loud, 1), (quiet, 2)])
        let segments = SpeechDetector.plan(levels: levels, window: window, duration: 3.0427,
                                           settings: DetectionSettings(thresholdDB: -35)).segments
        XCTAssertEqual(segments.last?.end, 3.0427)
        XCTAssertTrue(segments.allSatisfy { $0.duration > 0.01 })
    }

    func testVoiceBandDropsRumble() {
        func level(_ frequency: Double) -> Float {
            var meter = LevelMeter(sampleRate: 16_000, window: 0.05)
            meter.add((0..<16_000).map { Float(sin(2 * .pi * frequency * Double($0) / 16_000)) })
            return meter.finish().last!
        }
        XCTAssertGreaterThan(level(1_000), -4)
        XCTAssertLessThan(level(30), level(1_000) - 15)
    }
}
