import CoreGraphics
import Foundation

/// The part of one display to record, in the display's points from its top-left corner.
struct CaptureArea: Equatable, Codable {
    var displayID: CGDirectDisplayID
    var rect: CGRect
    var scale: CGFloat

    /// Snaps the rectangle to whole pixels with an even width and height, which the video encoder needs,
    /// and keeps it on the display.
    init(displayID: CGDirectDisplayID, rect: CGRect, displaySize: CGSize, scale: CGFloat) {
        let maxWidth = (displaySize.width * scale).rounded(.down)
        let maxHeight = (displaySize.height * scale).rounded(.down)
        let r = rect.standardized
        var width = Self.even(min(r.width * scale, maxWidth))
        var height = Self.even(min(r.height * scale, maxHeight))
        width = max(width, 2)
        height = max(height, 2)
        let x = min(max((r.minX * scale).rounded(), 0), maxWidth - width)
        let y = min(max((r.minY * scale).rounded(), 0), maxHeight - height)
        self.displayID = displayID
        self.scale = scale
        self.rect = CGRect(x: x / scale, y: y / scale, width: width / scale, height: height / scale)
    }

    static func wholeDisplay(_ displayID: CGDirectDisplayID, size: CGSize, scale: CGFloat) -> CaptureArea {
        CaptureArea(displayID: displayID, rect: CGRect(origin: .zero, size: size), displaySize: size, scale: scale)
    }

    var pixelWidth: Int { Int((rect.width * scale).rounded()) }
    var pixelHeight: Int { Int((rect.height * scale).rounded()) }

    private static func even(_ pixels: CGFloat) -> CGFloat {
        (pixels.rounded() / 2).rounded(.down) * 2
    }
}

extension CaptureArea {
    private static let defaultsKey = "lastCaptureArea"

    /// The area of the last recording, so the next one starts from it.
    static var last: CaptureArea? {
        get {
            UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(CaptureArea.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey)
        }
    }

    /// `Screen Recording 2026-11-20 at 08.12.33.mov` on the Desktop, named like the macOS screen recordings.
    static func newRecordingURL(in folder: URL, at date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screen Recording \(formatter.string(from: date))"
        var url = folder.appending(path: "\(base).mov")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(copy).mov")
            copy += 1
        }
        return url
    }
}
