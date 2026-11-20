import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorStore {
    enum Status: Equatable {
        case idle
        case analyzing
        case exporting
        case exported(URL)
    }

    static let speedPresets: [(value: Double, label: String, key: Character)] = [
        (1, "1×", "1"), (1.1, "1.1×", "2"), (1.2, "1.2×", "3"),
        (1.5, "1.5×", "4"), (2, "2×", "5"), (4, "4×", "6"),
    ]

    private(set) var videoURL: URL?
    private(set) var duration: Double = 0
    private(set) var levels: [Float] = []
    private(set) var words: [Word]?
    private(set) var videoSize = CGSize(width: 16, height: 9)
    private(set) var plan = Plan(segments: [])
    private(set) var undoStack: [Plan] = []
    var selected = 0
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    private(set) var status: Status = .idle
    var errorMessage: String?
    var settings = DetectionSettings()

    let player = AVPlayer()

    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var lastWritten: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerAdvanced(to: time.seconds) }
        }
        statusObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    var hasVideo: Bool { videoURL != nil }
    var automaticThreshold: Double { SpeechDetector.automaticThreshold(levels) }
    var canUndo: Bool { !undoStack.isEmpty }
    var selectedSegment: Segment? { plan.segments.indices.contains(selected) ? plan.segments[selected] : nil }
    var planURL: URL? { videoURL.map(PlanFile.url(for:)) }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        errorMessage = nil
        status = .analyzing
        watchTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        let asset = AVURLAsset(url: url)
        do {
            let analysis = try await VideoAnalysis.read(url, transcribe: true)
            self.asset = asset
            self.videoURL = url
            duration = analysis.duration
            levels = analysis.levels
            words = analysis.words
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let turned = size.applying(transform)
                videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
            }
            undoStack = []
            selected = 0
            playhead = 0
            loadPlanFile(fallback: detectedPlan())
            status = .idle
            rebuildPlayer()
            startWatchingPlanFile()
        } catch {
            status = .idle
            errorMessage = "Couldn't open \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    /// Returns to the video list; the plan is already saved next to the video.
    func closeVideo() {
        watchTask?.cancel()
        rebuildTask?.cancel()
        segmentLoop = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        asset = nil
        videoURL = nil
        plan = Plan(segments: [])
        undoStack = []
        levels = []
        words = nil
        selected = 0
        playhead = 0
        status = .idle
        errorMessage = nil
    }

    private func detectedPlan() -> Plan {
        VideoAnalysis(duration: duration, levels: levels, words: words).plan(settings)
    }

    // MARK: Plan file

    private func loadPlanFile(fallback: Plan) {
        guard let planURL else { return }
        guard let text = try? String(contentsOf: planURL, encoding: .utf8) else {
            plan = fallback
            save()
            return
        }
        do {
            plan = try Plan.parse(text)
            lastWritten = text
        } catch {
            plan = fallback
            lastWritten = text
            reportPlanError(error)
        }
    }

    private func save() {
        guard let planURL else { return }
        let text = plan.serialized()
        do {
            try text.write(to: planURL, atomically: true, encoding: .utf8)
            lastWritten = text
        } catch {
            errorMessage = "Couldn't save \(planURL.lastPathComponent). \(error.localizedDescription)"
        }
    }

    private func startWatchingPlanFile() {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.reloadPlanFileIfChanged()
            }
        }
    }

    private func reloadPlanFileIfChanged() {
        guard let planURL, let text = try? String(contentsOf: planURL, encoding: .utf8), text != lastWritten else { return }
        lastWritten = text
        do {
            let parsed = try Plan.parse(text)
            guard parsed != plan else { return }
            undoStack.append(plan)
            plan = parsed
            selected = min(selected, max(plan.segments.count - 1, 0))
            errorMessage = nil
            rebuildPlayer()
        } catch {
            reportPlanError(error)
        }
    }

    private func reportPlanError(_ error: Error) {
        let name = planURL?.lastPathComponent ?? "The plan file"
        errorMessage = "\(name) has a mistake. \(error.localizedDescription) Fix the file, or keep editing here to replace it."
    }

    // MARK: Editing

    private func edit(_ change: (inout Plan) -> Bool) {
        var updated = plan
        guard change(&updated), updated != plan else { return }
        undoStack.append(plan)
        plan = updated
        save()
        rebuildPlayer()
    }

    func setSpeed(_ speed: Double) {
        let i = selected
        edit { plan in
            guard plan.segments.indices.contains(i) else { return false }
            plan.segments[i].speed = speed
            return true
        }
    }

    func toggleCut() {
        guard let segment = selectedSegment else { return }
        setSpeed(segment.isCut ? 1 : 0)
    }

    func splitAtPlayhead() {
        let time = playhead
        edit { $0.split(at: time) }
        selected = plan.index(at: playhead) ?? 0
    }

    func mergeWithNext() {
        let i = selected
        edit { $0.mergeWithNext(i) }
    }

    func redetect() {
        let detected = detectedPlan()
        edit { plan in
            plan = detected
            return true
        }
        selected = plan.index(at: playhead) ?? 0
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        plan = previous
        selected = min(selected, max(plan.segments.count - 1, 0))
        save()
        rebuildPlayer()
    }

    // MARK: Dragging a boundary

    @ObservationIgnored private var planBeforeDrag: Plan?
    @ObservationIgnored private var segmentLoop: Range<Double>?

    func beginBoundaryDrag() {
        planBeforeDrag = plan
    }

    func moveBoundary(after i: Int, to time: Double) {
        plan.moveBoundary(after: i, to: time)
    }

    func endBoundaryDrag() {
        guard let before = planBeforeDrag else { return }
        planBeforeDrag = nil
        guard before != plan else { return }
        undoStack.append(before)
        save()
        rebuildPlayer()
    }

    // MARK: Playback

    /// Plays only the selected segment, then returns to its start so it can be replayed.
    func playSegment() {
        guard let segment = selectedSegment, !segment.isCut else { return }
        seek(to: segment.start)
        segmentLoop = segment.start..<segment.end
        player.play()
    }

    /// Moves the playhead from a timeline click; playback pauses so the spot stays put.
    func scrub(to source: Double) {
        segmentLoop = nil
        player.pause()
        seek(to: source)
    }

    func togglePlay() {
        guard hasVideo else { return }
        segmentLoop = nil
        if isPlaying {
            player.pause()
            return
        }
        if plan.outputTime(forSource: playhead) >= plan.outputDuration - 0.05 {
            seek(to: plan.segments.first { !$0.isCut }?.start ?? 0)
        }
        player.play()
    }

    func seek(to source: Double) {
        playhead = min(max(source, 0), duration)
        selected = plan.index(at: playhead) ?? 0
        player.seek(to: cmTime(plan.outputTime(forSource: playhead)), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func selectNext() { selectSegment(selected + 1) }
    func selectPrevious() { selectSegment(selected - 1) }

    private func selectSegment(_ i: Int) {
        guard plan.segments.indices.contains(i) else { return }
        seek(to: plan.segments[i].start)
    }

    private func playerAdvanced(to output: Double) {
        guard isPlaying, planBeforeDrag == nil else { return }
        let source = plan.sourceTime(forOutput: output)
        if let loop = segmentLoop, source >= loop.upperBound - 0.02 || source < loop.lowerBound {
            segmentLoop = nil
            player.pause()
            seek(to: loop.lowerBound)
            return
        }
        playhead = source
        selected = plan.index(at: playhead) ?? 0
    }

    private func rebuildPlayer() {
        guard let asset else { return }
        rebuildTask?.cancel()
        let plan = plan
        let duration = duration
        rebuildTask = Task {
            do {
                let composition = try await EditComposer.composition(for: asset, plan: plan, duration: duration)
                guard !Task.isCancelled else { return }
                let wasPlaying = isPlaying
                let item = AVPlayerItem(asset: composition)
                item.audioTimePitchAlgorithm = .spectral
                player.replaceCurrentItem(with: item)
                _ = await player.seek(to: cmTime(plan.outputTime(forSource: playhead)), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
            } catch {
                errorMessage = "Couldn't build the preview. \(error.localizedDescription)"
            }
        }
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: EditComposer.timescale)
    }

    // MARK: Export

    func export() {
        guard let asset, let videoURL, status != .exporting else { return }
        let output = PlanFile.exportURL(for: videoURL)
        status = .exporting
        let plan = plan
        let duration = duration
        Task {
            do {
                try await EditComposer.render(asset: asset, plan: plan, duration: duration, to: output)
                status = .exported(output)
            } catch {
                status = .idle
                errorMessage = "Export didn't finish. \(error.localizedDescription) Try again, or check there's free disk space."
            }
        }
    }

    func revealExport() {
        guard case let .exported(url) = status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
