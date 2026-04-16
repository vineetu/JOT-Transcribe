import SwiftUI
import Combine

@MainActor
final class FirstRunState: ObservableObject {
    static let shared = FirstRunState()

    @AppStorage("jot.setupComplete") var setupComplete: Bool = false

    var isFirstLaunch: Bool { !setupComplete }

    func markComplete() {
        setupComplete = true
    }
}
