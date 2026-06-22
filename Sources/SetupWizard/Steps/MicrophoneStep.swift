import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI
import os.log

struct MicrophoneStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    /// Mirrors `GeneralPane`'s cache; see `docs/plans/mic-disconnect-handling.md`.
    @AppStorage("jot.inputDeviceLastName") private var inputDeviceLastName: String = ""
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
            .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Input device:", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    if !inputDeviceUID.isEmpty,
                       !deviceList.devices.contains(where: { $0.uniqueID == inputDeviceUID }) {
                        Text("Last used (not connected)").tag(inputDeviceUID)
                    }
                    ForEach(deviceList.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: inputDeviceUID) { _, newValue in
                    if newValue.isEmpty {
                        inputDeviceLastName = ""
                    } else if let device = deviceList.devices.first(where: { $0.uniqueID == newValue }) {
                        inputDeviceLastName = device.localizedName
                    }
                    // Restart the meter so the bars reflect the
                    // newly-bound device immediately.
                    meter.stop()
                    meter.start()
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

/// AUHAL-backed input-level preview for the wizard "Pick your microphone"
/// step. Pre-`92605be` this used `AVAudioEngine.installTap`, which we
/// proved silently delivers zero buffers on certain hardware/macOS combos
/// (the documented motivation for the recording-path AUHAL rewrite). The
/// wizard meter regressed because the rewrite missed this surviving
/// AVAudioEngine consumer; this class mirrors the AUHAL setup in
/// `Sources/Recording/AudioCapture.swift` (input scope on bus 1, output
/// scope disabled, `kAudioOutputUnitProperty_CurrentDevice` honoring
/// `jot.inputDeviceUID`, callback computes peak per render slice).
///
/// We deliberately drop the converter / writer / file path — meter only
/// needs the per-callback peak, then a `@MainActor` hop to update
/// `@Published var level`. The 5-second setup timeout, decay timer, and
/// `setupTask` cancellation race protection carry over so a wedged
/// `coreaudiod` cannot freeze the wizard pane.
@MainActor
private final class InputLevelMeter: ObservableObject {
    @Published var level: Float = 0

    private var unit: AudioUnit?
    private var ctx: MeterContext?
    private var renderABL: UnsafeMutablePointer<AudioBufferList>?
    private var renderBytes: UnsafeMutableRawPointer?
    private var timer: Timer?
    fileprivate var peak: Float = 0
    private var setupTask: Task<Void, Never>?
    /// Mirrors `AudioCapture.leakedContexts` — keeps heap allocations
    /// alive past a hung AUHAL teardown so the still-running input
    /// callback's raw refcon doesn't dangle.
    private var leakedContexts: [MeterContext] = []
    private var leakedRenderABLs: [UnsafeMutablePointer<AudioBufferList>] = []
    private var leakedRenderBytes: [UnsafeMutableRawPointer] = []
    private let log = Logger(subsystem: "com.jot.Jot", category: "WizardMeter")

    func start() {
        guard unit == nil, setupTask == nil else { return }
        // Microphone permission is required to see meaningful values;
        // if not granted, we still spin up but the AUHAL stream will
        // emit silence — UI degrades to "bars sit idle" rather than
        // crashing. PermissionsStep is the gate; users reach this step
        // only after that (Skip can bypass).
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        // Decay timer runs regardless of engine state so bars sit at 0
        // if AUHAL setup fails/times out — same UX as a silent mic.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peak *= 0.88
                self.level = min(1.0, self.peak)
            }
        }

        // Read the user's selected UID (matches the recording path so the
        // meter responds to the device the picker has currently bound).
        let selectedUID = UserDefaults.standard.string(forKey: "jot.inputDeviceUID") ?? ""

        // CoreAudio-touching setup runs on a background GCD queue under
        // a 5s timeout. `AudioComponentInstanceNew`, property gets, and
        // `AudioOutputUnitStart` can each block indefinitely when
        // `coreaudiod` is wedged. Doing this inline froze the wizard
        // pane in the AVAudioEngine version; we keep the offload.
        setupTask = Task { @MainActor [weak self] in
            guard let meter = self else { return }
            let setup = await Self.configureMeterAUHALWithTimeout(
                selectedUID: selectedUID,
                log: meter.log,
                seconds: 5
            )
            meter.setupTask = nil
            guard !Task.isCancelled, meter.unit == nil else {
                // stop() ran before setup finished — tear down the
                // orphan. If teardown times out, leak via the meter's
                // leak arrays (the audio thread may still touch the
                // refcon).
                if let setup {
                    let outcome = AudioCapture.boundedAUHALTeardown(
                        unit: setup.unit,
                        timeout: 2,
                        log: meter.log,
                        site: "WizardMeter.orphan"
                    )
                    if outcome == .completed {
                        setup.renderABL.deallocate()
                        setup.renderBytes.deallocate()
                    } else {
                        meter.leakedContexts.append(setup.ctx)
                        meter.leakedRenderABLs.append(setup.renderABL)
                        meter.leakedRenderBytes.append(setup.renderBytes)
                    }
                }
                return
            }
            guard let setup else { return }
            // Wire the back-reference now (callback uses it weakly).
            // Doing this after `start()` returned means the first few
            // render callbacks may arrive before the ref is set; they
            // see `meter == nil` and short-circuit, decaying via the
            // timer — same UX as a 50 ms warm-up.
            setup.ctx.meter = meter
            meter.unit = setup.unit
            meter.ctx = setup.ctx
            meter.renderABL = setup.renderABL
            meter.renderBytes = setup.renderBytes
        }
    }

    func stop() {
        setupTask?.cancel()
        setupTask = nil
        ctx?.markStopping()
        var outcome: AudioCapture.TeardownOutcome = .completed
        if let activeUnit = unit {
            outcome = AudioCapture.boundedAUHALTeardown(
                unit: activeUnit,
                timeout: 2,
                log: log,
                site: "WizardMeter.stop"
            )
        }
        // On timeout, leak the buffers + ctx — late-resuming dispose
        // could still touch them via the unretained refcon.
        if outcome == .completed {
            renderABL?.deallocate()
            renderBytes?.deallocate()
        } else {
            if let liveCtx = ctx { leakedContexts.append(liveCtx) }
            if let liveABL = renderABL { leakedRenderABLs.append(liveABL) }
            if let liveBytes = renderBytes { leakedRenderBytes.append(liveBytes) }
        }
        unit = nil
        ctx = nil
        renderABL = nil
        renderBytes = nil
        timer?.invalidate()
        timer = nil
        level = 0
        peak = 0
    }

    /// Called from the real-time render trampoline after each chunk.
    /// Hops to @MainActor to update the published level.
    fileprivate func ingest(peakAmp: Float) {
        let amp = peakAmp
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.peak = Swift.max(amp, self.peak * 0.8)
            self.level = min(1.0, self.peak)
        }
    }

    deinit {
        timer?.invalidate()
        // The AUHAL unit is owned by `stop()`; if the view tears down
        // without calling stop(), the unit leaks. Keep the same
        // pre-existing trade-off as the AVAudioEngine version.
    }

    // MARK: - AUHAL setup (background queue, bounded by timeout)

    fileprivate struct MeterSetup: @unchecked Sendable {
        let unit: AudioUnit
        let ctx: MeterContext
        let renderABL: UnsafeMutablePointer<AudioBufferList>
        let renderBytes: UnsafeMutableRawPointer
    }

    fileprivate nonisolated static func configureMeterAUHALWithTimeout(
        selectedUID: String,
        log: Logger,
        seconds: Double
    ) async -> MeterSetup? {
        await withCheckedContinuation { (cont: CheckedContinuation<MeterSetup?, Never>) in
            // Commit/abandon coordination: if the timeout fires first, a
            // late-resuming `configureMeterAUHAL` returns a fully started
            // unit that the awaiter has already abandoned. Without
            // explicit cleanup the unit keeps running orphaned. We
            // mirror `SetupAttempt.tryCommit/tryAbandon` from the
            // recording path.
            let lock = NSLock()
            var resolved = false
            DispatchQueue.global(qos: .userInitiated).async {
                let setup = configureMeterAUHAL(selectedUID: selectedUID, log: log)
                lock.lock()
                let alreadyTimedOut = resolved
                resolved = true
                lock.unlock()
                if alreadyTimedOut {
                    // Timeout already returned nil to the caller; tear
                    // down the orphan unit. Bounded teardown might hang
                    // (the original timeout was already due to a wedged
                    // CoreAudio); on timeout we can't deallocate without
                    // racing the audio thread, so the buffers leak. The
                    // ctx is local to this closure and goes out of
                    // scope cleanly after the dispose returns.
                    if let setup {
                        let outcome = AudioCapture.boundedAUHALTeardown(
                            unit: setup.unit,
                            timeout: 2,
                            log: log,
                            site: "WizardMeter.lateSetup"
                        )
                        if outcome == .completed {
                            setup.renderABL.deallocate()
                            setup.renderBytes.deallocate()
                        }
                        // Else: leak both buffers AND keep `setup.ctx`
                        // alive by retaining the box ref via a shared
                        // module-private leak set. Bounded to one-per-
                        // coreaudiod-hang.
                        else {
                            WizardMeterLeakRegistry.shared.retain(setup)
                        }
                    }
                } else {
                    cont.resume(returning: setup)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                let alreadyResolved = resolved
                resolved = true
                lock.unlock()
                if !alreadyResolved {
                    Task { await ErrorLog.shared.warn(component: "SetupWizard", message: "Wizard meter AUHAL setup timed out (>5s) — coreaudiod may be stuck; see Help → Troubleshooting") }
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func configureMeterAUHAL(selectedUID: String, log: Logger) -> MeterSetup? {
        // 1. Find AUHAL.
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(comp, &newUnit) == noErr, let u = newUnit else { return nil }

        // 2. Enable input scope (bus 1), disable output scope.
        var on: UInt32 = 1
        var off: UInt32 = 0
        guard AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, UInt32(MemoryLayout<UInt32>.size)) == noErr
        else {
            AudioComponentInstanceDispose(u)
            return nil
        }

        // 3. Resolve and bind device. Honors `jot.inputDeviceUID` so the
        // bars reflect whatever the picker selected.
        var devID: AudioDeviceID = 0
        if !selectedUID.isEmpty, let resolved = audioDeviceID(forUID: selectedUID) {
            devID = resolved
        } else {
            devID = systemDefaultInputDevice() ?? 0
        }
        guard devID != 0,
              AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else {
            AudioComponentInstanceDispose(u)
            return nil
        }

        // 4. Read native ASBD.
        var deviceASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceASBD, &asbdSize) == noErr,
              deviceASBD.mSampleRate > 0
        else {
            AudioComponentInstanceDispose(u)
            return nil
        }

        // 5. Set client ASBD: mono Float32 packed at device rate.
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: deviceASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(u)
            return nil
        }

        // 6. Pre-allocate render AudioBufferList — match recording path's 4096 floor.
        var slice: UInt32 = 4096
        var sliceSize = UInt32(MemoryLayout<UInt32>.size)
        let sliceStatus = AudioUnitGetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &sliceSize)
        let chosenMaxFrames: UInt32 = (sliceStatus == noErr && slice > 0) ? Swift.max(slice, 4096) : 4096
        let bufferCapacity = Int(chosenMaxFrames * 4)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: bufferCapacity, alignment: MemoryLayout<Float>.alignment)
        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        abl.pointee.mNumberBuffers = 1
        abl.pointee.mBuffers.mNumberChannels = 1
        abl.pointee.mBuffers.mDataByteSize = UInt32(bufferCapacity)
        abl.pointee.mBuffers.mData = bytes

        // 7. Wire callback context + input proc.
        let ctx = MeterContext(unit: u, renderABL: abl, maxFrames: chosenMaxFrames, log: log)
        var cb = AURenderCallbackStruct(
            inputProc: wizardMeterAUHALInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())
        )
        guard AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(u) == noErr,
              AudioOutputUnitStart(u) == noErr
        else {
            abl.deallocate()
            bytes.deallocate()
            AudioComponentInstanceDispose(u)
            return nil
        }

        return MeterSetup(unit: u, ctx: ctx, renderABL: abl, renderBytes: bytes)
    }

    private nonisolated static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard ids.withUnsafeMutableBytes({ raw in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, raw.baseAddress!)
        }) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<CFString?>.size)
            var cfStr: CFString? = nil
            let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
                ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                    AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &size, ptr)
                }
            }
            if status == noErr, let s = cfStr, s as String == uid { return id }
        }
        return nil
    }

    private nonisolated static func systemDefaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        guard status == noErr, devID != 0 else { return nil }
        return devID
    }
}

