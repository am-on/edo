import AVFoundation
import Speech

/// Word timings from macOS's on-device transcription.
enum WordTranscriber {
    /// Returns nil when this Mac can't transcribe the Mac's language or English.
    @concurrent
    static func words(in url: URL) async throws -> [Word]? {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = locale ?? fallback else { return nil }

        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = transcriber.results
        let collector = Task {
            var words: [Word] = []
            for try await result in results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    words.append(Word(start: range.start.seconds, end: range.end.seconds, text: text))
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
