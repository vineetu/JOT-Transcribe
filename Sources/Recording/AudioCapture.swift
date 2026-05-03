@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

/// Errors surfaced by `AudioCapture` when the capture path fails in a
/// way the caller needs to distinguish. Device/driver errors are wrapped
/// rather than swallowed so `RecorderController` can render a message.
public enum AudioCaptureError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case converterUnavailable
    case engineStart(Error)
    case engineStartTimeout
    case fileCreate(Error)
    case conversion(Error)

    /// User-facing message shown when we detect the CoreAudio subsystem is
    /// wedged. Callers that surface `engineStartTimeout` should show this
    /// as-is (no "Could not start recording:" prefix) and leave the
    /// follow-up instructions to the Help → Troubleshooting card.
    public static let engineStartTimeoutMessage =
        "Audio system isn't responding — see Help → Troubleshooting."
}

/// Disconnect events emitted by `AudioCapture` while a session is running.
/// Currently single-case, but enumerated so callers can switch
/// exhaustively when more sources land (e.g. system route change).
public enum AudioCaptureDisconnectEvent: Sendable, Equatable {
    /// `AudioUnitRender` returned a non-zero status while the AUHAL
    /// callback was active — the bound device dropped off the bus.
    case renderError(OSStatus)
    /// `.AVCaptureDeviceWasDisconnected` fired for the UID we are
    /// currently bound to (debounced 250 ms to ride out Bluetooth
    /// flicker).
    case deviceListDropped
}

/// Surface returned to the controller after a successful
/// `AudioCapture.stop()` so it can decide whether to surface a
/// "Recorded with system default — \(savedName) was unavailable."
/// notice pill.
public struct AudioCaptureFallbackInfo: Sendable, Equatable {
    /// The UID the user had selected at `start()` time. Empty if the user
    /// is on system default.
    public let savedUID: String
    /// Cached display name for that UID (`jot.inputDeviceLastName`).
    /// Empty when the cache is empty AND we couldn't backfill it
    /// (rare — first session after upgrading from a build that
    /// pre-dates the cache).
    public let savedName: String
    /// Display name of the device we actually recorded from.
    public let actualDeviceName: String
    /// True when the saved UID could not be resolved and we fell back
    /// to the system default. False in normal operation.
    public let didFallback: Bool
}

