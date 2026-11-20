import AVFoundation
import ScreenCaptureKit

/// Writes screen frames and microphone audio into one movie. Both are stamped on the host clock,
/// so the voice stays in sync with the screen.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noFrames
        case audioFormat

        var errorDescription: String? {
            switch self {
            case .noFrames: "No screen frames arrived."
            case .audioFormat: "The microphone format isn't supported."
            }
        }
    }

    let url: URL
    /// Every append runs here; ScreenCaptureKit delivers its frames on it directly.
    let queue = DispatchQueue(label: "edo.recording")

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let sampleRate: Double
    private let audioFormat: CMAudioFormatDescription
    private var started: CMTime?

    init(url: URL, width: Int, height: Int, sampleRate: Double, frameRate: Int = 60) throws {
        self.url = url
        self.sampleRate = sampleRate
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // About 14 Mbit/s for a full Retina MacBook screen: screen content is mostly still.
        let bitRate = max(Double(width * height * frameRate) * 0.04, 2_000_000)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true

        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { throw Failure.audioFormat }
        audioFormat = format

        writer.add(video)
        writer.add(audio)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.hasNewFrame(sampleBuffer) else { return }
        appendVideo(sampleBuffer)
    }

    /// Runs on `queue`. The first frame starts the movie.
    func appendVideo(_ buffer: CMSampleBuffer) {
        if started == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = buffer.presentationTimeStamp
        }
        if writer.status == .writing, video.isReadyForMoreMediaData {
            video.append(buffer)
        }
    }

    /// Mono samples whose first one was captured at `hostTime` (mach absolute time).
    func appendAudio(_ samples: [Float], hostTime: UInt64) {
        queue.async { [self] in
            guard let started, writer.status == .writing, audio.isReadyForMoreMediaData else { return }
            var time = CMClockMakeHostTimeFromSystemUnits(hostTime)
            var samples = samples[...]
            if time < started {
                let skip = Int(((started - time).seconds * sampleRate).rounded(.up))
                guard skip < samples.count else { return }
                samples = samples.dropFirst(skip)
                time = time + CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(sampleRate))
            }
            if let buffer = sampleBuffer(Array(samples), at: time) {
                audio.append(buffer)
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard started != nil else {
                    writer.cancelWriting()
                    continuation.resume(throwing: Failure.noFrames)
                    return
                }
                video.markAsFinished()
                audio.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error ?? Failure.noFrames)
                    }
                }
            }
        }
    }

    private func sampleBuffer(_ samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: samples.count,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer
        )
        return buffer
    }

    /// ScreenCaptureKit also sends buffers without an image while the screen doesn't change.
    private static func hasNewFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}
