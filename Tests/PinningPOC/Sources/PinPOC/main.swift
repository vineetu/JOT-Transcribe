import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Enumeration helpers

struct InputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum POCError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case noInputDevices

    var description: String {
        switch self {
        case let .coreAudio(status, what):
            return "CoreAudio error \(status) in \(what)"
        case .noInputDevices:
            return "no input-capable CoreAudio devices found"
        }
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw POCError.coreAudio(status, what) }
}

func getStringProperty(
    device: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
    var cfStr: CFString? = nil
    try withUnsafeMutablePointer(to: &cfStr) { ptr in
        try check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr),
            "AudioObjectGetPropertyData(\(selector))"
        )
    }
    return cfStr.map { $0 as String } ?? ""
}

func deviceHasInputStreams(_ device: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
    guard status == noErr else { return false }
    return size >= UInt32(MemoryLayout<AudioStreamID>.size)
}

func defaultInputDeviceID() throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioObjectID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ),
        "defaultInputDevice"
    )
    return id
}

func enumerateInputDevices() throws -> [InputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ),
        "devices size"
    )

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    try ids.withUnsafeMutableBufferPointer { buf in
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buf.baseAddress!
            ),
            "devices data"
        )
    }

    return ids.compactMap { id -> InputDevice? in
        guard deviceHasInputStreams(id) else { return nil }
        let uid = (try? getStringProperty(device: id, selector: kAudioDevicePropertyDeviceUID)) ?? ""
        let name = (try? getStringProperty(device: id, selector: kAudioObjectPropertyName)) ?? ""
        return InputDevice(id: id, uid: uid, name: name)
    }
}

// MARK: - Path A capture

@discardableResult
func runPathA(on device: InputDevice, pinned: Bool, durationSeconds: TimeInterval) throws -> (frames: UInt64, sampleRate: Double) {
    let engine = AVAudioEngine()

    if pinned {
        // High-level API that internally stops + reinitializes the AUHAL when
        // the device changes. Avoids the stale outputFormat(forBus:) cache that
        // tripped the earlier pinning attempt.
        try engine.inputNode.auAudioUnit.setDeviceID(AUAudioObjectID(device.id))
        engine.reset()
    }

    let input = engine.inputNode
    // Read AFTER the pin — format must reflect the pinned device, not the
    // previously-cached (pre-pin) value.
    let format = input.outputFormat(forBus: 0)
    fputs("  pinned format: \(format)\n", stderr)

    var frameCount: UInt64 = 0
    var sumSquares: Double = 0
    var peakAbs: Float = 0
    let lock = NSLock()

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        let n = Int(buffer.frameLength)
        var localSq: Double = 0
        var localPeak: Float = 0
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<n {
                let s = ch[i]
                localSq += Double(s) * Double(s)
                let a = abs(s)
                if a > localPeak { localPeak = a }
            }
        }
        lock.lock()
        frameCount &+= UInt64(n)
        sumSquares += localSq
        if localPeak > peakAbs { peakAbs = localPeak }
        lock.unlock()
    }

    engine.prepare()
    try engine.start()

    Thread.sleep(forTimeInterval: durationSeconds)

    input.removeTap(onBus: 0)
    engine.stop()

    lock.lock()
    let total = frameCount
    let rms = total > 0 ? sqrt(sumSquares / Double(total)) : 0
    let peak = peakAbs
    lock.unlock()
    fputs("  rms: \(rms) peak: \(peak)\n", stderr)
    return (total, format.sampleRate)
}

// MARK: - Entry point

func main() -> Int32 {
    let duration: TimeInterval = 3.0

    let devices: [InputDevice]
    do {
        devices = try enumerateInputDevices()
    } catch {
        fputs("error enumerating devices: \(error)\n", stderr)
        return 2
    }

    guard !devices.isEmpty else {
        fputs("no input devices\n", stderr)
        return 2
    }

    fputs("input devices (\(devices.count)):\n", stderr)
    for d in devices {
        fputs("  - id=\(d.id) uid=\(d.uid) name=\(d.name)\n", stderr)
    }

    let defaultID = (try? defaultInputDeviceID()) ?? 0
    fputs("default input id: \(defaultID)\n", stderr)

    // Prefer the first non-default input device to actually exercise pinning.
    // Fall back to the single device if only one exists.
    let target: InputDevice
    if let nonDefault = devices.first(where: { $0.id != defaultID }) {
        target = nonDefault
    } else {
        target = devices[0]
        fputs("only one input device visible — pinning to it anyway\n", stderr)
    }

    let pinned = target.id != defaultID || devices.count == 1
    fputs("\ntarget: uid=\(target.uid) name=\(target.name) id=\(target.id) pinned=\(pinned ? "y" : "n")\n", stderr)
    fputs("running Path A for \(duration)s…\n", stderr)

    let result: (frames: UInt64, sampleRate: Double)
    do {
        result = try runPathA(on: target, pinned: true, durationSeconds: duration)
    } catch {
        fputs("Path A threw: \(error)\n", stderr)
        return 3
    }

    print("device_uid=\(target.uid)")
    print("device_name=\(target.name)")
    print("pinned=\(pinned ? "y" : "n")")
    print("total_frames=\(result.frames)")
    print("sample_rate=\(result.sampleRate)")

    return result.frames > 0 ? 0 : 1
}

exit(main())
