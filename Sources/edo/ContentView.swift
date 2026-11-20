import AVKit
import SwiftUI

struct ContentView: View {
    @Environment(EditorStore.self) private var store
    @Environment(Recorder.self) private var recorder

    var body: some View {
        VStack(spacing: 0) {
            if store.hasVideo {
                PlayerView(player: store.player)
                    .aspectRatio(store.videoSize, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .onTapGesture { store.togglePlay() }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    EditTimeline()
                    ControlBar()
                    Text("Space play · Return play segment · ←/→ segment · 1–6 speed · X cut · S or double-click split · M merge · drag a boundary to trim")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                WelcomeView()
            }
        }
        .overlay {
            if store.status == .analyzing {
                ProgressView("Finding speech…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .top) {
            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
            }
        }
        .sheet(isPresented: Bindable(recorder).showsSetup, onDismiss: recorder.setupDismissed) {
            RecordView().environment(recorder)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.open(url) }
            return true
        }
        .navigationTitle(store.videoURL?.lastPathComponent ?? "Edo")
        .toolbar {
            if store.hasVideo {
                EditorToolbar()
            }
        }
    }
}

/// Title-bar buttons while a video is open: back to the video list on the left, Detect and Export on the right.
private struct EditorToolbar: ToolbarContent {
    @Environment(EditorStore.self) private var store
    @State private var showsDetection = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { store.closeVideo() } label: {
                toolbarLabel("Videos", systemImage: "chevron.left")
            }
            .help("Back to the video list. Your edits are saved.")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showsDetection = true } label: {
                toolbarLabel("Detect", systemImage: "waveform")
            }
            .help("Find speech again with different settings")
            .popover(isPresented: $showsDetection, arrowEdge: .bottom) {
                DetectionSettingsView { showsDetection = false }
            }
            switch store.status {
            case .exporting:
                ProgressView().controlSize(.small)
                Text("Exporting…")
            case let .exported(url):
                Button { store.revealExport() } label: {
                    toolbarLabel("Show in Finder", systemImage: "folder")
                }
                .help(url.lastPathComponent)
                Button { store.export() } label: {
                    toolbarLabel("Export Again", systemImage: "square.and.arrow.up")
                }
            default:
                Button { store.export() } label: {
                    toolbarLabel("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Toolbar capsules hug their text, so the title gets a little room before the capsule's end.
private func toolbarLabel(_ title: String, systemImage: String) -> some View {
    Label {
        Text(title).padding(.trailing, 4)
    } icon: {
        Image(systemName: systemImage)
    }
    .labelStyle(.titleAndIcon)
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .frame(maxWidth: 640)
    }
}

private struct ControlBar: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
                store.togglePlay()
            }
            .labelStyle(.iconOnly)
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(clock(store.playhead)) / \(clock(store.duration))")
                    .monospacedDigit()
                Text("Edited: \(clock(store.plan.outputDuration))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)

            if store.selectedSegment != nil {
                Picker("Speed", selection: speedBinding) {
                    ForEach(EditorStore.speedPresets, id: \.value) { preset in
                        Text(preset.label).tag(preset.value)
                    }
                    Text("Cut").tag(0.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 0)

            ViewThatFits(in: .horizontal) {
                tools.labelStyle(.titleAndIcon)
                tools.labelStyle(.iconOnly)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 8) {
            Button("Split", systemImage: "scissors") { store.splitAtPlayhead() }
                .help("Split at the playhead (S)")
            Button("Merge", systemImage: "arrow.right.to.line") { store.mergeWithNext() }
                .help("Merge with the next segment (M)")
        }
        .fixedSize()
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { store.selectedSegment?.speed ?? 1 },
            set: { store.setSpeed($0) }
        )
    }
}

struct DetectionSettingsView: View {
    @Environment(EditorStore.self) private var store
    let done: () -> Void

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("Find speech")
                .font(.headline)

            option {
                Toggle("Use spoken words", isOn: $store.settings.useWords)
            } detail: {
                Text(wordsStatus)
            }

            option {
                Toggle("Pick the quiet level automatically", isOn: automaticBinding)
            } detail: {
                if let threshold = store.settings.thresholdDB {
                    Slider(value: Binding(get: { threshold }, set: { store.settings.thresholdDB = $0 }), in: -70...(-15), step: 1) {
                        Text("Quiet below")
                    }
                    .labelsHidden()
                    Text("Quiet below \(Int(threshold)) dB. Raise it if clicks count as talking; lower it if quiet words get sped up.")
                } else {
                    Text("Quiet below \(Int(store.automaticThreshold)) dB, picked from this video.")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Speed up pauses longer than")
                    Picker("Speed up pauses longer than", selection: $store.settings.minPause) {
                        ForEach([0.5, 1, 1.5, 2, 3], id: \.self) { seconds in
                            Text(String(format: "%g s", seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Quiet parts play at")
                    Picker("Quiet parts play at", selection: $store.settings.quietSpeed) {
                        ForEach(EditorStore.speedPresets, id: \.value) { preset in
                            Text(preset.label).tag(preset.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                Text("This replaces your segments. Undo brings them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Detect Again") {
                    store.redetect()
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private func option(@ViewBuilder _ control: () -> some View, @ViewBuilder detail: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            control()
            VStack(alignment: .leading, spacing: 6) {
                detail()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
        }
    }

    private var wordsStatus: String {
        guard let words = store.words else {
            return "Transcription isn't available for this video, so Edo uses loudness only."
        }
        return words.isEmpty
            ? "No words were heard, so Edo uses loudness only."
            : "Found \(words.count) words. Loud parts count as talking only where you say a word, so clicks are ignored."
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { store.settings.thresholdDB == nil },
            set: { store.settings.thresholdDB = $0 ? nil : store.automaticThreshold.rounded() }
        )
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

func clock(_ seconds: Double) -> String {
    let total = max(seconds, 0)
    let minutes = Int(total) / 60
    return String(format: "%d:%04.1f", minutes, total - Double(minutes * 60))
}
