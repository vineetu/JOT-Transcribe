import CoreAudio
import Foundation
import os.log

/// Silences other applications' audio for the duration of a recording, and
/// restores it exactly afterwards.
///
/// ## Why mute rather than pause
///
/// macOS offers no public way to pause another app. `MediaRemote` — the private
/// framework that could — has been entitlement-gated since **macOS 15.4**, and
/// only Apple-signed processes may set playback state. Simulating the
/// Play/Pause media key is the other option, but with MediaRemote closed there
/// is no way to ask what is playing, so the key press is a blind toggle that
/// *starts* music when nothing was playing, and only reaches whichever app owns
/// the key rather than "all audio".
///
/// Muting the default output device is public API, deterministic, and exactly
/// reversible. It is also what the category does: Wispr Flow's "Mute music
/// while dictating" mutes the default output device and falls back to
/// volume-to-zero on devices without hardware mute, and MacWhisper ships the
/// same toggle.
///
/// ## Only when something else is actually playing
///
/// CoreAudio process objects (macOS 14.2+, so unconditional on Jot's macOS 15
/// floor) let us ask which processes have running output and skip our own pid —
/// so Jot's own chimes never trigger a mute, and a silent machine is left alone.
/// Wispr requires 14.2 for exactly this reason; below it they cannot tell their
/// audio from yours.
///
/// Known and accepted: `kAudioProcessPropertyIsRunningOutput` reports active
/// output IO, not non-zero samples. An app holding a paused-but-open stream
/// (Spotify, a muted Zoom) reads as playing, so we will sometimes mute when
/// nothing is audible. Harmless here — restoring is exact — but it is the
/// reason this design is preferable to the media-key one, where the same false
/// positive would have produced a spurious *unpause*.
@MainActor
final class AudioTakeover {

    static let shared = AudioTakeover()

    private static let log = Logger(subsystem: "com.jot.Jot", category: "audio-takeover")

    /// Crash safety. If Jot dies mid-recording the device stays muted with
    /// nothing on screen to explain it, so the intent to restore is persisted
    /// and replayed at launch. Cleared on every clean restore.
    private static let pendingKey = "jot.audioTakeover.pendingRestore"

    private enum Applied {
        case muted(AudioDeviceID)
        case volumeZeroed(AudioDeviceID, previous: Float32)
    }

    private var applied: Applied?

    private init() {}

    // MARK: - Entry points

    /// Silence other audio, if any is playing. Idempotent.
    func begin() {
        guard applied == nil else { return }
        guard let device = Self.defaultOutputDevice() else { return }
        guard Self.otherProcessIsPlaying() else {
            Self.log.debug("takeover — nothing else playing, leaving audio alone")
            return
        }

        // Hardware mute first: it is a single boolean, so restoring cannot get
        // the level wrong. Not every device implements it (many USB and
        // aggregate interfaces do not), hence the volume fallback.
        if Self.setMute(device, true) {
            applied = .muted(device)
            persistPending(["mode": "mute", "device": String(device)])
            Self.log.info("takeover — muted device \(device, privacy: .public)")
            return
        }
        if let previous = Self.volume(device), Self.setVolume(device, 0) {
            applied = .volumeZeroed(device, previous: previous)
            persistPending(["mode": "volume", "device": String(device), "previous": String(previous)])
            Self.log.info("takeover — volume 0 on \(device, privacy: .public), was \(previous, privacy: .public)")
            return
        }
        Self.log.info("takeover — device exposes neither mute nor volume; no-op")
    }

    /// Restore. Safe to call when nothing was applied, and safe to call twice —
    /// every exit path (stop, cancel, mid-recording device disconnect) calls it,
    /// deliberately. A stuck mute is this feature's worst failure: Wispr ships
    /// with exactly that bug on headphone disconnect.
    func end() {
        defer { applied = nil; UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
        switch applied {
        case .muted(let device):
            _ = Self.setMute(device, false)
        case .volumeZeroed(let device, let previous):
            _ = Self.setVolume(device, previous)
        case nil:
            return
        }
        Self.log.info("takeover — restored")
    }

    /// Replay an interrupted restore at launch.
    func restorePendingAfterCrash() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: String],
              let deviceRaw = saved["device"], let device = AudioDeviceID(deviceRaw)
        else { return }
        switch saved["mode"] {
        case "mute":
            _ = Self.setMute(device, false)
        case "volume":
            if let raw = saved["previous"], let previous = Float32(raw) {
                _ = Self.setVolume(device, previous)
            }
        default:
            break
        }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        Self.log.info("takeover — restored a mute left behind by an unclean exit")
    }

    private func persistPending(_ info: [String: String]) {
        UserDefaults.standard.set(info, forKey: Self.pendingKey)
    }
}

// MARK: - CoreAudio

private extension AudioTakeover {

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    /// True when some process OTHER than Jot has running output.
    static func otherProcessIsPlaying() -> Bool {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects
        ) == noErr else { return false }

        let mine = getpid()
        for object in objects {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid != mine else { continue }

            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddr = address(kAudioProcessPropertyIsRunningOutput)
            if AudioObjectGetPropertyData(
                object, &runningAddr, 0, nil, &runningSize, &running
            ) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    static func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    static func volume(_ device: AudioDeviceID) -> Float32? {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    static func setVolume(_ device: AudioDeviceID, _ value: Float32) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        ) == noErr
    }
}
