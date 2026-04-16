import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation
import IOKit.hid
import os.log

@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    @Published private(set) var statuses: [Capability: PermissionStatus] = [:]

    private let log = Logger(subsystem: "com.jot.Jot", category: "Permissions")

    // lastKnown tracks what we observed the previous time we polled. We use
    // it to distinguish "was never denied → granted now" from "was denied,
    // the kernel now reports granted, but this running process still holds
    // the stale decision and must relaunch to pick it up."
    private var lastKnown: [Capability: PermissionStatus] = [:]

    private var activationObserver: NSObjectProtocol?

    private init() {
        for capability in Capability.allCases {
            statuses[capability] = .notDetermined
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop back to the main actor — the observer closure is not
            // isolated even though we routed it through the main queue.
            Task { @MainActor [weak self] in
                self?.refreshAll()
            }
        }

        refreshAll()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Polling

    func refreshAll() {
        for capability in Capability.allCases {
            let raw = rawStatus(for: capability)
            statuses[capability] = applyRelaunchRule(capability: capability, raw: raw)
            lastKnown[capability] = raw
        }
    }

    // Why: Input Monitoring and Accessibility decisions are cached in the
    // running process by the kernel — a denied → granted flip in System
    // Settings is not observable without a relaunch. Microphone, in
    // contrast, is re-checked by CoreAudio each request, so a flip there
    // IS observable in-process. This helper encodes that divergence.
    private func applyRelaunchRule(capability: Capability, raw: PermissionStatus) -> PermissionStatus {
        switch capability {
        case .microphone:
            return raw
        case .inputMonitoring, .accessibilityPostEvents, .accessibilityFullAX:
            if lastKnown[capability] == .denied && raw == .granted {
                return .requiresRelaunch
            }
            return raw
        }
    }

    private func rawStatus(for capability: Capability) -> PermissionStatus {
        switch capability {
        case .microphone:
            return microphoneStatus()
        case .inputMonitoring:
            return hidAccessStatus(for: kIOHIDRequestTypeListenEvent)
        case .accessibilityPostEvents, .accessibilityFullAX:
            return accessibilityStatus()
        }
    }

    private func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .authorized: return .granted
        @unknown default: return .notDetermined
        }
    }

    private func hidAccessStatus(for requestType: IOHIDRequestType) -> PermissionStatus {
        let access = IOHIDCheckAccess(requestType)
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        case kIOHIDAccessTypeUnknown: return .notDetermined
        default: return .notDetermined
        }
    }

    private func accessibilityStatus() -> PermissionStatus {
        // Pass nil options so we never trigger the system prompt as a side
        // effect of polling. Prompting is the caller's job via `request(_:)`
        // (which routes to System Settings for AX).
        return AXIsProcessTrusted() ? .granted : .denied
    }

    // MARK: - Requesting

    func request(_ capability: Capability) async {
        switch capability {
        case .microphone:
            await requestMicrophone()
        case .inputMonitoring, .accessibilityPostEvents, .accessibilityFullAX:
            SystemSettingsLinks.open(for: capability)
        }
        refreshAll()
    }

    private func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        log.info("Microphone request result: \(granted, privacy: .public)")
    }
}
