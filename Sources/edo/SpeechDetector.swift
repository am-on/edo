import AVFoundation

struct Word: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct DetectionSettings: Equatable, Sendable {
    /// Loudness below which audio is quiet; nil picks it from the video's own levels.
    var thresholdDB: Double?
    /// Once speech starts, it continues until loudness drops this far below the threshold.
    var hysteresisDB: Double = 6
    /// Loud bursts shorter than this are clicks or bumps, not speech.
    var minSpeech: Double = 0.15
    /// Pauses shorter than this stay at normal speed.
    var minPause: Double = 1.0
    var margin: Double = 0.2
    var minQuiet: Double = 0.3
    var quietSpeed: Double = 1.2
    var useWords = true
}

/// Splits a video into speech and quiet segments from its loudness, confirmed by transcribed words when available.
enum SpeechDetector {
    static let fallbackThreshold = -35.0

    static func plan(levels: [Float], window: Double, duration: Double,
                     settings: DetectionSettings, words: [Word]? = nil) -> Plan {
        let threshold = settings.thresholdDB ?? automaticThreshold(levels)
        var mask = speechMask(levels, window: window, threshold: threshold, settings: settings)
        if let words, !words.isEmpty {
            mask = confirmed(mask, by: words, window: window)
        }

        var segments: [Segment] = []
        var cursor = 0.0
        func addSpeech(until end: Double) {
            guard end - cursor > 0.01 else { return }
            segments.append(Segment(start: cursor, end: end, speed: 1, note: transcript(cursor, end, words) ?? "speech"))
        }
        for run in runs(mask, of: false) {
            let start = Double(run.lowerBound) * window
            let end = min(Double(run.upperBound) * window, duration)
            guard end - start >= settings.minPause else { continue }
            let quietStart = Plan.round(run.lowerBound == 0 ? 0 : start + settings.margin)
            let quietEnd = run.upperBound >= mask.count ? duration : Plan.round(end - settings.margin)
            guard quietEnd - quietStart > settings.minQuiet else { continue }
            addSpeech(until: quietStart)
            // Keep a wholly quiet recording playable. Trim edge pauses when speech is present.
            let trim = (run.lowerBound == 0) != (run.upperBound == mask.count)
            segments.append(Segment(start: max(quietStart, cursor), end: quietEnd, speed: trim ? 0 : settings.quietSpeed, note: "quiet"))
            cursor = quietEnd
        }
        addSpeech(until: duration)
        if let last = segments.indices.last, segments[last].end < duration {
            segments[last].end = duration
        }
        return Plan(segments: segments)
    }

    /// Otsu's threshold between the noise floor and the voice, or the fallback when there aren't two clear groups.
    static func automaticThreshold(_ levels: [Float]) -> Double {
        guard levels.count >= 20 else { return fallbackThreshold }
        var histogram = [Double](repeating: 0, count: 101)
        for level in levels {
            histogram[Int((min(max(Double(level), -100), 0) + 100).rounded())] += 1
        }
        let total = Double(levels.count)
        let sumAll = histogram.indices.reduce(0) { $0 + Double($1) * histogram[$1] }
        var weightLow = 0.0
        var sumLow = 0.0
        var best = 0.0
        var bestBin = 65
        var separation = 0.0
        for bin in 0..<100 {
            weightLow += histogram[bin]
            sumLow += Double(bin) * histogram[bin]
            let weightHigh = total - weightLow
            guard weightLow > 0, weightHigh > 0 else { continue }
            let meanLow = sumLow / weightLow
            let meanHigh = (sumAll - sumLow) / weightHigh
            let between = weightLow * weightHigh * (meanHigh - meanLow) * (meanHigh - meanLow)
            if between > best {
                best = between
                bestBin = bin
                separation = meanHigh - meanLow
            }
        }
        return separation >= 12 ? Double(bestBin) - 100 + 0.5 : fallbackThreshold
    }