/// Direct CoreAudio AUHAL (`kAudioUnitSubType_HALOutput`) capture path.
///
/// This mirrors `mic-test/variant-4-coreaudio-auhal/Source/Recorder.swift`
/// at the AUHAL boundary, with one Jot-specific addition: rendered
/// device-rate Float32 mono buffers are converted on a dedicated writer
/// queue to `AudioFormat.target` before being appended to memory and WAV.
public actor AudioCapture: AudioCapturing {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AudioCapture")

    nonisolated(unsafe) public weak var amplitudePublisher: AmplitudePublisher?

    private var unit: AudioUnit?
    private var renderABL: UnsafeMutablePointer<AudioBufferList>?
    private var renderBytes: UnsafeMutableRawPointer?
    private var maxFrames: UInt32 = 0
    private var fileURL: URL?
    private var startedAt: Date?
    private var ctx: CallbackContext?
    private var attempt: SetupAttempt?
    private var cancelRequestedDuringSetup = false
    /// Captured during `start()` and read by `stop()` so the controller
    /// can present a "Recorded with system default — \(savedName) was
    /// unavailable." notice. Reset on every `start()`.
    private var pendingFallbackInfo: AudioCaptureFallbackInfo?
    /// Disconnect event plumbing. Built fresh each session; held here
    /// (actor-isolated) until either the consumer reads via
    /// `disconnectEvents()` or the session ends. The continuation lives
    /// on the active `CallbackContext` so the real-time render trampoline
    /// can yield through a serial GCD queue without touching this actor.
    private var disconnectStream: AsyncStream<AudioCaptureDisconnectEvent>?
    private var disconnectContinuation: AsyncStream<AudioCaptureDisconnectEvent>.Continuation?

    private let recordingsDirectory: URL
    private let writerQueue = DispatchQueue(label: "com.jot.AudioCapture.writer", qos: .userInitiated)
    /// Serial queue the real-time AUHAL callback `dispatch_async`es onto when
    /// it needs to do anything that isn't lock-free atomic work — namely
    /// yielding a disconnect event onto the AsyncStream continuation. Keeps
    /// the render trampoline free of allocation / Swift-concurrency.
    private let disconnectQueue = DispatchQueue(label: "com.jot.AudioCapture.disconnect", qos: .userInitiated)
    /// `AVCaptureDevice.wasDisconnectedNotification` observer scoped to the
    /// active session. Belt-and-suspenders for the rare case where AUHAL
    /// stops delivering callbacks before its render proc reports an error
    /// (per `docs/plans/mic-disconnect-handling.md` §3). 250 ms debounce
    /// rides out Bluetooth flicker.
    private var deviceListObserver: NSObjectProtocol?
    /// Heap-boxed contexts and render buffers we deliberately leak when
    /// `boundedAUHALTeardown` times out. The audio thread may still be
    /// inside the input proc holding a raw `Unmanaged.takeUnretainedValue`
    /// refcon to a `CallbackContext`; we keep the actor's strong ref
    /// alive by stashing the box here so the heap allocation isn't
    /// reclaimed under it. Same idea for the render `AudioBufferList` /
    /// backing bytes pointers.
    private var leakedContexts: [CallbackContext] = []
    private var leakedRenderABLs: [UnsafeMutablePointer<AudioBufferList>] = []
    private var leakedRenderBytes: [UnsafeMutableRawPointer] = []
    private let outstandingLock = OSAllocatedUnfairLock(initialState: 0)
    private static let outstandingLimit = 64

    public init(recordingsDirectory: URL = AudioCapture.defaultRecordingsDirectory) {
        self.recordingsDirectory = recordingsDirectory
    }

    public func setAmplitudePublisher(_ publisher: AmplitudePublisher?) {
        amplitudePublisher = publisher
    }

    /// Hand the controller a stream of disconnect events for the
    /// currently-running session. Returns an empty (already-finished)
    /// stream when no session is active so the caller's `for await`
    /// loop tears down cleanly.
    ///
    /// Per `docs/plans/mic-disconnect-handling.md` §3 the stream is
    /// constructed once per `start()` and the same stream object is
    /// returned for the duration of that session.
    public func disconnectEvents() -> AsyncStream<AudioCaptureDisconnectEvent> {
        if let stream = disconnectStream {
            return stream
        }
        // No active session — hand back an already-finished stream so the
        // caller's `for await` exits immediately.
        let (stream, continuation) = AsyncStream<AudioCaptureDisconnectEvent>.makeStream()
        continuation.finish()
        return stream
    }

    /// Snapshot of why the bound device may have changed during the
    /// just-finished session. Read by `VoiceInputPipeline` /
    /// `RecorderController` after `stop()` to surface the
    /// "Recorded with system default" notice. Returns `nil` when no
    /// session ever ran or when the saved UID resolved cleanly.
    public func lastFallbackInfo() -> AudioCaptureFallbackInfo? {
        pendingFallbackInfo
    }

    /// `~/Library/Application Support/Jot/Recordings/`. Kept identical to
    /// `AudioCapture` so callers see the same on-disk recording location.
    public static var defaultRecordingsDirectory: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Jot/Recordings", isDirectory: true)
    }

    // MARK: - Start / Stop

    public func start() async throws {
        guard unit == nil, attempt == nil else { throw AudioCaptureError.alreadyRunning }

        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let url = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let selectedUID = UserDefaults.standard.string(forKey: "jot.inputDeviceUID") ?? ""
        let savedNameCache = UserDefaults.standard.string(forKey: "jot.inputDeviceLastName") ?? ""
        let publisher = amplitudePublisher
        let setupAttempt = SetupAttempt()
        setupAttempt.fileURL = url
        attempt = setupAttempt
        cancelRequestedDuringSetup = false
        // Reset prior session's fallback info so a stale `didFallback=true`
        // can't leak into a fresh session.
        pendingFallbackInfo = nil
        // Build a fresh disconnect stream for this session. The
        // continuation is parked on the upcoming `CallbackContext` so
        // the real-time render trampoline can yield through
        // `disconnectQueue` without touching this actor.
        let (newStream, newContinuation) = AsyncStream<AudioCaptureDisconnectEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        disconnectStream = newStream
        disconnectContinuation = newContinuation
        defer {
            attempt = nil
            cancelRequestedDuringSetup = false
        }

        let setup: AUHALSetup
        do {
            setup = try await Self.configureAUHALWithTimeout(
                attempt: setupAttempt,
                selectedUID: selectedUID,
                savedNameCache: savedNameCache,
                url: url,
                amplitudePublisher: publisher,
                writerQueue: writerQueue,
                disconnectQueue: disconnectQueue,
                disconnectContinuation: newContinuation,
                outstandingLock: outstandingLock,
                log: log,
                seconds: 5
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            if cancelRequestedDuringSetup || Task.isCancelled {
                throw CancellationError()
            }
            switch error {
            case AudioCaptureError.engineStartTimeout:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AUHAL setup timed out (>5s) — coreaudiod may be stuck; see Help → Troubleshooting") }
            case AudioCaptureError.engineStart(let inner):
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AUHAL start failed", context: ["error": ErrorLog.redactedAppleError(inner)]) }
            case AudioCaptureError.fileCreate(let inner):
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "Recording file create failed", context: ["error": ErrorLog.redactedAppleError(inner)]) }
            case AudioCaptureError.converterUnavailable:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AVAudioConverter unavailable") }
            default:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AUHAL setup failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            }
            throw error
        }

        if cancelRequestedDuringSetup || Task.isCancelled {
            disposeCommittedSetup(setup, deleteFile: true)
            throw CancellationError()
        }

        unit = setup.unit
        renderABL = setup.renderABL
        renderBytes = setup.renderBytes
        maxFrames = setup.maxFrames
        fileURL = setup.fileURL
        startedAt = Date()
        ctx = setup.ctx
        pendingFallbackInfo = setup.fallbackInfo
        // Belt-and-suspenders disconnect signal — fires when AVFoundation
        // surfaces a device-list change for the bound UID before AUHAL's
        // render proc reports an error. 250 ms debounce inside the
        // closure rides out Bluetooth flicker. AUHAL render-error fires
        // are de-duped by `CallbackContext.tryMarkDisconnected` so a
        // notification fired here while the render path is also winding
        // down only emits one event total.
        installDeviceListObserver(boundUID: setup.fallbackInfo.savedUID, context: setup.ctx)
        // Backfill the cached display name when the live device resolved
        // cleanly but no name was cached (existing user upgrading from a
        // build that pre-dates the cache). Defensive — only writes when
        // we actually have a non-fallback resolution AND the cache is
        // empty, so we never overwrite a user-edited name.
        if !setup.fallbackInfo.didFallback,
           !setup.fallbackInfo.savedUID.isEmpty,
           savedNameCache.isEmpty,
           !setup.fallbackInfo.actualDeviceName.isEmpty {
            UserDefaults.standard.set(setup.fallbackInfo.actualDeviceName, forKey: "jot.inputDeviceLastName")
        }
    }

    public func stop() async throws -> AudioRecording {
        guard let activeUnit = unit,
              let context = ctx,
              let url = fileURL,
              let startedAt
        else {
            throw AudioCaptureError.notRunning
        }

        context.markStopping()
        // Snapshot buffered samples *before* AUHAL teardown — per
        // `docs/plans/mic-disconnect-handling.md` the AUHAL stop calls
        // can hang on a removed device (rtaudio issue #194). If teardown
        // wedges, we still hand back whatever the writer queue accepted.
        let captured = writerQueue.sync {
            let snapshot = context.queueState.samples
            context.queueState.audioFile = nil
            context.queueState.converter = nil
            context.queueState.samples.removeAll(keepingCapacity: false)
            return snapshot
        }

        let outcome = AudioCapture.boundedAUHALTeardown(
            unit: activeUnit,
            timeout: 2,
            log: log,
            site: "stop"
        )

        // On timeout the render trampoline may still touch
        // `renderABL` / `ctx` if dispose eventually returns. Skip the
        // dealloc + ctx clear in that case to avoid a use-after-free —
        // see `docs/plans/mic-disconnect-handling.md`.
        finishDisconnectStream()
        if outcome == .completed {
            freeRenderBuffers()
            resetState()
        } else {
            resetStateAfterLeak()
        }

        let publisher = amplitudePublisher
        Task { @MainActor [weak publisher] in
            publisher?.reset()
        }

        return AudioRecording(
            samples: captured,
            fileURL: url,
            duration: TimeInterval(captured.count) / AudioFormat.sampleRate,
            createdAt: startedAt
        )
    }

    public func cancel() {
        if unit == nil, attempt != nil {
            cancelRequestedDuringSetup = true
            if let url = attempt?.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
            finishDisconnectStream()
            let publisher = amplitudePublisher
            Task { @MainActor [weak publisher] in
                publisher?.reset()
            }
            return
        }

        ctx?.markStopping()
        if let context = ctx {
            // Drain the writer queue first so any buffered work releases
            // its references before the unit is disposed (mirrors `stop()`).
            writerQueue.sync {
                context.queueState.audioFile = nil
                context.queueState.converter = nil
                context.queueState.samples.removeAll(keepingCapacity: false)
            }
        }

        var outcome: TeardownOutcome = .completed
        if let activeUnit = unit {
            outcome = AudioCapture.boundedAUHALTeardown(
                unit: activeUnit,
                timeout: 2,
                log: log,
                site: "cancel"
            )
        }

        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }

        finishDisconnectStream()
        if outcome == .completed {
            freeRenderBuffers()
            resetState()
        } else {
            resetStateAfterLeak()
        }

        let publisher = amplitudePublisher
        Task { @MainActor [weak publisher] in
            publisher?.reset()
        }
    }

    private func disposeCommittedSetup(_ setup: AUHALSetup, deleteFile: Bool) {
        setup.ctx.markStopping()
        writerQueue.sync {
            setup.ctx.queueState.audioFile = nil
            setup.ctx.queueState.converter = nil
            setup.ctx.queueState.samples.removeAll(keepingCapacity: false)
        }
        let outcome = AudioCapture.boundedAUHALTeardown(
            unit: setup.unit,
            timeout: 2,
            log: log,
            site: "disposeCommittedSetup"
        )
        if outcome == .completed {
            setup.renderABL.deallocate()
            setup.renderBytes.deallocate()
        } else {
            // Teardown timed out — retain ctx + buffers so the audio
            // thread's unretained refcon stays valid until it actually
            // returns. Bounded leak per `docs/plans/mic-disconnect-handling.md`.
            leakedContexts.append(setup.ctx)
            leakedRenderABLs.append(setup.renderABL)
            leakedRenderBytes.append(setup.renderBytes)
        }
        if deleteFile {
            try? FileManager.default.removeItem(at: setup.fileURL)
        }
    }

    private func finishDisconnectStream() {
        disconnectContinuation?.finish()
        disconnectContinuation = nil
        disconnectStream = nil
        if let observer = deviceListObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceListObserver = nil
        }
    }

    /// Subscribe to `AVCaptureDevice.wasDisconnectedNotification` so a
    /// device-removal that AUHAL hasn't surfaced yet still tears down
    /// gracefully. Skips when the bound device is system-default
    /// (`boundUID` is empty) since system-default fallback is handled
    /// transparently.
    private func installDeviceListObserver(boundUID: String, context: CallbackContext) {
        guard !boundUID.isEmpty else { return }
        // The notification posts on the main queue per AVFoundation;
        // capture the disconnect queue so the firing closure stays off
        // the main actor.
        let disconnectQueue = self.disconnectQueue
        // Note: stored as a NSObjectProtocol — fine to remove from any
        // thread in `finishDisconnectStream`.
        let log = self.log
        deviceListObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: nil
        ) { notification in
            log.info("[disconnect-diag] AVCapture wasDisconnected fired: device.uniqueID=\((notification.object as? AVCaptureDevice)?.uniqueID ?? "<nil>", privacy: .public) device.localizedName=\((notification.object as? AVCaptureDevice)?.localizedName ?? "<nil>", privacy: .public) activeBoundUID=\(boundUID, privacy: .public)")
            guard let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == boundUID
            else {
                if let mismatched = notification.object as? AVCaptureDevice {
                    log.info("[disconnect-diag] gate-uid: MISS (notification=\(mismatched.uniqueID, privacy: .public) bound=\(boundUID, privacy: .public))")
                }
                return
            }
            log.info("[disconnect-diag] gate-uid: MATCH (\(boundUID, privacy: .public))")
            // 250 ms debounce — Bluetooth (AirPods especially) emits a
            // brief disconnect/reconnect during route changes that
            // shouldn't kill an in-progress recording. Re-check the
            // device list at the end of the debounce window; if the
            // device is back, drop the event.
            log.info("[disconnect-diag] gate-wait: starting 250ms debounce for \(boundUID, privacy: .public)")
            disconnectQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                let stillMissing = AudioCapture.audioDeviceID(forUID: boundUID) == nil
                guard stillMissing else {
                    log.info("[disconnect-diag] gate-recheck: REAPPEARED — suppressing")
                    return
                }
                log.info("[disconnect-diag] gate-recheck: STILL_MISSING — proceeding to tryMarkDisconnected()")
                let casResult = context.tryMarkDisconnected()
                log.info("[disconnect-diag] gate-cas: tryMarkDisconnected() called, result=\(casResult, privacy: .public)")
                guard casResult else { return }
                let continuation = context.disconnectContinuation
                continuation.yield(.deviceListDropped)
                continuation.finish()
                Task {
                    await ErrorLog.shared.error(
                        component: "AudioCapture",
                        message: "AVCaptureDeviceWasDisconnected for bound UID — emitting disconnect",
                        context: ["uid": boundUID]
                    )
                }
            }
        }
    }

    /// Wraps the three AUHAL teardown calls in a 2-second bounded
    /// background dispatch. On timeout the unit pointer is intentionally
    /// leaked — better than wedging the @MainActor caller.
    /// `nonisolated` so it can be reused from `SetupAttempt.dispose()`
    /// (an `@unchecked Sendable` class outside the actor) and the
    /// wizard-meter teardown.
    /// Result of a bounded AUHAL teardown attempt. Callers use this to
    /// decide whether it is safe to free the heap-boxed `CallbackContext`
    /// and `AudioBufferList` (the AUHAL real-time callback may still be
    /// firing if the dispose call hung).
    enum TeardownOutcome: Sendable {
        case completed
        /// 2-second timeout fired before teardown returned. The caller
        /// MUST NOT deallocate render buffers or release the
        /// `CallbackContext` — the audio thread may still touch them
        /// when (or if) `AudioComponentInstanceDispose` eventually
        /// returns. We accept the leak; the alternative is a use-after-
        /// free crash. Per `docs/plans/mic-disconnect-handling.md`.
        case timedOut
    }

    @discardableResult
    static func boundedAUHALTeardown(
        unit: AudioUnit,
        timeout: TimeInterval,
        log: Logger,
        site: String
    ) -> TeardownOutcome {
        // `AudioUnit` is `UnsafeMutablePointer<ComponentInstanceRecord>`,
        // which is not `Sendable`. Wrap in an `@unchecked Sendable` box so
        // the dispatched closure can carry it across the queue. Safe
        // because the unit is only touched on this background thread for
        // the duration of teardown.
        struct UnitBox: @unchecked Sendable { let unit: AudioUnit }
        let box = UnitBox(unit: unit)
        let lock = OSAllocatedUnfairLock(initialState: false)
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            AudioOutputUnitStop(box.unit)
            AudioUnitUninitialize(box.unit)
            AudioComponentInstanceDispose(box.unit)
            let isLate = lock.withLock { resumed in
                let was = resumed
                resumed = true
                return was
            }
            if !isLate {
                semaphore.signal()
            }
        }
        let timeoutResult = semaphore.wait(timeout: .now() + timeout)
        if timeoutResult == .timedOut {
            let alreadyResumed = lock.withLock { resumed -> Bool in
                let was = resumed
                resumed = true
                return was
            }
            if !alreadyResumed {
                log.error("AUHAL teardown timed out at \(site, privacy: .public) — leaking AudioUnit + buffers")
                Task {
                    await ErrorLog.shared.error(
                        component: "AudioCapture",
                        message: "AUHAL teardown timed out — leaking unit and buffers",
                        context: ["site": site]
                    )
                }
                return .timedOut
            }
            // Else: background block beat us to the resume — clean exit.
            return .completed
        }
        return .completed
    }

    private func freeRenderBuffers() {
        renderABL?.deallocate()
        renderBytes?.deallocate()
    }

    private func resetState() {
        unit = nil
        renderABL = nil
        renderBytes = nil
        maxFrames = 0
        fileURL = nil
        startedAt = nil
        ctx = nil
    }

    /// Same as `resetState` but intentionally LEAKS `renderABL`,
    /// `renderBytes`, and `ctx` — the bounded AUHAL teardown timed out
    /// so the audio thread may still touch them when (or if) dispose
    /// eventually returns. See `docs/plans/mic-disconnect-handling.md`.
    /// Next `start()` allocates a fresh `CallbackContext` and buffers,
    /// so the leak is bounded to one-per-hung-disconnect.
    private func resetStateAfterLeak() {
        // Stash the live references in the leak arrays so the heap
        // allocations stay alive even though the per-session slots get
        // cleared. The audio thread holds raw `Unmanaged` pointers; if
        // we just `ctx = nil` here the strong ref drops to 0 and the
        // CallbackContext deallocates under the still-running callback.
        if let liveCtx = ctx {
            leakedContexts.append(liveCtx)
        }
        if let liveABL = renderABL {
            leakedRenderABLs.append(liveABL)
        }
        if let liveBytes = renderBytes {
            leakedRenderBytes.append(liveBytes)
        }
        unit = nil
        renderABL = nil
        renderBytes = nil
        maxFrames = 0
        fileURL = nil
        startedAt = nil
        ctx = nil
    }

    // MARK: - AUHAL setup

    private struct AUHALSetup: @unchecked Sendable {
        let unit: AudioUnit
        let renderABL: UnsafeMutablePointer<AudioBufferList>
        let renderBytes: UnsafeMutableRawPointer
        let maxFrames: UInt32
        let fileURL: URL
        let ctx: CallbackContext
        let fallbackInfo: AudioCaptureFallbackInfo
    }

    private static func configureAUHALWithTimeout(
        attempt: SetupAttempt,
        selectedUID: String,
        savedNameCache: String,
        url: URL,
        amplitudePublisher: AmplitudePublisher?,
        writerQueue: DispatchQueue,
        disconnectQueue: DispatchQueue,
        disconnectContinuation: AsyncStream<AudioCaptureDisconnectEvent>.Continuation,
        outstandingLock: OSAllocatedUnfairLock<Int>,
        log: Logger,
        seconds: Double
    ) async throws -> AUHALSetup {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AUHALSetup, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                func fail(_ error: Error) {
                    attempt.dispose(writerQueue: writerQueue)
                    if attempt.tryAbandon() {
                        cont.resume(throwing: error)
                    }
                }

                // 1. Find the AUHAL component.
                var desc = AudioComponentDescription(
                    componentType: kAudioUnitType_Output,
                    componentSubType: kAudioUnitSubType_HALOutput,
                    componentManufacturer: kAudioUnitManufacturer_Apple,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                guard let comp = AudioComponentFindNext(nil, &desc) else {
                    log.error("AudioComponentFindNext returned nil for HALOutput")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(OSStatus(paramErr))))
                    return
                }
                var newUnit: AudioUnit?
                var status = AudioComponentInstanceNew(comp, &newUnit)
                guard status == noErr, let u = newUnit else {
                    log.error("AudioComponentInstanceNew failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }
                attempt.unit = u

                // 2. Enable input scope (bus 1), disable output scope (bus 0).
                var on: UInt32 = 1
                var off: UInt32 = 0
                status = AudioUnitSetProperty(
                    u,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &on,
                    UInt32(MemoryLayout<UInt32>.size)
                )
                if status != noErr {
                    log.error("EnableIO(input) failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }
                status = AudioUnitSetProperty(
                    u,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &off,
                    UInt32(MemoryLayout<UInt32>.size)
                )
                if status != noErr {
                    log.error("EnableIO(output, off) failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }

                // 3. Resolve and bind the device.
                //
                // Note: the picker stores `AVCaptureDevice.uniqueID` while
                // CoreAudio resolves against `kAudioDevicePropertyDeviceUID`.
                // These are documented as separate APIs but produce identical
                // strings in practice on macOS — this is the standard
                // AVFoundation⇄CoreAudio bridge pattern. Verified
                // empirically by the picker test under commit `92605be`.
                var devID: AudioDeviceID = 0
                var didFallback = false
                if !selectedUID.isEmpty {
                    if let resolved = Self.audioDeviceID(forUID: selectedUID) {
                        devID = resolved
                        log.info("Resolved UID \(selectedUID, privacy: .public) → AudioDeviceID=\(devID, privacy: .public)")
                    } else {
                        log.warning("Could not resolve UID \(selectedUID, privacy: .public); falling back to system default")
                        devID = Self.systemDefaultInputDevice() ?? 0
                        didFallback = true
                    }
                } else {
                    devID = Self.systemDefaultInputDevice() ?? 0
                    log.info("Using system default input AudioDeviceID=\(devID, privacy: .public)")
                }
                guard devID != 0 else {
                    log.error("No input device available")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(kAudioHardwareBadDeviceError)))
                    return
                }

                status = AudioUnitSetProperty(
                    u,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    if !selectedUID.isEmpty,
                       let fallbackID = Self.systemDefaultInputDevice(),
                       fallbackID != 0,
                       fallbackID != devID {
                        log.warning("CurrentDevice set failed for selected UID; falling back to system default: \(status, privacy: .public)")
                        devID = fallbackID
                        didFallback = true
                        status = AudioUnitSetProperty(
                            u,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &devID,
                            UInt32(MemoryLayout<AudioDeviceID>.size)
                        )
                    }
                    if status != noErr {
                        log.error("CurrentDevice set failed: \(status, privacy: .public)")
                        fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                        return
                    }
                }
                let actualDeviceName = Self.stringProperty(devID, selector: kAudioObjectPropertyName) ?? ""

                // 4. Read the device's native ASBD on input scope, element 1.
                var deviceASBD = AudioStreamBasicDescription()
                var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                status = AudioUnitGetProperty(
                    u,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1,
                    &deviceASBD,
                    &asbdSize
                )
                if status != noErr {
                    log.error("Get device StreamFormat failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }
                log.info("Device input ASBD: sr=\(deviceASBD.mSampleRate, privacy: .public) ch=\(deviceASBD.mChannelsPerFrame, privacy: .public) fmtFlags=\(deviceASBD.mFormatFlags, privacy: .public)")

                guard deviceASBD.mSampleRate > 0 else {
                    log.error("Device reports sample rate 0 — aborting")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(kAudio_ParamError)))
                    return
                }

                // 5. Set client ASBD on **output** scope, element 1 — mono
                // Float32 packed at the device's sample rate. AUHAL down-mixes.
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
                status = AudioUnitSetProperty(
                    u,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &clientASBD,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                )
                if status != noErr {
                    log.error("Set client StreamFormat failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }

                let formatString = "device sr=\(Int(deviceASBD.mSampleRate)) ch=\(deviceASBD.mChannelsPerFrame) → client sr=\(Int(clientASBD.mSampleRate)) ch=1 Float32"
                log.info("Client render ASBD: \(formatString, privacy: .public)")

                // 6. Determine the maximum frames-per-slice the unit will
                // deliver. Match variant 4's 4096 floor.
                var slice: UInt32 = 4096
                var sliceSize = UInt32(MemoryLayout<UInt32>.size)
                let sliceStatus = AudioUnitGetProperty(
                    u,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &slice,
                    &sliceSize
                )
                let chosenMaxFrames: UInt32 = (sliceStatus == noErr && slice > 0)
                    ? max(slice, 4096)
                    : 4096
                log.info("MaximumFramesPerSlice=\(chosenMaxFrames, privacy: .public)")

                // 7. Build the AVAudioFormat used to wrap rendered chunks.
                guard let avFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: clientASBD.mSampleRate,
                    channels: 1,
                    interleaved: false
                ) else {
                    log.error("Could not build AVAudioFormat for client ASBD")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(kAudio_ParamError)))
                    return
                }

                // 8. Pre-allocate the render AudioBufferList and its backing
                // bytes. Mono Float32 packed -> 4 bytes per frame.
                let bytesPerFrame: UInt32 = 4
                let bufferCapacity = Int(chosenMaxFrames * bytesPerFrame)
                let bytes = UnsafeMutableRawPointer.allocate(
                    byteCount: bufferCapacity,
                    alignment: MemoryLayout<Float>.alignment
                )
                let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                abl.pointee.mNumberBuffers = 1
                abl.pointee.mBuffers.mNumberChannels = 1
                abl.pointee.mBuffers.mDataByteSize = UInt32(bufferCapacity)
                abl.pointee.mBuffers.mData = bytes
                attempt.renderABL = abl
                attempt.renderBytes = bytes

                // 9. Open the WAV file and converter at Jot's target format.
                let audioFile: AVAudioFile
                do {
                    audioFile = try AVAudioFile(
                        forWriting: url,
                        settings: AudioFormat.target.settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                } catch {
                    log.error("AVAudioFile init failed: \(error.localizedDescription, privacy: .public)")
                    fail(AudioCaptureError.fileCreate(error))
                    return
                }

                guard let converter = AVAudioConverter(from: avFmt, to: AudioFormat.target) else {
                    log.error("AVAudioConverter unavailable")
                    fail(AudioCaptureError.converterUnavailable)
                    return
                }

                // 10. Build the callback context. Heap-allocated so its
                // address is stable for the refcon's lifetime.
                let queueState = QueueState()
                queueState.audioFile = audioFile
                queueState.converter = converter
                let context = CallbackContext(
                    unit: u,
                    renderABL: abl,
                    renderBytes: bytes,
                    maxFrames: chosenMaxFrames,
                    avFormat: avFmt,
                    amplitudePublisher: amplitudePublisher,
                    writerQueue: writerQueue,
                    disconnectQueue: disconnectQueue,
                    disconnectContinuation: disconnectContinuation,
                    outstandingLock: outstandingLock,
                    outstandingLimit: Self.outstandingLimit,
                    log: log,
                    queueState: queueState
                )
                attempt.ctx = context

                // 11. Wire the input callback. Pass the box as the refcon.
                var cb = AURenderCallbackStruct(
                    inputProc: audioCaptureAUHALInputCallback,
                    inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
                )
                status = AudioUnitSetProperty(
                    u,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &cb,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                )
                if status != noErr {
                    log.error("SetInputCallback failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }

                // 12. Initialize and start.
                status = AudioUnitInitialize(u)
                if status != noErr {
                    log.error("AudioUnitInitialize failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }

                status = AudioOutputUnitStart(u)
                if status != noErr {
                    log.error("AudioOutputUnitStart failed: \(status, privacy: .public)")
                    fail(AudioCaptureError.engineStart(Self.osStatusError(status)))
                    return
                }

                let fallbackInfo = AudioCaptureFallbackInfo(
                    savedUID: selectedUID,
                    savedName: savedNameCache,
                    actualDeviceName: actualDeviceName,
                    didFallback: didFallback
                )
                let setup = AUHALSetup(
                    unit: u,
                    renderABL: abl,
                    renderBytes: bytes,
                    maxFrames: chosenMaxFrames,
                    fileURL: url,
                    ctx: context,
                    fallbackInfo: fallbackInfo
                )

                if attempt.tryCommit() {
                    cont.resume(returning: setup)
                } else {
                    attempt.dispose(writerQueue: writerQueue)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if attempt.tryAbandon() {
                    cont.resume(throwing: AudioCaptureError.engineStartTimeout)
                }
            }
        }
    }

    // MARK: - CoreAudio helpers

    private static func osStatusError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &dataSize,
                raw.baseAddress!
            )
        }
        guard status == noErr else { return nil }

        for id in ids {
            if let candidate = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
               candidate == uid {
                return id
            }
        }
        return nil
    }

    private static func systemDefaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &devID
        )
        guard status == noErr, devID != 0 else { return nil }
        return devID
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
            }
        }
        guard status == noErr, let s = cfStr else { return nil }
        return s as String
    }
}

