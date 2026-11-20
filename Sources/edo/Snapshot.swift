import AppKit
import AVKit
import ScreenCaptureKit
import SwiftUI

/// Saves pictures of the editor for checking its layout, then quits.
///
/// EDO_SNAPSHOT=out.png saves the main window: a real screenshot when Edo may record the screen,
/// otherwise drawn offscreen with the current video frame drawn in. EDO_SNAPSHOT_TIME moves the playhead first;
/// EDO_SNAPSHOT_WIDTH and EDO_SNAPSHOT_HEIGHT size the window first, and
/// EDO_SNAPSHOT_DETECT=detect.png also saves the Detect panel, and
/// EDO_SNAPSHOT_RECORD=folder saves the recording screens in each state.
enum Snapshot {
    @MainActor static weak var store: EditorStore?
    static let started = Date()
    private static let environment = ProcessInfo.processInfo.environment

    static func log(_ message: String) {
        guard environment["EDO_SNAPSHOT"] != nil else { return }
        FileHandle.standardError.write(Data(String(format: "%.1fs %@\n", Date().timeIntervalSince(started), message).utf8))
    }

    @MainActor
    static func takeIfRequested() async {
        guard let path = environment["EDO_SNAPSHOT"] else { return }
        guard let window = NSApp.windows.first(where: \.isVisible) else { exit(1) }
        let width = environment["EDO_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? window.contentLayoutRect.width
        let height = environment["EDO_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 620
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        if let time = environment["EDO_SNAPSHOT_TIME"].flatMap(Double.init) { store?.scrub(to: time) }
        try? await Task.sleep(for: .seconds(2))

        if let image = await screenshot(of: window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } else {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            await drawVideoFrame(into: bitmap, window: window)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        if let detectPath = environment["EDO_SNAPSHOT_DETECT"], let store {
            save(DetectionSettingsView(done: {}).environment(store), to: detectPath)
        }
        if let folder = environment["EDO_SNAPSHOT_RECORD"], let store {
            saveRecording(into: URL(fileURLWithPath: folder), store: store)
        }
        exit(0)
    }

    /// The window as it is on screen, glass and tints included, when Edo may record the screen.
    @MainActor
    private static func screenshot(of window: NSWindow) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Video layers draw outside the view hierarchy, so the frame at the playhead is drawn where the video sits.
    @MainActor
    private static func drawVideoFrame(into bitmap: NSBitmapImageRep, window: NSWindow) async {
        guard let store, let asset = store.player.currentItem?.asset,
              let (view, rect) = videoRect(in: window.contentView) else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let frame = try? await generator.image(at: store.player.currentTime()).image else { return }
        let target = view.convert(rect, to: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSImage(cgImage: frame, size: target.size).draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private static func videoRect(in view: NSView?) -> (NSView, CGRect)? {
        guard let view else { return nil }
        if let player = view as? AVPlayerView { return (player, player.videoBounds) }
        if let layer = view.layer as? AVPlayerLayer { return (view, layer.videoRect) }
        for subview in view.subviews {
            if let found = videoRect(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func save(_ content: some View, to path: String) {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension Snapshot {
    @MainActor
    private static func saveRecording(into folder: URL, store: EditorStore) {
        func path(_ name: String) -> String { folder.appending(path: "\(name).png").path }
        let talking = MicMonitor.preview(.running, level: -22)
        let sheets: [(String, Recorder)] = [
            ("setup", .preview(store: store, mic: talking)),
            ("setup-mic-denied", .preview(store: store, mic: .preview(.denied))),
            ("setup-mic-failed", .preview(store: store, mic: .preview(.failed))),
            ("setup-no-screen-access", .preview(store: store, mic: talking, screenAccess: false)),
            ("setup-start-failed", .preview(store: store, mic: talking,
                                            startError: "The recording didn't start. Try again, or restart Edo if it keeps happening.")),
        ]
        for (name, recorder) in sheets {
            save(RecordView().environment(recorder), to: path(name))
        }
        let recording = Recorder.preview(store: store, mic: talking, phase: .recording(since: .now - 42))
        save(RecordingControls().environment(recording).padding(20), to: path("panel"))
        save(RecordingControls().environment(Recorder.preview(store: store, mic: .preview(.running, level: -3), phase: .recording(since: .now - 125))).padding(20),
             to: path("panel-loud"))
        save(RecordingControls().environment(Recorder.preview(store: store, mic: talking, phase: .saving)).padding(20), to: path("panel-saving"))

        guard let screen = NSScreen.main, let id = screen.displayID else { return }
        let picker = AreaPicker(initial: nil) { _ in }
        save(AreaToolbar(picker: picker, screen: screen).padding(20), to: path("toolbar-empty"))
        let size = screen.frame.size
        picker.select(CaptureArea(displayID: id, rect: CGRect(x: size.width * 0.2, y: size.height * 0.15,
                                                                width: size.width * 0.55, height: size.height * 0.6),
                                  displaySize: size, scale: screen.backingScaleFactor))
        let overlay = OverlayWindow(screen: screen, picker: picker)
        if let view = overlay.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path("overlay")))
        }
    }
}

extension Snapshot {
    /// EDO_RECORD_TEST=3 records the whole main screen for that many seconds, printing each step,
    /// then stops and opens the recording, which checks recording without anyone clicking.
    @MainActor
    static func recordTestIfRequested(_ recorder: Recorder) async {
        guard let seconds = environment["EDO_RECORD_TEST"].flatMap(Double.init), let screen = NSScreen.main else { return }
        func say(_ message: String) {
            FileHandle.standardError.write(Data(String(format: "%.1fs %@\n", Date().timeIntervalSince(started), message).utf8))
        }
        recorder.openSetup()
        try? await Task.sleep(for: .seconds(2))
        say("mic \(recorder.mic.state), screen access \(recorder.hasScreenAccess)")
        recorder.chooseArea()
        try? await Task.sleep(for: .seconds(1))
        recorder.confirmWholeScreen(screen)
        for _ in 0..<Int(seconds * 2) {
            try? await Task.sleep(for: .milliseconds(500))
            say("\(recorder.phase), mic level \(recorder.mic.level) dB")
        }
        await recorder.stop()
        say("opened \(store?.videoURL?.path ?? "nothing"), error: \(store?.errorMessage ?? "none")")
    }
}
