import AppKit
import SwiftUI

@MainActor
enum Launch {
    static var url: URL?
}

struct EdoApp: App {
    @State private var store: EditorStore
    @State private var recorder: Recorder

    init() {
        let store = EditorStore()
        _store = State(initialValue: store)
        _recorder = State(initialValue: Recorder(store: store))
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Edo", id: "main") {
            ContentView()
                .environment(store)
                .environment(recorder)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .task {
                    Snapshot.store = store
                    Snapshot.log("task started")
                    if let url = Launch.url { await store.open(url) }
                    Snapshot.log("opened")
                    await Snapshot.takeIfRequested()
                    await Snapshot.recordTestIfRequested(recorder)
                }
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { EditorCommands(store: store, recorder: recorder) }
    }
}

struct EditorCommands: Commands {
    let store: EditorStore
    let recorder: Recorder

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") { store.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Record Screen…") { recorder.openSetup() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(recorder.phase != .idle)
            Button("Stop Recording") { Task { await recorder.stop() } }
                .disabled(!recorder.isRecording)
            Button("Back to Video List") { store.closeVideo() }
                .disabled(!store.hasVideo)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }
                .keyboardShortcut("z")
                .disabled(!store.canUndo)
        }
        CommandMenu("Video") {
            Group {
                Button(store.isPlaying ? "Pause" : "Play") { store.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Play Segment") { store.playSegment() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Previous Segment") { store.selectPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Segment") { store.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                ForEach(EditorStore.speedPresets, id: \.value) { preset in
                    Button("Speed \(preset.label)") { store.setSpeed(preset.value) }
                        .keyboardShortcut(KeyEquivalent(preset.key), modifiers: [])
                }
                Button("Cut or Restore") { store.toggleCut() }
                    .keyboardShortcut("x", modifiers: [])
                Divider()
                Button("Split at Playhead") { store.splitAtPlayhead() }
                    .keyboardShortcut("s", modifiers: [])
                Button("Merge with Next") { store.mergeWithNext() }
                    .keyboardShortcut("m", modifiers: [])
                Divider()
                Button("Detect Speech Again") { store.redetect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Export") { store.export() }
                    .keyboardShortcut("e")
            }
            .disabled(!store.hasVideo)
        }
    }
}
