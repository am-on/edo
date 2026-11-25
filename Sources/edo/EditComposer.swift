import AVFoundation

enum ExportError: LocalizedError {
    case unavailable

    var errorDescription: String? { "This Mac can't export this video." }
}

/// Turns a plan into an AVFoundation composition that plays and exports the edit.
enum EditComposer {
    static let timescale: CMTimeScale = 60_000

    @concurrent
    static func composition(for asset: AVURLAsset, plan: Plan, duration: Double) async throws -> sending AVMutableComposition {
        let composition = AVMutableComposition()
        let assetEnd = CMTime(seconds: duration, preferredTimescale: timescale)
        var cursor = CMTime.zero
        for segment in plan.segments where !segment.isCut {
            let start = CMTime(seconds: segment.start, preferredTimescale: timescale)
            let end = CMTimeMinimum(CMTime(seconds: segment.end, preferredTimescale: timescale), assetEnd)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            try await composition.insertTimeRange(range, of: asset, at: cursor)
            if segment.speed == 1 {
                cursor = cursor + range.duration
            } else {
                let scaled = CMTime(seconds: range.duration.seconds / segment.speed, preferredTimescale: timescale)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
                cursor = cursor + scaled
            }
        }
        if let source = try await asset.loadTracks(withMediaType: .video).first,
           let track = composition.tracks(withMediaType: .video).first {
            track.preferredTransform = try await source.load(.preferredTransform)
        }
        return composition
    }

    /// Decodes the composition and encodes it again from time zero, so each track of the movie is
    /// one continuous run of samples that every player, browsers included, plays to the end.
    @concurrent
    static func render(asset: AVURLAsset, plan: Plan, duration: Double, to url: URL) async throws {
        let composition = try await composition(for: asset, plan: plan, duration: duration)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        guard !videoTracks.isEmpty, let sourceVideo else { throw ExportError.unavailable }

        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var pumps: [Pump] = []

        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = videoComposition
        let (dataRate, frameRate) = try await sourceVideo.load(.estimatedDataRate, .nominalFrameRate)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoComposition.renderSize.width,
            AVVideoHeightKey: videoComposition.renderSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(Double(dataRate), 1_000_000),
                AVVideoExpectedSourceFrameRateKey: frameRate > 0 ? frameRate : 60,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        reader.add(videoOutput)
        writer.add(videoInput)
        pumps.append(Pump(output: videoOutput, input: videoInput))

        if !audioTracks.isEmpty, let sourceAudio {
            let format = try await sourceAudio.load(.formatDescriptions).first
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let sampleRate = format.map(\.mSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? 48_000
            let channels = format.map { Int($0.mChannelsPerFrame) }.flatMap { (1...2).contains($0) ? $0 : nil } ?? 2
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ])
            audioOutput.audioTimePitchAlgorithm = .spectral
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 64_000 * channels,
            ])
            reader.add(audioOutput)
            writer.add(audioInput)
            pumps.append(Pump(output: audioOutput, input: audioInput))
        }

        try? FileManager.default.removeItem(at: url)
        guard reader.startReading() else { throw reader.error ?? ExportError.unavailable }
        guard writer.startWriting() else { throw writer.error ?? ExportError.unavailable }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup { group in
            for pump in pumps {
                group.addTask { await pump.run() }
            }
        }
        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? reader.error ?? ExportError.unavailable
        }
        writer.endSession(atSourceTime: composition.duration)
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

/// Copies one track's samples from the reader to the writer whenever the writer can take more.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "edo.export")

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }
}
