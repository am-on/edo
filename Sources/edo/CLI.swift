import AVFoundation
import Foundation

struct CLIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum CLI {
    static let usage = """
    usage: edo [video]                    open the editor
           edo detect <video> [options]   print the detected plan without saving it
           edo plan <video> [options]     detect and write <video>.plan.txt (--force replaces it)
           edo render <video> [output]    export the edit described by <video>.plan.txt
           edo levels <video> [from] [to] print loudness, the speech mask and words over time

    detection options:
      --loudness        ignore spoken words and use loudness only
      --threshold DB    treat audio below DB (e.g. -40) as quiet instead of choosing automatically
      --pause SECONDS   only speed up pauses at least this long (default 1)
      --speed X         speed for quiet parts (default 1.2)
    """

    @MainActor
    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw CLIError(usage) }
        let command = arguments[0]
        let video = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: video.path) else { throw CLIError("\(video.path) doesn't exist") }
        let options = Array(arguments.dropFirst(2))
        let planURL = PlanFile.url(for: video)

        switch command {
        case "detect", "plan":
            let settings = try detectionSettings(options)
            if command == "plan", FileManager.default.fileExists(atPath: planURL.path), !options.contains("--force") {
                throw CLIError("\(planURL.lastPathComponent) already exists; pass --force to replace it")
            }
            let analysis = try await VideoAnalysis.read(video, transcribe: settings.useWords)
            let plan = analysis.plan(settings)
            let threshold = settings.thresholdDB ?? SpeechDetector.automaticThreshold(analysis.levels)
            let words = analysis.words.map { "\($0.count) words" } ?? "no words"
            if command == "plan" {
                try plan.serialized().write(to: planURL, atomically: true, encoding: .utf8)
            }
            print(plan.serialized(), terminator: "")
            print(String(format: "# %d segments, quiet below %.0f dB, %@, %.1fs -> %.1fs",
                         plan.segments.count, threshold, words, analysis.duration, plan.outputDuration))
            if command == "plan" { print("# wrote \(planURL.path)") }
        case "levels":
            let analysis = try await VideoAnalysis.read(video, transcribe: true)
            let from = options.first.flatMap(Double.init) ?? 0
            let to = options.dropFirst().first.flatMap(Double.init) ?? analysis.duration
            let settings = DetectionSettings()
            let threshold = SpeechDetector.automaticThreshold(analysis.levels)
            var mask = SpeechDetector.speechMask(analysis.levels, window: AudioLevels.window, threshold: threshold, settings: settings)
            let loud = mask
            if let words = analysis.words { mask = SpeechDetector.confirmed(mask, by: words, window: AudioLevels.window) }
            print(String(format: "# quiet below %.0f dB; L = loud, S = counted as speech", threshold))
            for (i, level) in analysis.levels.enumerated() {
                let time = Double(i) * AudioLevels.window
                guard time >= from, time <= to else { continue }
                let bar = String(repeating: "█", count: max(0, Int((Double(level) + 70) / 2)))
                let words = (analysis.words ?? []).filter { $0.start >= time && $0.start < time + AudioLevels.window }.map(\.text)
                print(String(format: "%6.2f %6.1f %@%@ ", time, level, loud[i] ? "L" : " ", mask[i] ? "S" : " ") + bar.padding(toLength: 36, withPad: " ", startingAt: 0) + words.joined(separator: " "))
            }
        case "render":
            let asset = AVURLAsset(url: video)
            let duration = try await asset.load(.duration).seconds
            let plan: Plan
            if let text = try? String(contentsOf: planURL, encoding: .utf8) {
                plan = try Plan.parse(text)
            } else {
                plan = try await VideoAnalysis.read(video, transcribe: true).plan(DetectionSettings())
            }
            let output = options.first.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? PlanFile.exportURL(for: video)
            try await EditComposer.render(asset: asset, plan: plan, duration: duration, to: output)
            print(String(format: "%.1fs -> %.1fs  ", duration, plan.outputDuration) + output.path)
        default:
            throw CLIError(usage)
        }
    }

    private static func detectionSettings(_ options: [String]) throws -> DetectionSettings {
        var settings = DetectionSettings()
        var remaining = options[...]
        while let option = remaining.popFirst() {
            func value() throws -> Double {
                guard let text = remaining.popFirst(), let number = Double(text) else {
                    throw CLIError("\(option) needs a number")
                }
                return number
            }
            switch option {
            case "--loudness": settings.useWords = false
            case "--threshold": settings.thresholdDB = try value()
            case "--pause": settings.minPause = try value()
            case "--speed": settings.quietSpeed = try value()
            case "--force": break
            default: throw CLIError("unknown option \(option)\n\n\(usage)")
            }
        }
        return settings
    }
}
