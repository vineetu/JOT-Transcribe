import Carbon.HIToolbox
import Foundation

/// Finds the physical key that types a given letter in the user's CURRENT
/// keyboard layout, so a synthetic ⌘V really is ⌘V.
///
/// Why: a `CGEvent` carries a virtual key code — a key POSITION, not a
/// letter. macOS then reads that position through the active layout. On
/// Dvorak the QWERTY "V" position (`kVK_ANSI_V`) types K, so a hard-coded
/// `kVK_ANSI_V` arrives as ⌘K: search in Slack and Codex, Edit Link in
/// TextEdit. The same happens to ⌘C (arrives as ⌘J), which breaks Rewrite's
/// selection capture.
///
/// The lookup is made with ⌘ held, because that is the layer shortcuts are
/// read from and some layouts change it: "Dvorak – QWERTY ⌘" types Dvorak
/// but reads ⌘ shortcuts by QWERTY position, and non-Latin layouts (Russian,
/// Greek, Hebrew) map their ⌘ layer to QWERTY. Asking the ⌘ layer gets all of
/// those right without special cases.
///
/// Returns nil when the layout has no key for the letter or exposes no layout
/// data (some input methods); callers fall back to the QWERTY position, which
/// is what those layouts expect for shortcuts anyway.
@MainActor
enum KeyboardLayoutKeyCode {
    static func keyCode(typing character: Character, preferred: CGKeyCode) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layout = layoutData(source)
        else { return nil }
        return keyCode(typing: character, preferred: preferred, layout: layout)
    }

    /// Same lookup against an explicit layout. Split out so every layout can
    /// be checked without switching the user's input source.
    static func keyCode(typing character: Character, preferred: CGKeyCode, layout: Data) -> CGKeyCode? {
        let target = String(character).lowercased()
        // Today's key first: on QWERTY (and anything whose ⌘ layer is QWERTY)
        // nothing changes, not even which of two matching keys is used.
        if translate(preferred, layout: layout) == target { return preferred }
        for code in CGKeyCode(0)..<128 where translate(code, layout: layout) == target {
            return code
        }
        return nil
    }

    static func layoutData(_ source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func translate(_ keyCode: CGKeyCode, layout: Data) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDown),
                UInt32((cmdKey >> 8) & 0xFF),
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).lowercased()
        }
    }
}
