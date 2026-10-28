import Foundation

extension Notification.Name {
    /// Posted by APIKeyCache.reload() after an API key was saved, replaced or removed.
    static let apiKeysDidChange = Notification.Name("APIKeysDidChange")
}

/// Keychain API keys, read on first use and kept in memory, so provider rebuilds don't
/// hit the Keychain (a legacy-keychain ACL prompt blocks the calling thread) and keys of
/// providers that aren't in use are never read. Save paths call reload().
@MainActor
final class APIKeyCache {
    private let read: (KeychainStore) throws -> String?
    private var cache: [String: String] = [:]
    /// Called once per failed read (until the next reload) with the Keychain account.
    var onReadFailure: ((String) -> Void)?

    init(read: @escaping (KeychainStore) throws -> String? = { try $0.get() }) {
        self.read = read
    }

    var groq: String { value(.groqAPIKey) }
    var cerebras: String { value(.cerebrasAPIKey) }
    var custom: String { value(.customAPIKey) }

    /// The key `option` sends; "" for keyless providers.
    func key(for option: CleanupProviderOption) -> String {
        switch option {
        case .groqAPI: return groq
        case .cerebrasAPI: return cerebras
        case .customAPI: return custom
        case .builtIn, .ollamaLocal, .appleFoundationModels: return ""
        }
    }

    // ponytail: the first read of each key still runs on the main thread. A missing key
    // isn't cached (looking up an absent item is cheap and never prompts), so a key saved
    // by a path that doesn't call reload() is still picked up on the next rebuild.
    func value(_ store: KeychainStore) -> String {
        if let cached = cache[store.account] { return cached }
        do {
            guard let key = try read(store) else { return "" }
            cache[store.account] = key
            return key
        } catch {
            // Cached as "" so a denied ACL prompt isn't shown again on every rebuild.
            NSLog("[Murmur] Keychain read failed for %@: %@", store.account, String(describing: error))
            cache[store.account] = ""
            onReadFailure?(store.account)
            return ""
        }
    }

    /// Drops every cached key and posts .apiKeysDidChange; call after saving or deleting one.
    func reload() {
        cache.removeAll()
        NotificationCenter.default.post(name: .apiKeysDidChange, object: self)
    }
}
