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

    @concurrent
    static func render(asset: AVURLAsset, plan: Plan, duration: Double, to url: URL) async throws {
        let composition = try await composition(for: asset, plan: plan, duration: duration)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError.unavailable
        }
        session.audioTimePitchAlgorithm = .spectral
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mov)
    }
}
