import AppKit
import SwiftUI

/// A script on screen while you record. You paste it and place it while choosing the area;
/// Edo's windows stay out of the video, so only you see it.
@MainActor
@Observable
final class ScriptPrompter {
    var text: String
    private(set) var isShown: Bool
    /// The script can be edited while choosing the area, and is read-only while recording.
    private(set) var isEditing = false

    @ObservationIgnored private var panel: ScriptPanel?
    @ObservationIgnored private let defaults: UserDefaults?

    private enum Key {
        static let text = "script"
        static let shown = "scriptShown"
        static let frame = "scriptFrame"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        text = defaults.string(forKey: Key.text) ?? ""
        isShown = defaults.bool(forKey: Key.shown)
    }

    /// A prompter that never saves, for snapshots.
    init(previewText: String, shown: Bool, editing: Bool = false) {
        defaults = nil
        text = previewText
        isShown = shown
        isEditing = editing
    }

    /// Shows the script for editing above the area picker, if it's turned on.
    func showForEditing() {
        guard isShown else { return }
        isEditing = true
        let panel = panel ?? makePanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.orderFrontRegardless()
    }

    func setShown(_ shown: Bool) {
        isShown = shown
        if shown {
            showForEditing()
            panel?.makeKeyAndOrderFront(nil)
        } else {
            close()
        }
        save()
    }

    /// Keeps the script on screen, read-only, where you placed it; hides it when it's empty.
    func startRecording() {
        guard isShown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            close()
            return
        }
        isEditing = false
        let panel = panel ?? makePanel()
        panel.level = .floating
        panel.orderFrontRegardless()
        save()
    }

    func close() {
        save()
        panel?.orderOut(nil)
        panel = nil
        isEditing = false
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(text, forKey: Key.text)
        defaults.set(isShown, forKey: Key.shown)
        if let panel { defaults.set(NSStringFromRect(panel.frame), forKey: Key.frame) }
    }

    private func makePanel() -> ScriptPanel {
        let panel = ScriptPanel(content: ScriptPanelView(prompter: self), frame: savedFrame() ?? Self.defaultFrame())
        self.panel = panel
        return panel
    }

    /// The last place you put the script, while it's still on a connected screen.
    private func savedFrame() -> CGRect? {
        guard let saved = defaults?.string(forKey: Key.frame) else { return nil }
        let frame = NSRectFromString(saved)
        guard frame.width >= ScriptPanel.minSize.width, frame.height >= ScriptPanel.minSize.height,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    /// Top center of the main screen.
    private static func defaultFrame() -> CGRect {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = CGSize(width: 560, height: 220)
        return CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8, width: size.width, height: size.height)
    }
}

/// Moves by its top edge or background and resizes by its edges, without taking focus from the app being recorded.
private final class ScriptPanel: NSPanel {
    static let minSize = CGSize(width: 240, height: 90)

    init(content: some View, frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = NSHostingView(rootView: content)
        setFrame(frame, display: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        minSize = Self.minSize
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // A see-through background, so you can still see what the panel covers.
        isOpaque = false
        backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.25)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

struct ScriptPanelView: View {
    @Bindable var prompter: ScriptPrompter
    /// Text fills the panel up to this size, and gets smaller down to `minFontSize` when the script is long.
    static let maxFontSize: CGFloat = 40
    static let minFontSize: CGFloat = 10
    /// The text view's own inset on each side.
    private static let inset: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if prompter.isEditing {
                Text("Drag here to move, or an edge to resize. The text fits the panel. It isn't in the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, Self.inset)
            }
            GeometryReader { geometry in
                let size = Self.fittingFontSize(prompter.text.isEmpty ? "Paste your script here" : prompter.text, in: geometry.size)
                let font = Font.system(size: size, weight: .medium)
                if prompter.isEditing {
                    TextEditor(text: $prompter.text)
                        .font(font)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if prompter.text.isEmpty {
                                Text("Paste your script here")
                                    .font(font)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, Self.inset)
                                    .allowsHitTesting(false)
                            }
                        }
                } else {
                    Text(prompter.text)
                        .font(font)
                        .padding(.leading, Self.inset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // A soft halo keeps the text readable over a busy screen.
            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 3)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The largest whole-point size at which `text` wraps to fit `space`, between the smallest and largest size.
    static func fittingFontSize(_ text: String, in space: CGSize) -> CGFloat {
        let width = space.width - inset * 2
        guard width > 0, space.height > 0 else { return minFontSize }
        var low = Int(minFontSize), high = Int(maxFontSize)
        while low < high {
            let mid = (low + high + 1) / 2
            let font = NSFont.systemFont(ofSize: CGFloat(mid), weight: .medium)
            let height = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
            ).height
            if height <= space.height { low = mid } else { high = mid - 1 }
        }
        return CGFloat(low)
    }
}
