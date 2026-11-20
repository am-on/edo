import AVFoundation
import Observation
import Synchronization

/// Live microphone level through Apple's voice processing, which makes Edo offer the Control Center mic modes.
@MainActor
@Observable
final class MicMonitor {
    enum State: Equatable {
        case stopped
        case running
        case denied
        case failed
    }

    private(set) var state: State = .stopped
    /// Voice-band loudness of the last 50 ms, in dB.
    private(set) var level: Float = -100
    private(set) var activeMode = AVCaptureDevice.activeMicrophoneMode
    private(set) var preferredMode = AVCaptureDevice.preferredMicrophoneMode
    private(set) var deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
    private(set) var sampleRate = 48_000.0
    /// Receives the voice while a recording runs.
    let sink = AudioSink()

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var modeTask: Task<Void, Never>?

    func start() async {
        guard engine == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .denied
            return
        }
        let engine = AVAudioEngine()
        do {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // The main mixer stays untouched: connecting it gives the output a stereo format that voice processing,
            // with its multichannel input, can't start with.
            let format = input.outputFormat(forBus: 0)
            sampleRate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(sampleRate: format.sampleRate, sink: sink) { [weak self] level in
                Task { @MainActor in self?.level = level }
            })
            try engine.start()
        } catch {
            FileHandle.standardError.write(Data("edo: microphone didn't start: \(error)\n".utf8))
            state = .failed
            return
        }
        self.engine = engine
        state = .running
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        modeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.activeMode = AVCaptureDevice.activeMicrophoneMode
                self?.preferredMode = AVCaptureDevice.preferredMicrophoneMode
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        modeTask?.cancel()
        modeTask = nil
        sink.set(nil)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = -100
        if state == .running { state = .stopped }
    }

    func showModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// A monitor fixed in one state, for snapshots.
    static func preview(_ state: State, level: Float = -100, mode: AVCaptureDevice.MicrophoneMode = .voiceIsolation) -> MicMonitor {
        let mic = MicMonitor()
        mic.state = state
        mic.level = level
        mic.activeMode = mode
        mic.preferredMode = mode
        mic.deviceName = "MacBook Air Microphone"
        return mic
    }

    /// The tap runs on the audio thread, so it is built outside the main actor.
    nonisolated private static func tap(sampleRate: Double, sink: AudioSink, report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) var meter = LevelMeter(sampleRate: sampleRate, window: 0.05)
        return { buffer, time in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let hostTime = time.isHostTimeValid
                ? time.hostTime
                : mach_absolute_time() - AVAudioTime.hostTime(forSeconds: Double(samples.count) / sampleRate)
            sink.send(samples, hostTime: hostTime)
            meter.add(samples)
            if let last = meter.drain().last { report(last) }
        }
    }
}

/// Hands microphone samples from the audio thread to whoever records them.
final class AudioSink: Sendable {
    typealias Handler = @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void
    private let handler = Mutex<Handler?>(nil)

    func set(_ newHandler: Handler?) {
        handler.withLock { $0 = newHandler }
    }

    func send(_ samples: [Float], hostTime: UInt64) {
        handler.withLock { $0 }?(samples, hostTime)
    }
}

extension AVCaptureDevice.MicrophoneMode {
    var label: String {
        switch self {
        case .standard: "Standard"
        case .wideSpectrum: "Wide Spectrum"
        case .voiceIsolation: "Voice Isolation"
        @unknown default: "Unknown"
        }
    }
}
