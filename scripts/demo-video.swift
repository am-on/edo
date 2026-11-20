// Makes a made-up screen recording for screenshots: a fake trip-planner app with a voice-over and pauses.
// Usage: swift scripts/demo-video.swift <out.mov> [itinerary|budget|packing] [--silent]
// Needs ffmpeg (Homebrew) and the macOS `say` voices.
import AppKit
import Foundation

let width = 1920, height = 1200, fps = 30
let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first else {
    FileHandle.standardError.write(Data("usage: demo-video.swift <out.mov> [itinerary|budget|packing] [--silent]\n".utf8))
    exit(2)
}
let sceneName = arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "itinerary"
let silent = arguments.contains("--silent")

// MARK: Script

enum Kind {
    case move(to: CGPoint, duration: Double)
    case click
    case flag(String)
    case type(String, text: String, duration: Double)
}

struct Action {
    var at: Double
    var kind: Kind
}

enum Beat {
    case say(String)
    case pause(Double, [Action] = [])
}

let addButton = CGPoint(x: 1730, y: 150)
let newRowDates = CGPoint(x: 1000, y: 685)
let saveButton = CGPoint(x: 1730, y: 1110)
let budgetTab = CGPoint(x: 150, y: 196)
let lisbonRow = CGPoint(x: 900, y: 420)
let packingItem = CGPoint(x: 470, y: 420)

let scenes: [String: (tab: Int, cursor: CGPoint, beats: [Beat])] = [
    "itinerary": (0, CGPoint(x: 1100, y: 600), [
        .pause(0.6),
        .say("Here's the new itinerary view in Wayfare."),
        .pause(3.4, [Action(at: 0.3, kind: .move(to: addButton, duration: 1.2)), Action(at: 1.7, kind: .click),
                     Action(at: 1.8, kind: .flag("row")), Action(at: 2.2, kind: .type("city", text: "Lisbon", duration: 1.0))]),
        .say("Adding a stop takes one click. Type the city, then pick the dates."),
        .pause(4.2, [Action(at: 0.4, kind: .move(to: newRowDates, duration: 1.0)), Action(at: 1.6, kind: .click),
                     Action(at: 2.4, kind: .flag("dates")), Action(at: 2.6, kind: .move(to: CGPoint(x: 1300, y: 900), duration: 1.2))]),
        .say("The trip total updates as you go."),
        .pause(2.6, [Action(at: 0.2, kind: .move(to: saveButton, duration: 1.1)), Action(at: 1.5, kind: .click),
                     Action(at: 1.6, kind: .flag("saved"))]),
        .say("That's it. Everyone on the trip sees the change right away."),
        .pause(1.4),
    ]),
    "budget": (1, budgetTab, [
        .pause(0.5),
        .say("This is the budget for the whole trip."),
        .pause(2.8, [Action(at: 0.4, kind: .move(to: lisbonRow, duration: 1.2)), Action(at: 1.8, kind: .click),
                     Action(at: 1.9, kind: .flag("split"))]),
        .say("Pick a stop to split its cost with friends."),
        .pause(1.2),
    ]),
    "packing": (2, CGPoint(x: 1200, y: 700), [
        .pause(0.5),
        .say("The packing list is shared with everyone."),
        .pause(2.6, [Action(at: 0.3, kind: .move(to: packingItem, duration: 1.2)), Action(at: 1.7, kind: .click),
                     Action(at: 1.8, kind: .flag("packed"))]),
        .say("Check things off as you pack."),
        .pause(1.0),
    ]),
]

guard let scene = scenes[sceneName] else {
    FileHandle.standardError.write(Data("unknown scene \(sceneName)\n".utf8))
    exit(2)
}

// MARK: Voice

let sampleRate = 48_000
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "edo-demo-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func run(_ tool: String, _ args: [String], stdin: FileHandle? = nil) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    if let stdin { process.standardInput = stdin }
    try process.run()
    return process
}

