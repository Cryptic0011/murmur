import Foundation
import Security

struct KeychainStore {
    let service: String
    let account: String

    static let groqAPIKey = KeychainStore(service: "com.murmur.app", account: "groq-api-key")
    static let cerebrasAPIKey = KeychainStore(service: "com.murmur.app", account: "cerebras-api-key")
    static let customAPIKey = KeychainStore(service: "com.murmur.app", account: "custom-api-key")

    enum Error: Swift.Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case undecodableData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
                return "\(message) (\(status))"
            case .undecodableData:
                return "The saved Keychain item isn't valid text."
            }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves `value` without surrounding whitespace (pasted keys often carry a
    /// trailing newline). An empty value deletes the item rather than storing "".
    func set(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete() }
        let attrs: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Never needed before login, never migrated to another Mac. The file-based
            // login keychain ignores this today; ACLs gate access there.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = baseQuery.merging(attrs) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw Error.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw Error.unexpectedStatus(status)
        }
    }

    /// The stored value, trimmed; nil when nothing (or only whitespace) is stored.
    func get() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw Error.unexpectedStatus(status) }
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw Error.undecodableData
        }
        // Keys saved by older builds weren't trimmed.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }
}
