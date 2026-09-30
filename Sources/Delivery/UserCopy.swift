import AppKit

/// A user-initiated Copy — a row's copy glyph, the detail toolbar's Copy, the
/// summary's copy button. ONE implementation of "put this text on the
/// clipboard": through the live `Pasteboarding` seam (so harness flows verify
/// it via a stub), or straight to the general pasteboard during the
/// cold-launch window before `AppServices.live` exists. A failed write is
/// logged under `component`.
@MainActor
enum UserCopy {
    @discardableResult
    static func write(_ text: String, component: String) -> Bool {
        let pasteboard: any Pasteboarding = AppServices.live?.pasteboard ?? LivePasteboard()
        guard pasteboard.write(text) else {
            Task { await ErrorLog.shared.warn(
                component: component,
                message: "copy failed — pasteboard write returned false") }
            return false
        }
        return true
    }
}
