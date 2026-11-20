import AVFoundation

struct Segment: Equatable, Sendable {
    var start: Double
    var end: Double
    /// Playback rate; 0 removes the segment from the output.
    var speed: Double
    var note: String = ""

    var duration: Double { end - start }
    var isCut: Bool { speed == 0 }
    var outputDuration: Double { isCut ? 0 : duration / speed }
}

enum PlanError: LocalizedError, Equatable {
    case badLine(Int, String)
    case overlap(Int)

    var errorDescription: String? {
        switch self {
        case let .badLine(line, text):
            "Line \(line) should read “start end speed”, like “3.46 5.72 1.2”, but reads “\(text)”."
        case let .overlap(line):
            "Line \(line) starts before the previous segment ends."
        }
    }
}

/// An edit of one video: contiguous segments in source time, each with a playback speed.
struct Plan: Equatable, Sendable {
    var segments: [Segment]

    static let header = """
    # Edo edit plan. One line per segment, in order:
    #   start end speed  # note
    # Times are seconds in the original video. Speed 1 is normal, 1.5 is 50% faster,
    # 0 cuts the segment, and gaps between lines are cut too.
    # Edo reloads this file whenever it changes on disk.
    """

    var outputDuration: Double { segments.reduce(0) { $0 + $1.outputDuration } }

    func index(at time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.start <= time } ?? 0
    }

    func outputTime(forSource time: Double) -> Double {
        var output = 0.0
        for segment in segments {
            if time >= segment.end {
                output += segment.outputDuration
                continue
            }
            if time > segment.start && !segment.isCut {
                output += (time - segment.start) / segment.speed
            }
            break
        }
        return output
    }

    func sourceTime(forOutput time: Double) -> Double {
        var remaining = time
        for segment in segments where !segment.isCut {
            if remaining < segment.outputDuration {
                return segment.start + remaining * segment.speed
            }
            remaining -= segment.outputDuration
        }
        return segments.last { !$0.isCut }?.end ?? 0
    }

    @discardableResult
    mutating func split(at time: Double, minimum: Double = 0.1) -> Bool {
        let time = Plan.round(time)
        guard let i = index(at: time) else { return false }
        let segment = segments[i]
        guard time - segment.start >= minimum, segment.end - time >= minimum else { return false }
        segments[i].end = time
        var second = segment
        second.start = time
        segments.insert(second, at: i + 1)
        return true
    }

    @discardableResult
    mutating func mergeWithNext(_ i: Int) -> Bool {
        guard segments.indices.contains(i), i + 1 < segments.count else { return false }
        segments[i].end = segments[i + 1].end
        segments.remove(at: i + 1)
        return true
    }

    mutating func moveBoundary(after i: Int, to time: Double, minimum: Double = 0.1) {
        guard segments.indices.contains(i), i + 1 < segments.count else { return }
        let low = segments[i].start + minimum
        let high = segments[i + 1].end - minimum
        guard low <= high else { return }
        let clamped = Plan.round(min(max(time, low), high))
        segments[i].end = clamped
        segments[i + 1].start = clamped
    }

    func serialized() -> String {
        var lines = [Plan.header]
        for segment in segments {
            let speed = Plan.format(segment.speed).padding(toLength: 5, withPad: " ", startingAt: 0)
            var line = String(format: "%7.2f %7.2f  ", segment.start, segment.end) + speed
            if !segment.note.isEmpty { line += "  # \(segment.note)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) throws -> Plan {
        var segments: [Segment] = []
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let body = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if body.isEmpty { continue }
            let note = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let fields = body.split(whereSeparator: \.isWhitespace)
            let values = fields.compactMap { Double($0) }
            guard fields.count == 3, values.count == 3, values[1] >= values[0], values[0] >= 0, values[2] >= 0 else {
                throw PlanError.badLine(number + 1, body)
            }
            if values[1] - values[0] < 0.005 { continue }
            if let previous = segments.last {
                if values[0] < previous.end - 0.0001 { throw PlanError.overlap(number + 1) }
                if values[0] > previous.end {
                    segments.append(Segment(start: previous.end, end: values[0], speed: 0, note: "gap"))
                }
            } else if values[0] > 0 {
                segments.append(Segment(start: 0, end: values[0], speed: 0, note: "gap"))
            }
            segments.append(Segment(start: values[0], end: values[1], speed: values[2], note: note))
        }
        return Plan(segments: segments)
    }

    static func format(_ speed: Double) -> String {
        String(format: "%g", speed)
    }

    static func round(_ time: Double) -> Double {
        (time * 100).rounded() / 100
    }
}

enum PlanFile {
    static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("plan.txt")
    }

    static func exportURL(for video: URL) -> URL {
        let name = video.deletingPathExtension().lastPathComponent
        return video.deletingLastPathComponent().appendingPathComponent("\(name)-edited.mov")
    }
}

/// Everything detection needs from a video, read once.
struct VideoAnalysis: Sendable {
    var duration: Double
    var levels: [Float]
    var words: [Word]?

    @concurrent
    static func read(_ url: URL, transcribe: Bool) async throws -> VideoAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let levels = try await AudioLevels.read(url)
        let words = transcribe ? (try? await WordTranscriber.words(in: url)) ?? nil : nil
        return VideoAnalysis(duration: duration, levels: levels, words: words)
    }

    func plan(_ settings: DetectionSettings) -> Plan {
        SpeechDetector.plan(levels: levels, window: AudioLevels.window, duration: duration,
                            settings: settings, words: settings.useWords ? words : nil)
    }
}
