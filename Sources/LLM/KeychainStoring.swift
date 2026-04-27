import Foundation
import Security

/// OS-boundary seam for the macOS Keychain. The live conformer is
/// `LiveKeychain` (wraps `SecItemAdd/CopyMatching/Delete` against the
/// generic-password class); harness conformers in `Tests/JotHarness/` keep
/// an in-memory `[String: String]` so flow tests can verify API-key
/// persistence without touching the developer's real Keychain.
///
/// The seam is **String-flavored** (returns `String?`, accepts `String`).
/// Today's `KeychainHelper` is `Data`-flavored and silently swallows
/// errors; that helper stays in place for now — Phase 3 migrates each
/// call site to the throwing protocol per the cleanup-roadmap (B1
/// keychain item).
///
/// All three operations throw. `load(account:)` returns `nil` (rather
/// than throwing) on `errSecItemNotFound` — the conventional "no value
/// stored" outcome that callers want to treat as a normal case, not as
/// an error. Any other `OSStatus` non-success or UTF-8 decoding failure
/// is wrapped as `KeychainError`.
protocol KeychainStoring: Sendable {
    func load(account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Errors thrown by `KeychainStoring` conformers. Phase 3 will route
/// these through `JotError` once the typed-error work lands; for Phase 0
/// the seam just exposes them as `Error`-conforming cases.
enum KeychainError: Error {
    /// Wrapped `OSStatus` returned by `SecItemAdd`, `SecItemCopyMatching`,
    /// or `SecItemDelete` when not `errSecSuccess` (and not the special
    /// `errSecItemNotFound` case that `load` treats as a normal nil).
    case osStatus(OSStatus)
    /// `SecItemCopyMatching` returned data that wasn't valid UTF-8 — the
    /// stored value is corrupt or written by a non-Jot writer.
    case decodingFailed
}

/// Live conformer — talks to the macOS Keychain via the Security
/// framework. Mirrors `KeychainHelper`'s data-flavored operations but
/// throws on `OSStatus` errors instead of swallowing them, and accepts /
/// returns `String` instead of `Data` (UTF-8 round-trip handled here so
/// every call site doesn't redo it).
struct LiveKeychain: KeychainStoring {
    /// `kSecAttrService` value for every Jot keychain entry. Matches
    /// `KeychainHelper.service` so existing items written by the
    /// non-throws helper are visible to this seam (and vice-versa during
    /// the Phase 3 migration window).
    private let service: String

    init(service: String = "com.jot.Jot") {
        self.service = service
    }

    func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = result as? Data else { throw KeychainError.decodingFailed }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    func save(_ value: String, account: String) throws {
        // Match `KeychainHelper.save`'s delete-then-add semantics so a
        // re-save replaces the existing item rather than colliding.
        try? delete(account: account)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // `errSecItemNotFound` on delete is a no-op success — calling
        // delete on something that isn't there isn't an error.
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }
}
