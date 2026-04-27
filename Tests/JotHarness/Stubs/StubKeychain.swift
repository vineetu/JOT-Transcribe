import Foundation
import os
@testable import Jot

/// Harness conformer for `KeychainStoring`. In-memory `[String: String]`
/// store, with a `throwsOnLoad` mode for the F2 "Keychain throws"
/// failure-path test.
///
/// **`final class` not `actor`.** `KeychainStoring`'s methods are
/// synchronous (`throws`, not `async throws`) — actor-isolated methods
/// are implicitly async, so an actor can't conform. Mutable state lives
/// behind an `OSAllocatedUnfairLock` for `Sendable` correctness.
///
/// **No reach into the real Keychain.** The live `LiveKeychain` wraps
/// `SecItemAdd/CopyMatching/Delete`; the stub never touches the
/// Security framework.
final class StubKeychain: KeychainStoring, @unchecked Sendable {
    private struct State {
        var store: [String: String]
        let throwsOnLoad: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    init(seed: KeychainSeed = .empty) {
        switch seed {
        case .empty:
            self.state = OSAllocatedUnfairLock(initialState: State(store: [:], throwsOnLoad: false))
        case .populated(let entries):
            var dict: [String: String] = [:]
            for entry in entries { dict[entry.account] = entry.value }
            self.state = OSAllocatedUnfairLock(initialState: State(store: dict, throwsOnLoad: false))
        case .throwsOnLoad:
            self.state = OSAllocatedUnfairLock(initialState: State(store: [:], throwsOnLoad: true))
        }
    }

    // MARK: - KeychainStoring

    func load(account: String) throws -> String? {
        try state.withLock { current in
            if current.throwsOnLoad {
                throw KeychainError.osStatus(errSecAuthFailed)
            }
            return current.store[account]
        }
    }

    func save(_ value: String, account: String) throws {
        state.withLock { current -> Void in
            current.store[account] = value
        }
    }

    func delete(account: String) throws {
        state.withLock { current -> Void in
            current.store.removeValue(forKey: account)
        }
    }
}
