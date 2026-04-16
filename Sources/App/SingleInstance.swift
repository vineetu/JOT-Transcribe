import AppKit
import Foundation

final class SingleInstance {
    private static let pingName = Notification.Name("com.jot.Jot.singleInstance.ping")
    private static let pongName = Notification.Name("com.jot.Jot.singleInstance.pong")

    private let center = DistributedNotificationCenter.default()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var focusHandler: (() -> Void)?

    func anotherInstanceIsRunning(timeout: TimeInterval = 0.2) -> Bool {
        var sawPong = false
        let observer = center.addObserver(
            forName: Self.pongName,
            object: nil,
            queue: .main
        ) { note in
            if let sender = note.userInfo?["pid"] as? Int, sender != Int(self.ownPID) {
                sawPong = true
            }
        }
        defer { center.removeObserver(observer) }

        center.postNotificationName(
            Self.pingName,
            object: nil,
            userInfo: ["pid": Int(ownPID)],
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !sawPong {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return sawPong
    }

    func activateExistingInstance() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.jot.Jot")
        for app in running where app.processIdentifier != ownPID {
            app.activate(options: [.activateAllWindows])
            break
        }
    }

    func installObserver(focus: @escaping () -> Void) {
        self.focusHandler = focus
        center.addObserver(
            forName: Self.pingName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let sender = note.userInfo?["pid"] as? Int, sender == Int(self.ownPID) {
                return
            }
            self.center.postNotificationName(
                Self.pongName,
                object: nil,
                userInfo: ["pid": Int(self.ownPID)],
                deliverImmediately: true
            )
            self.focusHandler?()
        }
    }
}
