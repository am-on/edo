import AppKit
import Observation
import SwiftUI

/// Dims every display and lets you choose the area to record, like the macOS screenshot tool:
/// drag to draw it, drag inside to move it, drag an edge or knob to resize it. Return records and Esc cancels.
@MainActor
@Observable
final class AreaPicker {
    private(set) var area: CaptureArea?
    @ObservationIgnored private var overlays: [OverlayWindow] = []
    @ObservationIgnored private let onDone: (CaptureArea?) -> Void

    /// `onDone` must show its next window before returning: the overlays close right after it,
    /// and macOS quits Edo when none of its windows are left on screen.
    init(initial: CaptureArea?, onDone: @escaping (CaptureArea?) -> Void) {
        self.onDone = onDone
        let displays = NSScreen.screens.compactMap(\.displayID)
        area = initial.flatMap { displays.contains($0.displayID) ? $0 : nil }
    }

    func show() {
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0, picker: self) }
        for overlay in overlays { overlay.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        NSApp.activate()
    }

    func select(_ newArea: CaptureArea?) {
        area = newArea
        for overlay in overlays { overlay.contentView?.needsDisplay = true }
    }

    func selectWholeDisplay(of screen: NSScreen) {
        guard let id = screen.displayID else { return }
        select(.wholeDisplay(id, size: screen.frame.size, scale: screen.backingScaleFactor))
    }

    func confirm() {
        guard let area else { return }
        onDone(area)
        close()
    }

    func cancel() {
        onDone(nil)
        close()
    }

    private func close() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = []
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, picker: AreaPicker) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let selection = SelectionView(screen: screen, picker: picker)
        let toolbar = NSHostingView(rootView: AreaToolbar(picker: picker, screen: screen))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        selection.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: selection.centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: selection.bottomAnchor, constant: -48),
        ])
        contentView = selection
    }

    override var canBecomeKey: Bool { true }
}

/// Draws the dimmed screen with the chosen area cut out, and turns drags into an area.
private final class SelectionView: NSView {
    private let screen: NSScreen
    private let displayID: CGDirectDisplayID?
    private let picker: AreaPicker
    private var drag: AreaDrag?

    init(screen: NSScreen, picker: AreaPicker) {
        self.screen = screen
        displayID = screen.displayID
        self.picker = picker
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let area = picker.area, area.displayID == displayID else { return nil }
        return area.rect
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard let selection, let area = picker.area else { return }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.setLineDash([6, 4], count: 2, phase: 0)
        border.stroke()

        for handle in AreaDrag.Handle.all {
            let center = handle.point(on: selection)
            let knob = NSBezierPath(ovalIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            knob.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            knob.lineWidth = 1
            knob.stroke()
        }

        let label = "\(area.pixelWidth) × \(area.pixelHeight)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.maxX - size.width - 12, y: selection.maxY + 10)
        if origin.y + size.height + 8 > bounds.maxY { origin.y = selection.maxY - size.height - 14 }
        let background = CGRect(x: origin.x - 6, y: origin.y - 2, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        drag = AreaDrag.starting(at: convert(event.locationInWindow, from: nil), area: selection)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let displayID, let drag,
              let rect = drag.area(at: convert(event.locationInWindow, from: nil), within: bounds) else { return }
        picker.select(CaptureArea(displayID: displayID, rect: rect, displaySize: bounds.size, scale: screen.backingScaleFactor))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: picker.cancel()
        case 36, 76: picker.confirm()
        default: super.keyDown(with: event)
        }
    }

    private func updateCursor(at point: CGPoint) {
        if let toolbar = subviews.first, toolbar.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        switch AreaDrag.starting(at: point, area: selection) {
        case .create: NSCursor.crosshair.set()
        case .move: NSCursor.openHand.set()
        case let .resize(handle, _): Self.cursor(for: handle).set()
        }
    }

    private static func cursor(for handle: AreaDrag.Handle) -> NSCursor {
        // The view is flipped, so the area's top is the screen's top.
        let position: NSCursor.FrameResizePosition = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        default: .left
        }
        return .frameResize(position: position, directions: .all)
    }
}

struct AreaToolbar: View {
    let picker: AreaPicker
    let screen: NSScreen

    var body: some View {
        HStack(spacing: 10) {
            Text(picker.area == nil ? "Drag to choose the area to record." : "Drag the area or its edges to adjust it.")
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Button("Whole Screen") { picker.selectWholeDisplay(of: screen) }
            Button("Cancel") { picker.cancel() }
            Button("Record") { picker.confirm() }
                .buttonStyle(.borderedProminent)
                .disabled(picker.area == nil)
        }
        .controlSize(.large)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen showing a display, for turning a capture area back into window coordinates.
    static func showing(_ displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}
