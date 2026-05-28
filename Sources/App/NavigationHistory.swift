import SwiftUI

@MainActor
@Observable
final class NavigationHistory {
    private(set) var back: [AppSidebarSelection] = []
    private(set) var forward: [AppSidebarSelection] = []
    var isNavigatingHistory = false

    @ObservationIgnored
    private var selection: Binding<AppSidebarSelection>?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func bind(selection: Binding<AppSidebarSelection>) {
        self.selection = selection
    }

    func pushCurrent(_ old: AppSidebarSelection) {
        guard !isNavigatingHistory else { return }
        back.append(old)
        forward.removeAll()
    }

    func goBack() {
        guard let selection else { return }
        guard let target = back.popLast() else { return }

        isNavigatingHistory = true
        forward.append(selection.wrappedValue)
        selection.wrappedValue = target

        DispatchQueue.main.async { [weak self] in
            self?.isNavigatingHistory = false
        }
    }

    func goForward() {
        guard let selection else { return }
        guard let target = forward.popLast() else { return }

        isNavigatingHistory = true
        back.append(selection.wrappedValue)
        selection.wrappedValue = target

        DispatchQueue.main.async { [weak self] in
            self?.isNavigatingHistory = false
        }
    }

    /// Drops back/forward entries that no longer satisfy `predicate`.
    /// Preserves the relative order of survivors.
    ///
    /// v1.13: invoked by `JotAppWindow` when the user flips Advanced
    /// off so the back-button doesn't take them to a pane (Ask Jot,
    /// Vocabulary) that the sidebar no longer surfaces.
    func filter(_ predicate: (AppSidebarSelection) -> Bool) {
        back.removeAll { !predicate($0) }
        forward.removeAll { !predicate($0) }
    }
}

@MainActor
private let defaultNavigationHistory = NavigationHistory()

private struct NavigationHistoryKey: @preconcurrency EnvironmentKey {
    @MainActor
    static let defaultValue: NavigationHistory = defaultNavigationHistory
}

extension EnvironmentValues {
    var navigationHistory: NavigationHistory {
        get { self[NavigationHistoryKey.self] }
        set { self[NavigationHistoryKey.self] = newValue }
    }
}