    static func speechMask(_ levels: [Float], window: Double, threshold: Double, settings: DetectionSettings) -> [Bool] {
        let loud = levels.map { Double($0) >= threshold }
        let low = threshold - settings.hysteresisDB
        var mask = loud
        for run in runs(loud, of: true) {
            var i = run.lowerBound - 1
            while i >= 0, !mask[i], Double(levels[i]) >= low { mask[i] = true; i -= 1 }
            i = run.upperBound
            while i < mask.count, !mask[i], Double(levels[i]) >= low { mask[i] = true; i += 1 }
        }
        let minWindows = Int((settings.minSpeech / window).rounded())
        for run in runs(mask, of: true) where run.count < minWindows {
            for i in run { mask[i] = false }
        }
        return mask
    }

    /// Keeps loud stretches where a word starts or that sit right next to such speech,
    /// and marks the start of every word as speech.
    static func confirmed(_ mask: [Bool], by words: [Word], window: Double, attachGap: Double = 0.4) -> [Bool] {
        var result = [Bool](repeating: false, count: mask.count)
        var pending: [Range<Int>] = []
        for run in runs(mask, of: true) {
            let start = Double(run.lowerBound) * window - 0.3
            let end = Double(run.upperBound) * window + 0.3
            if words.contains(where: { $0.start >= start && $0.start <= end }) {
                for i in run { result[i] = true }
            } else {
                pending.append(run)
            }
        }
        let reach = Int((attachGap / window).rounded())
        var attached = true
        while attached {
            attached = false
            pending.removeAll { run in
                let near = max(run.lowerBound - reach, 0)..<min(run.upperBound + reach, result.count)
                guard near.contains(where: { result[$0] }) else { return false }
                for i in run { result[i] = true }
                attached = true
                return true
            }
        }
        for word in words {
            let first = max(Int(word.start / window), 0)
            let last = min(Int((word.start + min(word.end - word.start, 0.4)) / window), result.count)
            if first < last {
                for i in first..<last { result[i] = true }
            }
        }
        return result
    }

    static func runs(_ mask: [Bool], of value: Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (i, element) in mask.enumerated() {
            if element == value {
                if start == nil { start = i }
            } else if let s = start {
                result.append(s..<i)
                start = nil
            }
        }
        if let s = start { result.append(s..<mask.count) }
        return result
    }

    private static func transcript(_ start: Double, _ end: Double, _ words: [Word]?) -> String? {
        guard let words else { return nil }
        let text = words.filter { $0.start >= start && $0.start < end }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

/// Audio loudness of a video in dBFS within the voice band, one value per `window` seconds.
enum AudioLevels {
    static let window = 0.05
    static let sampleRate = 16_000.0

    @concurrent
    static func read(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()

        var meter = LevelMeter(sampleRate: sampleRate, window: window)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            meter.add(samples)
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return meter.finish()
    }
}

/// Voice-band loudness per window: drops rumble below 100 Hz and hiss above 4 kHz before measuring.
struct LevelMeter {
    private var highPass: Biquad
    private var lowPass: Biquad
    private let perWindow: Int
    private var sum: Float = 0
    private var count = 0
    private(set) var levels: [Float] = []

    init(sampleRate: Double, window: Double) {
        highPass = .highPass(cutoff: 100, sampleRate: sampleRate)
        lowPass = .lowPass(cutoff: 4_000, sampleRate: sampleRate)
        perWindow = Int(sampleRate * window)
    }

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            let filtered = lowPass.process(highPass.process(sample))
            sum += filtered * filtered
            count += 1
            if count == perWindow { flush() }
        }
    }

    mutating func finish() -> [Float] {
        if count > 0 { flush() }
        return levels
    }

    /// Hands over the finished windows and forgets them, for live metering.
    mutating func drain() -> [Float] {
        defer { levels.removeAll(keepingCapacity: true) }
        return levels
    }

    private mutating func flush() {
        levels.append(20 * log10(max((sum / Float(count)).squareRoot(), 1e-6)))
        sum = 0
        count = 0
    }
}

/// Second-order filter with the Audio EQ Cookbook coefficients.
struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    static func highPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * q)
        return Biquad(b0: (1 + cos(w)) / 2, b1: -(1 + cos(w)), b2: (1 + cos(w)) / 2,
                      a0: 1 + alpha, a1: -2 * cos(w), a2: 1 - alpha)
    }

    static func lowPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * q)
        return Biquad(b0: (1 - cos(w)) / 2, b1: 1 - cos(w), b2: (1 - cos(w)) / 2,
                      a0: 1 + alpha, a1: -2 * cos(w), a2: 1 - alpha)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