/// 16-bit mono samples of the `data` chunk in a WAV file.
func samples(ofWAV url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "data" {
            return data[offset + 8..<min(offset + 8 + size, data.count)].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        offset += 8 + size + (size % 2)
    }
    return []
}

var audio: [Int16] = []
var timeline: [(start: Double, beat: Beat)] = []
var generator = SystemRandomNumberGenerator()
func roomTone(_ count: Int) -> [Int16] {
    (0..<count).map { _ in Int16.random(in: -24...24, using: &generator) }
}
for (index, beat) in scene.beats.enumerated() {
    timeline.append((Double(audio.count) / Double(sampleRate), beat))
    switch beat {
    case let .say(text):
        let file = work.appending(path: "line\(index).wav")
        let say = try run("/usr/bin/say", ["-v", "Samantha", "-r", "175", "-o", file.path, "--data-format=LEI16@\(sampleRate)", text])
        say.waitUntilExit()
        audio += try samples(ofWAV: file).map { $0 &+ Int16.random(in: -24...24, using: &generator) }
    case let .pause(seconds, _):
        audio += roomTone(Int(seconds * Double(sampleRate)))
    }
}
let duration = Double(audio.count) / Double(sampleRate)

var header = Data()
func append<T>(_ value: T) { withUnsafeBytes(of: value) { header.append(contentsOf: $0) } }
header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + audio.count * 2))
header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
header.append(contentsOf: Array("data".utf8)); append(UInt32(audio.count * 2))
let wav = work.appending(path: "voice.wav")
try (header + audio.withUnsafeBytes { Data($0) }).write(to: wav)

// MARK: Actions in time

var actions: [(time: Double, kind: Kind)] = []
for (start, beat) in timeline {
    if case let .pause(_, list) = beat {
        actions += list.map { (start + $0.at, $0.kind) }
    }
}

func flag(_ name: String, _ t: Double) -> Bool {
    actions.contains { if case let .flag(n) = $0.kind { n == name && $0.time <= t } else { false } }
}

func typed(_ field: String, _ t: Double) -> String {
    for action in actions {
        guard case let .type(f, text, length) = action.kind, f == field, t >= action.time else { continue }
        let count = Int(Double(text.count) * min((t - action.time) / length, 1))
        return String(text.prefix(count))
    }
    return ""
}

func cursor(_ t: Double) -> CGPoint {
    var position = scene.cursor
    for action in actions {
        guard case let .move(target, length) = action.kind, t >= action.time else { continue }
        let progress = min((t - action.time) / length, 1)
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        position = CGPoint(x: position.x + (target.x - position.x) * eased, y: position.y + (target.y - position.y) * eased)
    }
    return position
}

func lastClick(_ t: Double) -> (age: Double, at: CGPoint)? {
    let clicks = actions.filter { if case .click = $0.kind { $0.time <= t } else { false } }
    guard let click = clicks.last, t - click.time < 0.35 else { return nil }
    return (t - click.time, cursor(click.time))
}

// MARK: Drawing

let accent = NSColor(srgbRed: 0.13, green: 0.47, blue: 0.85, alpha: 1)
let ink = NSColor(white: 0.12, alpha: 1)
let muted = NSColor(white: 0.45, alpha: 1)
let line = NSColor(white: 0.88, alpha: 1)