// MARK: - Callback state

/// Touched only by blocks dispatched onto `writerQueue`.
fileprivate final class QueueState: @unchecked Sendable {
    var samples: [Float] = []
    var audioFile: AVAudioFile?
    var converter: AVAudioConverter?
}

/// Holds everything the C input callback needs without crossing actor
/// isolation. Mutable audio state lives in `queueState` and is touched only
/// on `writerQueue`.
fileprivate final class CallbackContext: @unchecked Sendable {
    let unit: AudioUnit
    let renderABL: UnsafeMutablePointer<AudioBufferList>
    let renderBytes: UnsafeMutableRawPointer
    let maxFrames: UInt32
    let avFormat: AVAudioFormat
    weak var amplitudePublisher: AmplitudePublisher?
    let writerQueue: DispatchQueue
    /// Serial queue the real-time render trampoline `dispatch_async`es to
    /// when it needs to do non-realtime work (yielding the disconnect
    /// event). Keeps the audio thread out of Swift concurrency.
    let disconnectQueue: DispatchQueue
    /// Continuation for the disconnect AsyncStream the actor handed out.
    /// Invoked once via `disconnectQueue` on the first render error;
    /// subsequent errors are de-duped via `disconnectFlag`. Marked as
    /// non-actor-isolated so it can be touched from the real-time
    /// callback under the lock.
    let disconnectContinuation: AsyncStream<AudioCaptureDisconnectEvent>.Continuation
    let outstandingLock: OSAllocatedUnfairLock<Int>
    let outstandingLimit: Int
    let log: Logger
    let queueState: QueueState
    private let stopLock = OSAllocatedUnfairLock(initialState: false)
    private let droppedLock = OSAllocatedUnfairLock(initialState: 0)
    /// One-shot flag — only the first AudioUnitRender error per session
    /// fires a disconnect event. Compare-and-set under `disconnectLock`.
    private let disconnectLock = OSAllocatedUnfairLock(initialState: false)

    init(
        unit: AudioUnit,
        renderABL: UnsafeMutablePointer<AudioBufferList>,
        renderBytes: UnsafeMutableRawPointer,
        maxFrames: UInt32,
        avFormat: AVAudioFormat,
        amplitudePublisher: AmplitudePublisher?,
        writerQueue: DispatchQueue,
        disconnectQueue: DispatchQueue,
        disconnectContinuation: AsyncStream<AudioCaptureDisconnectEvent>.Continuation,
        outstandingLock: OSAllocatedUnfairLock<Int>,
        outstandingLimit: Int,
        log: Logger,
        queueState: QueueState
    ) {
        self.unit = unit
        self.renderABL = renderABL
        self.renderBytes = renderBytes
        self.maxFrames = maxFrames
        self.avFormat = avFormat
        self.amplitudePublisher = amplitudePublisher
        self.writerQueue = writerQueue
        self.disconnectQueue = disconnectQueue
        self.disconnectContinuation = disconnectContinuation
        self.outstandingLock = outstandingLock
        self.outstandingLimit = outstandingLimit
        self.log = log
        self.queueState = queueState
    }

    func markStopping() {
        stopLock.withLock { $0 = true }
    }

    func isStoppingNow() -> Bool {
        stopLock.withLock { $0 }
    }

    func incrementDropped() -> Int {
        droppedLock.withLock {
            $0 += 1
            return $0
        }
    }

    /// Compare-and-set the disconnect flag. Returns true on the first call
    /// per session — subsequent calls return false so the caller fires
    /// the event exactly once.
    func tryMarkDisconnected() -> Bool {
        disconnectLock.withLock { fired in
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

/// Coordinates setup timeout with late-success cleanup. Timeout abandons the
/// attempt but never disposes live CoreAudio memory; the background setup
/// queue owns disposal once setup eventually exits.
fileprivate final class SetupAttempt: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ())
    var unit: AudioUnit?
    var ctx: CallbackContext?
    var renderABL: UnsafeMutablePointer<AudioBufferList>?
    var renderBytes: UnsafeMutableRawPointer?
    var fileURL: URL?
    private var isCommitted = false
    private var isAbandoned = false

    func tryCommit() -> Bool {
        lock.withLock {
            guard !isCommitted, !isAbandoned else { return false }
            isCommitted = true
            return true
        }
    }

    func tryAbandon() -> Bool {
        lock.withLock {
            guard !isCommitted, !isAbandoned else { return false }
            isAbandoned = true
            return true
        }
    }

    func dispose(writerQueue: DispatchQueue) {
        ctx?.markStopping()
        // Drain the writer queue first so a hung unit teardown can't
        // strand outstanding writes — mirrors `AudioCapture.cancel()`.
        // Hold a local strong ref to the context so a timeout-leak path
        // can stash it in the global registry before the local goes
        // out of scope.
        let retainedCtx = ctx
        if let context = ctx {
            writerQueue.sync {
                context.queueState.audioFile = nil
                context.queueState.converter = nil
                context.queueState.samples.removeAll(keepingCapacity: false)
            }
            ctx = nil
        } else {
            writerQueue.sync {}
        }
        var outcome: AudioCapture.TeardownOutcome = .completed
        if let activeUnit = unit {
            // 2-second bounded teardown — see `docs/plans/mic-disconnect-handling.md`.
            outcome = AudioCapture.boundedAUHALTeardown(
                unit: activeUnit,
                timeout: 2,
                log: Logger(subsystem: "com.jot.Jot", category: "AudioCapture.SetupAttempt"),
                site: "SetupAttempt.dispose"
            )
            unit = nil
        }
        if outcome == .completed {
            renderABL?.deallocate()
            renderABL = nil
            renderBytes?.deallocate()
            renderBytes = nil
        } else {
            // Teardown timed out — retain ctx + buffers in the
            // process-wide leak registry so a late-resuming dispose
            // doesn't dereference a freed refcon. Bounded to one entry
            // per coreaudiod hang.
            if let retainedCtx { AudioCaptureLeakRegistry.shared.retain(ctx: retainedCtx) }
            if let abl = renderABL { AudioCaptureLeakRegistry.shared.retain(renderABL: abl) }
            if let bytes = renderBytes { AudioCaptureLeakRegistry.shared.retain(renderBytes: bytes) }
            renderABL = nil
            renderBytes = nil
        }
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
    }
}

/// Process-wide retainer for `CallbackContext`s and render buffers we
/// could not safely deallocate from `SetupAttempt.dispose` (no actor
/// instance to stash them on). Keeps the heap allocations alive past a
/// hung AUHAL teardown so the audio thread's unretained refcon doesn't
/// dangle. Bounded to one entry per coreaudiod hang in practice.
fileprivate final class AudioCaptureLeakRegistry: @unchecked Sendable {
    static let shared = AudioCaptureLeakRegistry()
    private let lock = NSLock()
    private var contexts: [CallbackContext] = []
    private var renderABLs: [UnsafeMutablePointer<AudioBufferList>] = []
    private var renderBytes: [UnsafeMutableRawPointer] = []

    func retain(ctx: CallbackContext) {
        lock.lock(); defer { lock.unlock() }
        contexts.append(ctx)
    }
    func retain(renderABL: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        renderABLs.append(renderABL)
    }
    func retain(renderBytes: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        self.renderBytes.append(renderBytes)
    }
}

// MARK: - C input callback trampoline

/// AUHAL input callback. Called on a CoreAudio real-time thread.
///
/// Per Apple TN2091, an input callback's job is to call `AudioUnitRender`
/// to pull freshly-captured samples into the callback-supplied buffer list.
private func audioCaptureAUHALInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<CallbackContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard !ctx.isStoppingNow() else { return noErr }

    // Reset the available capacity hint each call: AudioUnitRender wants
    // mDataByteSize set to how much room our buffer can hold.
    let capacity = ctx.maxFrames * 4   // mono Float32 = 4 B/frame
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
        // Treat any non-zero render status as a possible mid-recording
        // disconnect (USB pull, AirPods drop, sleep/wake). Lock-free
        // compare-and-set guarantees a single fire per session; the
        // expensive work — yielding the event onto the AsyncStream and
        // logging — happens off the real-time thread via
        // `disconnectQueue` per `docs/plans/mic-disconnect-handling.md`
        // §3 (no allocation / Swift concurrency / logging on the audio
        // thread).
        if ctx.tryMarkDisconnected() {
            let continuation = ctx.disconnectContinuation
            let status = renderStatus
            let log = ctx.log
            ctx.disconnectQueue.async {
                log.info("[disconnect-diag] auhal-render: status=\(status, privacy: .public)")
                log.error("AudioUnitRender failed: \(status, privacy: .public)")
                continuation.yield(.renderError(status))
                continuation.finish()
                Task {
                    await ErrorLog.shared.error(
                        component: "AudioCapture",
                        message: "AudioUnitRender failed — emitting disconnect",
                        context: ["status": "\(status)"]
                    )
                }
            }
        }
        return renderStatus
    }

    // Wrap the rendered samples in a fresh AVAudioPCMBuffer so the meter,
    // converter, and writer operate on the same Float32 mono shape.
    guard inNumberFrames > 0,
          let bytes = ctx.renderABL.pointee.mBuffers.mData,
          let scratch = AVAudioPCMBuffer(pcmFormat: ctx.avFormat, frameCapacity: inNumberFrames)
    else {
        return noErr
    }
    scratch.frameLength = inNumberFrames
    if let dst = scratch.floatChannelData?[0] {
        let byteCount = Int(inNumberFrames) * MemoryLayout<Float>.size
        memcpy(dst, bytes, byteCount)
    }

    let level = AmplitudePublisher.rms(from: scratch)
    Task { @MainActor [weak publisher = ctx.amplitudePublisher] in
        publisher?.append(rms: level)
    }

    // Backpressure check.
    let outstanding = ctx.outstandingLock.withLock { $0 }
    if outstanding > ctx.outstandingLimit {
        let dropped = ctx.incrementDropped()
        if dropped == 1 || dropped.isMultiple(of: 64) {
            ctx.log.error("Dropping AUHAL buffer; writerQueue outstanding=\(outstanding, privacy: .public) dropped=\(dropped, privacy: .public)")
        }
        return noErr
    }

    ctx.outstandingLock.withLock { $0 += 1 }
    let lockRef = ctx.outstandingLock
    let queueState = ctx.queueState
    let log = ctx.log
    let sourceFormat = ctx.avFormat
    ctx.writerQueue.async {
        defer { lockRef.withLock { $0 -= 1 } }
        convertAndWrite(
            scratch,
            sourceFormat: sourceFormat,
            queueState: queueState,
            log: log
        )
    }

    return noErr
}

