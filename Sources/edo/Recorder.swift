import AppKit
import ScreenCaptureKit
import SwiftUI

/// Records an area of the screen with the voice-processed microphone, then opens the recording in the editor.
@MainActor
@Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case choosingArea
        case starting
        case recording(since: Date)
        case saving
    }

    private(set) var phase: Phase = .idle
    var showsSetup = false
    private(set) var hasScreenAccess = CGPreflightScreenCaptureAccess()
    /// Set when the last attempt to record failed; shown in the setup sheet.
    private(set) var startError: String?
    let mic: MicMonitor
    let script = ScriptPrompter()

    @ObservationIgnored private let store: EditorStore
    @ObservationIgnored private var picker: AreaPicker?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var writer: RecordingWriter?
    @ObservationIgnored private var watcher: StreamWatcher?
    @ObservationIgnored private var area: CaptureArea?
    /// Set when Start Over couldn't save the take before; shown once the recording opens.
    @ObservationIgnored private var lostTake = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var frame: NSWindow?
    @ObservationIgnored private weak var mainWindow: NSWindow?

    init(store: EditorStore, mic: MicMonitor = MicMonitor()) {
        self.store = store
        self.mic = mic
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    // MARK: Setup

    func openSetup() {
        guard phase == .idle else { return }
        hasScreenAccess = CGPreflightScreenCaptureAccess()
        startError = nil
        lostTake = false
        showsSetup = true
        Task { await mic.start() }
    }

    /// Called when the setup sheet goes away without recording.
    func setupDismissed() {
        if phase == .idle { mic.stop() }
    }

    func requestScreenAccess() {
        // macOS shows its prompt once; after that the switch is in System Settings.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }

    func chooseArea() {
        guard phase == .idle, mic.state == .running else { return }
        showsSetup = false
        phase = .choosingArea
        mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        mainWindow?.orderOut(nil)
        let picker = AreaPicker(initial: CaptureArea.last, script: script) { [weak self] area in
            guard let self else { return }
            self.picker = nil
            if let area {
                self.script.startRecording()
                self.phase = .starting
                self.showRecordingWindows(for: area)
                Task { await self.start(area) }
            } else {
                self.script.close()
                self.phase = .idle
                self.mic.stop()
                self.showMainWindow()
            }
        }
        self.picker = picker
        picker.show()
    }

    // MARK: Recording

    private func start(_ area: CaptureArea) async {
        CaptureArea.last = area
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == area.displayID }) else {
                throw RecorderError.displayGone
            }
            // Edo's own windows, like the recording panel, stay out of the video.
            let edo = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: edo, exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.sourceRect = area.rect
            config.width = area.pixelWidth
            config.height = area.pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = true
            config.queueDepth = 6

            let url = CaptureArea.newRecordingURL(in: RecentVideos.folders.left)
            let writer = try RecordingWriter(url: url, width: area.pixelWidth, height: area.pixelHeight, sampleRate: mic.sampleRate)
            let watcher = StreamWatcher { [weak self] in
                Task { @MainActor in await self?.stop() }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: watcher)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            mic.sink.set { samples, hostTime in writer.appendAudio(samples, hostTime: hostTime) }
            try await stream.startCapture()

            self.writer = writer
            self.stream = stream
            self.watcher = watcher
            self.area = area
            phase = .recording(since: .now)
        } catch {
            FileHandle.standardError.write(Data("edo: recording didn't start: \(error)\n".utf8))
            mic.sink.set(nil)
            phase = .idle
            hasScreenAccess = CGPreflightScreenCaptureAccess()
            startError = hasScreenAccess
                ? "The recording didn't start. Try again, or restart Edo if it keeps happening."
                : "Edo can't record the screen yet. Allow it below, then quit and reopen Edo."
            showMainWindow()
            hideRecordingWindows()
            showsSetup = true
        }
    }

    func stop() async {
        guard isRecording, let writer else { return }
        phase = .saving
        await endCapture()
        mic.stop()
        do {
            try await writer.finish()
            phase = .idle
            showMainWindow()
            hideRecordingWindows()
            await store.open(writer.url)
            if lostTake {
                store.errorMessage = "An earlier take couldn't be saved. Check there's free disk space."
            }
        } catch {
            FileHandle.standardError.write(Data("edo: recording wasn't saved: \(error)\n".utf8))
            try? FileManager.default.removeItem(at: writer.url)
            phase = .idle
            showMainWindow()
            hideRecordingWindows()
            store.errorMessage = "The recording couldn't be saved. Check there's free disk space and record again."
        }
    }

    /// Saves the take so far on the Desktop and starts a new recording of the same area.
    func startOver() async {
        guard isRecording, let writer, let area else { return }
        phase = .starting
        await endCapture()
        do {
            try await writer.finish()
        } catch {
            FileHandle.standardError.write(Data("edo: the previous take wasn't saved: \(error)\n".utf8))
            try? FileManager.default.removeItem(at: writer.url)
            lostTake = true
        }
        await start(area)
    }

    /// Stops the screen capture and the audio going into the movie; the mic keeps running.
    private func endCapture() async {
        try? await stream?.stopCapture()
        stream = nil
        watcher = nil
        mic.sink.set(nil)
        writer = nil
        area = nil
    }

    /// A recorder fixed in one state, for snapshots.
    static func preview(store: EditorStore, mic: MicMonitor, screenAccess: Bool = true, startError: String? = nil,
                        phase: Phase = .idle) -> Recorder {
        let recorder = Recorder(store: store, mic: mic)
        recorder.hasScreenAccess = screenAccess
        recorder.startError = startError
        recorder.phase = phase
        return recorder
    }

    /// Records the whole screen while the area picker is open, for EDO_RECORD_TEST.
    func confirmWholeScreen(_ screen: NSScreen) {
        picker?.selectWholeDisplay(of: screen)
        picker?.confirm()
    }

    private func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Runs after the main window is back: macOS quits Edo when none of its windows are on screen.
    private func hideRecordingWindows() {
        panel?.orderOut(nil)
        frame?.orderOut(nil)
        script.close()
        panel = nil
        frame = nil
    }

    private func showRecordingWindows(for area: CaptureArea) {
        guard let screen = NSScreen.showing(area.displayID) else { return }
        // The capture area counts from the display's top-left corner; windows from the bottom-left.
        let rect = CGRect(x: screen.frame.minX + area.rect.minX, y: screen.frame.maxY - area.rect.maxY,
                          width: area.rect.width, height: area.rect.height)
        let frame = AreaFrameWindow(around: rect)
        frame.orderFrontRegardless()
        self.frame = frame

        let panel = RecordingPanel(content: RecordingControls().environment(self))
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 4))
        panel.orderFrontRegardless()
        self.panel = panel

    }
}