func text(_ string: String, _ point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) {
    (string as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

func box(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

func drawFrame(_ t: Double) {
    box(CGRect(x: 0, y: 0, width: width, height: height), NSColor(white: 0.97, alpha: 1))

    // Title bar and sidebar
    box(CGRect(x: 0, y: 0, width: width, height: 64), NSColor(white: 0.93, alpha: 1))
    for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        box(CGRect(x: 24 + i * 30, y: 24, width: 16, height: 16), color, radius: 8)
    }
    text("Wayfare", CGPoint(x: 900, y: 20), size: 20, weight: .semibold, color: muted)
    box(CGRect(x: 0, y: 64, width: 300, height: height - 64), NSColor(white: 0.94, alpha: 1))
    let tab = scene.tab
    for (i, name) in ["Itinerary", "Budget", "Packing", "Travelers"].enumerated() {
        let rect = CGRect(x: 16, y: 100 + i * 70, width: 268, height: 52)
        if i == tab { box(rect, accent.withAlphaComponent(0.14), radius: 10) }
        box(CGRect(x: rect.minX + 18, y: rect.midY - 11, width: 22, height: 22), i == tab ? accent : muted.withAlphaComponent(0.5), radius: 6)
        text(name, CGPoint(x: rect.minX + 56, y: rect.midY - 14), size: 22, weight: i == tab ? .semibold : .regular, color: i == tab ? accent : ink)
    }

    // Header
    text("Summer in Portugal", CGPoint(x: 360, y: 110), size: 40, weight: .bold)
    text("Jul 4 – Jul 18 · 4 travelers", CGPoint(x: 362, y: 166), size: 22, color: muted)

    switch scene.tab {
    case 0: drawItinerary(t)
    case 1: drawBudget(t)
    default: drawPacking(t)
    }

    // Cursor with a click ring
    let c = cursor(t)
    if let click = lastClick(t) {
        let r = 14 + click.age * 60
        let ring = NSBezierPath(ovalIn: CGRect(x: click.at.x - r, y: click.at.y - r, width: 2 * r, height: 2 * r))
        accent.withAlphaComponent(0.5 * (1 - click.age / 0.35)).setStroke()
        ring.lineWidth = 4
        ring.stroke()
    }
    let arrow = NSBezierPath()
    arrow.move(to: c)
    for (dx, dy) in [(0.0, 34.0), (8.0, 26.0), (14.0, 40.0), (20.0, 37.0), (14.0, 24.0), (25.0, 24.0)] {
        arrow.line(to: CGPoint(x: c.x + dx, y: c.y + dy))
    }
    arrow.close()
    NSColor.black.setFill()
    arrow.fill()
    NSColor.white.setStroke()
    arrow.lineWidth = 2
    arrow.stroke()
}

func drawItinerary(_ t: Double) {
    let pressed = lastClick(t).map { hypot($0.at.x - addButton.x, $0.at.y - addButton.y) < 80 } ?? false
    box(CGRect(x: 1640, y: 120, width: 200, height: 60), pressed ? accent.blended(withFraction: 0.25, of: .black)! : accent, radius: 12)
    text("+ Add stop", CGPoint(x: 1678, y: 135), size: 22, weight: .semibold, color: .white)

    var stops = [("Porto", "Jul 4 – Jul 7", "3 nights", "€540"), ("Douro Valley", "Jul 7 – Jul 9", "2 nights", "€410"),
                 ("Coimbra", "Jul 9 – Jul 11", "2 nights", "€290")]
    if flag("row", t) {
        let city = typed("city", t)
        stops.append((city.isEmpty ? " " : city, flag("dates", t) ? "Jul 11 – Jul 15" : "Pick dates", flag("dates", t) ? "4 nights" : "", flag("dates", t) ? "€720" : ""))
    }
    for (i, stop) in stops.enumerated() {
        let y = 240 + i * 130
        box(CGRect(x: 360, y: y, width: 1480, height: 110), .white, radius: 16, stroke: line)
        box(CGRect(x: 392, y: y + 31, width: 48, height: 48), accent.withAlphaComponent(0.15), radius: 24)
        text("\(i + 1)", CGPoint(x: 408, y: y + 39), size: 24, weight: .bold, color: accent)
        text(stop.0, CGPoint(x: 470, y: y + 22), size: 30, weight: .semibold)
        text(stop.1, CGPoint(x: 940, y: y + 34), size: 24, color: stop.1 == "Pick dates" ? accent : muted)
        text(stop.2, CGPoint(x: 1300, y: y + 34), size: 24, color: muted)
        text(stop.3, CGPoint(x: 1700, y: y + 30), size: 28, weight: .semibold)
    }
    let total = flag("dates", t) ? "€1,960" : "€1,240"
    box(CGRect(x: 360, y: 1070, width: 1480, height: 1), line)
    text("Trip total", CGPoint(x: 360, y: 1095), size: 24, color: muted)
    text(total, CGPoint(x: 520, y: 1088), size: 32, weight: .bold)
    box(CGRect(x: 1660, y: 1084, width: 180, height: 54), flag("saved", t) ? NSColor.systemGreen : accent, radius: 12)
    text(flag("saved", t) ? "Saved" : "Save", CGPoint(x: flag("saved", t) ? 1716 : 1724, y: 1097), size: 22, weight: .semibold, color: .white)
}

func drawBudget(_ t: Double) {
    let rows = [("Porto", "€540", 0.27), ("Lisbon", "€720", 0.36), ("Douro Valley", "€410", 0.21), ("Coimbra", "€290", 0.15)]
    for (i, row) in rows.enumerated() {
        let y = CGFloat(380 + i * 120)
        let selected = i == 1 && flag("split", t)
        box(CGRect(x: 360, y: y, width: 1480, height: 96), selected ? accent.withAlphaComponent(0.08) : .white, radius: 16, stroke: selected ? accent : line)
        text(row.0, CGPoint(x: 400, y: y + 30), size: 28, weight: .semibold)
        box(CGRect(x: 800, y: y + 40, width: 700, height: 16), line, radius: 8)
        box(CGRect(x: 800, y: y + 40, width: 700 * CGFloat(row.2 / 0.36), height: 16), accent, radius: 8)
        text(selected ? "\(row.1) · €180 each" : row.1, CGPoint(x: selected ? 1560 : 1700, y: y + 28), size: 28, weight: .semibold)
    }
    text("Spent so far", CGPoint(x: 360, y: 250), size: 24, color: muted)
    text("€1,960 of €2,400", CGPoint(x: 360, y: 285), size: 40, weight: .bold)
}

func drawPacking(_ t: Double) {
    let items = ["Passports", "Sunscreen", "Chargers", "Hiking shoes", "Swimwear", "Rain jacket"]
    for (i, item) in items.enumerated() {
        let y = 250 + i * 100
        let done = i == 1 || i == 2 || (i == 0 && flag("packed", t))
        box(CGRect(x: 360, y: y, width: 1480, height: 80), .white, radius: 14, stroke: line)
        box(CGRect(x: 392, y: y + 24, width: 32, height: 32), done ? accent : .white, radius: 8, stroke: done ? nil : muted)
        if done { text("✓", CGPoint(x: 399, y: y + 22), size: 24, weight: .bold, color: .white) }
        text(item, CGPoint(x: 450, y: y + 22), size: 28, color: done ? muted : ink)
        text(["Ana", "Ben", "Ana", "Chloe", "Ben", "Dev"][i], CGPoint(x: 1720, y: y + 24), size: 24, color: muted)
    }
}

// MARK: Encoding

let ffmpegArgs = ["-hide_banner", "-loglevel", "error", "-y",
                  "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-"]
    + (silent ? [] : ["-i", wav.path])
    + ["-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
    + (silent ? ["-an"] : ["-c:a", "aac", "-b:a", "128k", "-shortest"])
    + [output]
let pipe = Pipe()
let ffmpeg = try run("/opt/homebrew/bin/ffmpeg", ffmpegArgs, stdin: pipe.fileHandleForReading)

let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
for frame in 0..<Int(duration * Double(fps)) {
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawFrame(Double(frame) / Double(fps))
        NSGraphicsContext.current = nil
    }
    pipe.fileHandleForWriting.write(Data(pixels))
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
print(String(format: "%@: %.1f s, scene %@%@", output, duration, sceneName, silent ? ", no sound" : ""))
exit(ffmpeg.terminationStatus)