private func convertAndWrite(
    _ buffer: AVAudioPCMBuffer,
    sourceFormat: AVAudioFormat,
    queueState: QueueState,
    log: Logger
) {
    guard let audioFile = queueState.audioFile,
          let converter = queueState.converter
    else {
        return
    }

    let ratio = AudioFormat.sampleRate / sourceFormat.sampleRate
    let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
    guard
        let outBuffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormat.target,
            frameCapacity: estimatedFrames
        )
    else {
        log.error("Failed to allocate AUHAL conversion output buffer")
        return
    }

    var suppliedOnce = false
    var error: NSError?
    let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
        if suppliedOnce {
            inputStatus.pointee = .noDataNow
            return nil
        }
        suppliedOnce = true
        inputStatus.pointee = .haveData
        return buffer
    }

    switch status {
    case .error:
        if let error {
            log.error("AUHAL AudioConverter error: \(error.localizedDescription)")
        } else {
            log.error("AUHAL AudioConverter error")
        }
        return
    case .inputRanDry, .haveData, .endOfStream:
        break
    @unknown default:
        break
    }

    let frameCount = Int(outBuffer.frameLength)
    guard frameCount > 0, let channelData = outBuffer.floatChannelData else { return }

    let channelPtr = channelData[0]
    queueState.samples.append(contentsOf: UnsafeBufferPointer(start: channelPtr, count: frameCount))

    do {
        try audioFile.write(from: outBuffer)
    } catch {
        log.error("AUHAL AVAudioFile write failed: \(error.localizedDescription)")
    }
}