/// Module-private retainer for `MeterContext` + render buffers that we
/// could not safely deallocate (bounded teardown timed out and the
/// context is no longer reachable from any `InputLevelMeter` instance).
/// This is a process-lifetime leak — bounded to one entry per coreaudiod
/// hang. Without it, late-resuming `AudioComponentInstanceDispose` could
/// dereference a freed refcon.
fileprivate final class WizardMeterLeakRegistry: @unchecked Sendable {
    static let shared = WizardMeterLeakRegistry()
    private let lock = NSLock()
    private var contexts: [MeterContext] = []
    private var renderABLs: [UnsafeMutablePointer<AudioBufferList>] = []
    private var renderBytes: [UnsafeMutableRawPointer] = []

    func retain(_ setup: InputLevelMeter.MeterSetup) {
        lock.lock(); defer { lock.unlock() }
        contexts.append(setup.ctx)
        renderABLs.append(setup.renderABL)
        renderBytes.append(setup.renderBytes)
    }
}

// MARK: - Meter callback context + trampoline

/// Heap-boxed state the C input callback needs. The callback computes a
/// peak amplitude per render slice and hops to @MainActor via the
/// `meter` weak ref to update the UI.
fileprivate final class MeterContext: @unchecked Sendable {
    let unit: AudioUnit
    let renderABL: UnsafeMutablePointer<AudioBufferList>
    let maxFrames: UInt32
    let log: Logger
    weak var meter: InputLevelMeter?
    private let stopLock = OSAllocatedUnfairLock(initialState: false)
    /// One-shot — the wizard meter doesn't need to log every render
    /// failure (mic pulled mid-preview just means the bars fall to 0
    /// via the decay timer). Log the first miss only, off the RT
    /// thread.
    private let renderErrorLogged = OSAllocatedUnfairLock(initialState: false)

    init(unit: AudioUnit, renderABL: UnsafeMutablePointer<AudioBufferList>, maxFrames: UInt32, log: Logger) {
        self.unit = unit
        self.renderABL = renderABL
        self.maxFrames = maxFrames
        self.log = log
    }

    func markStopping() {
        stopLock.withLock { $0 = true }
    }

    func isStoppingNow() -> Bool {
        stopLock.withLock { $0 }
    }

    func tryLogRenderError() -> Bool {
        renderErrorLogged.withLock { fired in
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

/// AUHAL input callback for the wizard meter. Mirrors the recording
/// path's structure but skips the converter / writer / amplitude-publisher
/// fan-out — meter only needs the peak.
private func wizardMeterAUHALInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<MeterContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard !ctx.isStoppingNow() else { return noErr }

    let capacity = ctx.maxFrames * 4
    ctx.renderABL.pointee.mBuffers.mDataByteSize = capacity

    let renderStatus = AudioUnitRender(
        ctx.unit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        ctx.renderABL
    )
    if renderStatus != noErr {
        // Mic pulled while wizard is open — bars decay to 0 via the
        // timer. Log the first miss only, off the real-time thread.
        if ctx.tryLogRenderError() {
            let log = ctx.log
            let status = renderStatus
            DispatchQueue.global(qos: .utility).async {
                log.warning("WizardMeter AudioUnitRender failed: \(status, privacy: .public)")
            }
        }
        return renderStatus
    }

    guard inNumberFrames > 0,
          let bytes = ctx.renderABL.pointee.mBuffers.mData
    else {
        return noErr
    }

    let floats = bytes.assumingMemoryBound(to: Float.self)
    var maxAmp: Float = 0
    let count = Int(inNumberFrames)
    for i in 0..<count {
        let v = abs(floats[i])
        if v > maxAmp { maxAmp = v }
    }
    let peakAmp = maxAmp
    if let meter = ctx.meter {
        // Hop off the real-time thread via the meter's @MainActor entry.
        // `Task { @MainActor }` allocates but is acceptable in the
        // setup/preview path — this isn't the recording-of-the-user's
        // dictation hot path; it's the wizard preview.
        Task { @MainActor [weak meter] in
            meter?.ingest(peakAmp: peakAmp)
        }
    }
    return noErr
}

@MainActor
private final class WizardInputDeviceWatcher: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []

    private var observer: NSObjectProtocol?
    private var disconnectedObserver: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        disconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let disconnectedObserver { NotificationCenter.default.removeObserver(disconnectedObserver) }
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
