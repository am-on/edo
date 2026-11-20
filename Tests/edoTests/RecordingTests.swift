import AVFoundation
import XCTest

@testable import edo

final class CaptureAreaTests: XCTestCase {
    private let display = CGSize(width: 1470, height: 956)

    func testSnapsToEvenWholePixels() {
        let area = CaptureArea(displayID: 1, rect: CGRect(x: 10.3, y: 20.7, width: 300.6, height: 200.2), displaySize: display, scale: 2)
        XCTAssertEqual(area.pixelWidth, 600)
        XCTAssertEqual(area.pixelHeight, 400)
        XCTAssertEqual(area.rect.minX * 2, (area.rect.minX * 2).rounded())
        XCTAssertEqual(area.rect.minY * 2, (area.rect.minY * 2).rounded())
    }

    func testOddPixelSizeOnNonRetinaRoundsDownToEven() {
        let area = CaptureArea(displayID: 1, rect: CGRect(x: 0, y: 0, width: 301, height: 199), displaySize: display, scale: 1)
        XCTAssertEqual(area.pixelWidth, 300)
        XCTAssertEqual(area.pixelHeight, 198)
    }

    func testStaysOnTheDisplay() {
        let area = CaptureArea(displayID: 1, rect: CGRect(x: 1400, y: 900, width: 200, height: 100), displaySize: display, scale: 2)
        XCTAssertLessThanOrEqual(area.rect.maxX, display.width)
        XCTAssertLessThanOrEqual(area.rect.maxY, display.height)
        XCTAssertEqual(area.pixelWidth, 400)
        XCTAssertEqual(area.pixelHeight, 200)
    }

    func testWholeDisplay() {
        let area = CaptureArea.wholeDisplay(1, size: display, scale: 2)
        XCTAssertEqual(area.rect, CGRect(origin: .zero, size: display))
        XCTAssertEqual(area.pixelWidth, 2940)
        XCTAssertEqual(area.pixelHeight, 1912)
    }

    func testRecordingNameMatchesMacOSAndAvoidsExistingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 8, minute: 5, second: 3)))

        let first = CaptureArea.newRecordingURL(in: folder, at: date)
        XCTAssertEqual(first.lastPathComponent, "Screen Recording 2026-11-20 at 08.05.03.mov")
        try Data().write(to: first)
        XCTAssertEqual(CaptureArea.newRecordingURL(in: folder, at: date).lastPathComponent, "Screen Recording 2026-11-20 at 08.05.03 2.mov")
    }
}

final class RecordingWriterTests: XCTestCase {
    func testWritesScreenAndVoiceIntoOneMovie() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 320, height: 200, sampleRate: 48_000)

        // Two seconds of 30 fps frames and a 440 Hz tone, stamped on the host clock like the real sources.
        let start = mach_absolute_time()
        let ticksPerSecond = AVAudioTime.hostTime(forSeconds: 1)
        for frame in 0..<60 {
            let hostTime = start + UInt64(Double(frame) / 30 * Double(ticksPerSecond))
            let buffer = try makeFrame(width: 320, height: 200, at: CMClockMakeHostTimeFromSystemUnits(hostTime))
            writer.queue.sync { writer.appendVideo(buffer) }
            if frame % 3 == 0 {
                let first = frame / 3 * 4_800
                let tone = (first..<first + 4_800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.3 }
                writer.appendAudio(tone, hostTime: hostTime)
            }
        }
        try await writer.finish()

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 200))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)

        // The tone comes through loud, so the voice is really in the file.
        let levels = try await AudioLevels.read(url)
        XCTAssertGreaterThan(levels.dropFirst(4).prefix(20).min() ?? -100, -20)
    }

    func testFinishWithoutFramesFails() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 320, height: 200, sampleRate: 48_000)
        do {
            try await writer.finish()
            XCTFail("Expected an error")
        } catch RecordingWriter.Failure.noFrames {}
    }

    private func makeFrame(width: Int, height: Int, at time: CMTime) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let pixelBuffer = try XCTUnwrap(pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &buffer)
        return try XCTUnwrap(buffer)
    }
}

final class AreaDragTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let area = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testPressPicksKnobEdgeInsideOrOutside() {
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 103, y: 98), area: area), .resize(.topLeft, original: area))
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 300, y: 405), area: area), .resize(.bottom, original: area))
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 496, y: 250), area: area), .resize(.right, original: area))
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 300, y: 250), area: area), .move(original: area, from: CGPoint(x: 300, y: 250)))
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 700, y: 700), area: area), .create(from: CGPoint(x: 700, y: 700)))
        XCTAssertEqual(AreaDrag.starting(at: CGPoint(x: 700, y: 700), area: nil), .create(from: CGPoint(x: 700, y: 700)))
    }

    func testCornerResizeMovesOnlyThatCorner() {
        let drag = AreaDrag.resize(.bottomRight, original: area)
        XCTAssertEqual(drag.area(at: CGPoint(x: 600, y: 500), within: bounds), CGRect(x: 100, y: 100, width: 500, height: 400))
    }

    func testEdgeResizeKeepsTheOtherAxis() {
        let drag = AreaDrag.resize(.left, original: area)
        XCTAssertEqual(drag.area(at: CGPoint(x: 50, y: 700), within: bounds), CGRect(x: 50, y: 100, width: 450, height: 300))
    }

    func testResizeStopsAtMinimumSizeAndScreenEdge() {
        let shrink = AreaDrag.resize(.right, original: area)
        XCTAssertEqual(shrink.area(at: CGPoint(x: 0, y: 0), within: bounds)?.width, AreaDrag.minimumSize)
        let grow = AreaDrag.resize(.bottom, original: area)
        XCTAssertEqual(grow.area(at: CGPoint(x: 0, y: 5000), within: bounds)?.maxY, 800)
    }

    func testMoveKeepsSizeAndStaysOnScreen() {
        let drag = AreaDrag.move(original: area, from: CGPoint(x: 300, y: 250))
        XCTAssertEqual(drag.area(at: CGPoint(x: 350, y: 270), within: bounds), CGRect(x: 150, y: 120, width: 400, height: 300))
        XCTAssertEqual(drag.area(at: CGPoint(x: 5000, y: -5000), within: bounds), CGRect(x: 600, y: 0, width: 400, height: 300))
    }

    func testNewAreaNeedsAMinimumDrag() {
        let drag = AreaDrag.create(from: CGPoint(x: 500, y: 500))
        XCTAssertNil(drag.area(at: CGPoint(x: 505, y: 505), within: bounds))
        XCTAssertEqual(drag.area(at: CGPoint(x: 300, y: 400), within: bounds), CGRect(x: 300, y: 400, width: 200, height: 100))
    }
}
