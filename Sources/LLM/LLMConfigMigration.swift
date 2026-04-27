import Foundation

/// One-shot migration from the v1.5.0 flat `{jot.llm.baseURL, jot.llm.model,
/// jot.llm.apiKey}` schema to the v1.5.1 per-provider buckets. Runs exactly
/// once per machine (guarded by `jot.migration.perProviderV1`).
///
/// Does NOT clobber per-provider values the user has already entered in the
/// new build — only fills in EMPTY per-provider buckets from the old flat
/// values. Old flat keys are LEFT IN PLACE as a safety net; a future cleanup
/// release can drop them.
enum LLMConfigMigration {
    private static let flagKey = "jot.migration.perProviderV1"
    private static let trimFlagKey = "jot.migration.trimURLsV1"

    /// Phase 4 patch round 3: `keychain` seam threaded so the legacy
    /// API-key migration routes through `KeychainStoring` (production:
    /// `LiveKeychain`; harness: `StubKeychain`) instead of the static
    /// `KeychainHelper`. Closes the Phase 3 #29 Scope-A deferral.
    ///
    /// Default-provider regression fix: `defaults` seam threaded so the
    /// migration writes per-provider buckets and migration flags to the
    /// suite-scoped `UserDefaults` carried by `SystemServices.userDefaults`
    /// when called from the harness. Production passes `.standard`.
    static func runIfNeeded(keychain: any KeychainStoring, defaults: UserDefaults = .standard) {
        trimStoredValuesIfNeeded(keychain: keychain, defaults: defaults)
        runPerProviderBucketsIfNeeded(keychain: keychain, defaults: defaults)
    }

    /// Strip leading/trailing whitespace + newlines from any already-stored
    /// per-provider baseURLs/models and keychain API keys. Users who pasted
    /// URLs with trailing linebreaks (common Chrome paste artifact) end up
    /// with `https://.../v1\n` which `URL(string:)` happily accepts but the
    /// `\n` gets percent-encoded to `%0A` on the request path. Runs once.
    private static func trimStoredValuesIfNeeded(keychain: any KeychainStoring, defaults: UserDefaults) {
        guard !defaults.bool(forKey: trimFlagKey) else { return }
        defer { defaults.set(true, forKey: trimFlagKey) }

        for provider in [LLMProvider.openai, .anthropic, .gemini, .ollama] {
            for suffix in ["baseURL", "model"] {
                let key = "jot.llm.\(provider.rawValue).\(suffix)"
                if let raw = defaults.string(forKey: key) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != raw {
                        if trimmed.isEmpty {
                            defaults.removeObject(forKey: key)
                        } else {
                            defaults.set(trimmed, forKey: key)
                        }
                    }
                }
            }
            let apiKey = "jot.llm.\(provider.rawValue).apiKey"
            if let raw = (try? keychain.load(account: apiKey)) ?? nil {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != raw {
                    if trimmed.isEmpty {
                        try? keychain.delete(account: apiKey)
                    } else {
                        try? keychain.save(trimmed, account: apiKey)
                    }
                }
            }
        }
    }

    private static func runPerProviderBucketsIfNeeded(keychain: any KeychainStoring, defaults: UserDefaults) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let providerRaw = defaults.string(forKey: "jot.llm.provider") ?? ""
        guard let provider = LLMProvider(rawValue: providerRaw) else { return }

        let oldBaseURL = defaults.string(forKey: "jot.llm.baseURL") ?? ""
        let oldModel = defaults.string(forKey: "jot.llm.model") ?? ""
        let oldAPIKey: String = (try? keychain.load(account: "jot.llm.apiKey")) ?? nil ?? ""

        let baseURLKey = "jot.llm.\(provider.rawValue).baseURL"
        let modelKey = "jot.llm.\(provider.rawValue).model"
        let apiKeychainKey = "jot.llm.\(provider.rawValue).apiKey"

        let currentBucketBaseURL = defaults.string(forKey: baseURLKey) ?? ""
        let currentBucketModel = defaults.string(forKey: modelKey) ?? ""
        let currentBucketAPIKey: String = (try? keychain.load(account: apiKeychainKey)) ?? nil ?? ""

        if currentBucketBaseURL.isEmpty && !oldBaseURL.isEmpty {
            defaults.set(oldBaseURL, forKey: baseURLKey)
        }
        if currentBucketModel.isEmpty && !oldModel.isEmpty {
            defaults.set(oldModel, forKey: modelKey)
        }
        if currentBucketAPIKey.isEmpty && !oldAPIKey.isEmpty {
            try? keychain.save(oldAPIKey, account: apiKeychainKey)
        }
    }
}