enum RecorderError: LocalizedError {
    case displayGone
    var errorDescription: String? { "The display to record isn't connected." }
}

/// Stops the recording when macOS ends it, for example from the screen-recording item in the menu bar.
private final class StreamWatcher: NSObject, SCStreamDelegate, Sendable {
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("edo: screen capture stopped: \(error)\n".utf8))
        onStop()
    }
}

/// A floating panel that stays out of the way: it never takes focus from the app being recorded.
private final class RecordingPanel: NSPanel {
    init(content: some View) {
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        super.init(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = host
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// A thin outline just outside the recorded area, so you can see what's in the video.
private final class AreaFrameWindow: NSWindow {
    init(around rect: CGRect) {
        let outset = rect.insetBy(dx: -3, dy: -3)
        super.init(contentRect: outset, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView:
            Rectangle()
                .strokeBorder(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
        )
    }
}

/// Start Over, timer, live mic level, mic mode and Stop, shown while recording.
struct RecordingControls: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        HStack(spacing: 12) {
            // Start Over sits at the far end from Stop, so neither is clicked by mistake.
            Button {
                Task { await recorder.startOver() }
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
            .help("Save this take and start a new recording")
            .disabled(!recorder.isRecording)
            Divider().frame(height: 16)
            Circle().fill(.red).frame(width: 10, height: 10)
            Group {
                switch recorder.phase {
                case let .recording(since): Text(since, style: .timer).monospacedDigit()
                case .saving: Text("Saving…").foregroundStyle(.secondary)
                default: Text("Starting…").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, alignment: .leading)
            LevelBar(level: recorder.mic.level)
                .frame(width: 80)
            Button {
                recorder.mic.showModes()
            } label: {
                Text(recorder.mic.activeMode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change the mic mode")
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!recorder.isRecording)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }
}
