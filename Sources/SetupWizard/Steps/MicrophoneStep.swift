import AVFoundation
import AppKit
import SwiftUI

struct MicrophoneStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    @StateObject private var meter = InputLevelMeter()
    @StateObject private var deviceList = WizardInputDeviceWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick your microphone")
                    .font(.system(size: 22, weight: .semibold))
                Text("Jot records from this device whenever you use the hotkey. Speak to see the level meter respond.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(deviceList.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()

                HStack {
                    Button("Reset to System Default") { inputDeviceUID = "" }
                        .controlSize(.small)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Input level")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                LevelMeterView(level: meter.level)
                    .frame(height: 48)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            deviceList.refresh()
            meter.start()
            coordinator.setChrome(WizardStepChrome(
                primaryTitle: "Continue",
                canAdvance: true,
                isPrimaryBusy: false,
                showsSkip: true
            ))
        }
        .onDisappear { meter.stop() }
    }
}

// MARK: - Level meter

private struct LevelMeterView: View {
    let level: Float
    private let barCount = 10

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let barWidth = (geo.size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: index))
                        .frame(width: max(barWidth, 2), height: height(for: index, container: geo.size.height))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func height(for index: Int, container: CGFloat) -> CGFloat {
        // Map the continuous level into 10 discrete bars: bar `i` lights once
        // the level crosses `(i + 1) / barCount`.
        let threshold = Float(index) / Float(barCount)
        let overshoot = max(0, min(1, (level - threshold) * Float(barCount)))
        let min = container * 0.15
        return min + CGFloat(overshoot) * (container - min)
    }

    private func color(for index: Int) -> Color {
        let fraction = Double(index) / Double(barCount - 1)
        if fraction > 0.85 { return .red }
        if fraction > 0.6 { return .orange }
        return .green
    }
}

@MainActor
private final class InputLevelMeter: ObservableObject {
    @Published var level: Float = 0

    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var peak: Float = 0

    func start() {
        guard engine == nil else { return }
        // Microphone permission is required to actually see meaningful values;
        // if it's not granted we still spin up the engine but the tap will
        // emit silence — the UI degrades to "bars sit idle" rather than
        // crashing. PermissionsStep is the gate; users reach this step only
        // after that (though Skip can bypass it).
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
            var maxAmp: Float = 0
            for i in 0..<frames {
                let v = abs(channel[i])
                if v > maxAmp { maxAmp = v }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Smooth decay so the bars don't flap violently.
                self.peak = Swift.max(maxAmp, self.peak * 0.8)
                self.level = min(1.0, self.peak)
            }
        }

        do {
            try engine.start()
            self.engine = engine
        } catch {
            // Tap was installed on the shared input node; tear it down so the
            // next mount can retry cleanly.
            input.removeTap(onBus: 0)
        }

        // Fallback decay — keeps bars settling even when the mic is silent.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peak *= 0.88
                self.level = min(1.0, self.peak)
            }
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        timer?.invalidate()
        timer = nil
        level = 0
        peak = 0
    }

    deinit {
        timer?.invalidate()
    }
}

@MainActor
private final class WizardInputDeviceWatcher: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = session.devices
    }
}
