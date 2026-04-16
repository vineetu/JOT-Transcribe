import Foundation

/// Published by `DeliveryService` each time a transcript is handed off.
///
/// The overlay + library subscribe to render toasts / confirmations. The
/// event carries the text so consumers don't have to read it back off the
/// pasteboard (which may have been restored by the time they look).
enum DeliveryEvent: Sendable {
    case pasted(text: String)
    case clipboardOnly(text: String, reason: String)
    case failed(error: String)
}
