import Foundation

enum Capability: String, CaseIterable, Sendable {
    case microphone
    case inputMonitoring
    case accessibilityPostEvents
    case accessibilityFullAX
}
