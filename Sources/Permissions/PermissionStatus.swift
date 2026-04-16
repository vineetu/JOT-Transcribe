import Foundation

enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
    case requiresRelaunch
}
