import AVFoundation
import SwiftUI

/// Before recording: check the microphone and its mic mode, and that Edo may record the screen.
struct RecordView: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        let mic = recorder.mic
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Screen")
                .font(.title3.weight(.semibold))

            if let error = recorder.startError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch mic.state {
            case .running, .stopped:
                VStack(alignment: .leading, spacing: 8) {
                    Label(mic.deviceName ?? "Microphone", systemImage: "mic.fill")
                    LevelBar(level: mic.level)
                    HStack {
                        Text("Mic mode: \(mic.activeMode.label)")
                        Spacer()
                        Button("Change…") { mic.showModes() }
                    }
                    if mic.activeMode != mic.preferredMode {
                        Text("Control Center is set to \(mic.preferredMode.label), but this microphone doesn't support it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edo can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then open this again.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            case .failed:
                Text("The microphone didn't start. Check that a microphone is connected, then close this and open it again.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !recorder.hasScreenAccess {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Edo needs your permission to record the screen. After you allow it, quit and reopen Edo.", systemImage: "rectangle.dashed.badge.record")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow Screen Recording…") { recorder.requestScreenAccess() }
                }
            }

            HStack {
                Text("Drag the area to record, then talk. Stop opens it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { recorder.showsSetup = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Area…") { recorder.chooseArea() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mic.state != .running || !recorder.hasScreenAccess)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Loudness from -60 dB (empty) to 0 dB (full), green while talking and red near clipping.
struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(max((level + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > -6 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * fraction)
                    .animation(.linear(duration: 0.05), value: fraction)
            }
        }
        .frame(height: 8)
    }
}
