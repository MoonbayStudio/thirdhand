import Foundation
import Security

protocol AIAPICredentialStoring: Sendable {
    func loadAPIKey(for provider: AIAPIProvider) throws -> String?
    func saveAPIKey(_ apiKey: String, for provider: AIAPIProvider) throws
    func deleteAPIKey(for provider: AIAPIProvider) throws
}
struct KeychainAIAPICredentialStore: AIAPICredentialStoring {
    func loadAPIKey(for provider: AIAPIProvider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AIAPICredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            throw AIAPICredentialError.invalidStoredValue(provider)
        }
        return key
    }

    func saveAPIKey(_ apiKey: String, for provider: AIAPIProvider) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AIAPICredentialError.emptyKey(provider)
        }

        let update = [kSecValueData as String: Data(normalized.utf8)]
        let query = baseQuery(for: provider)
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIAPICredentialError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = Data(normalized.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIAPICredentialError.keychain(addStatus)
        }
    }

    func deleteAPIKey(for provider: AIAPIProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIAPICredentialError.keychain(status)
        }
    }

    private func baseQuery(for provider: AIAPIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: "api-key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }

    private func service(for provider: AIAPIProvider) -> String {
        if provider == .openRouter {
            // Keep the existing service name so current OpenRouter keys migrate without a copy.
            return "studio.moonbay.ThirdHand.openrouter"
        }
        return "studio.moonbay.ThirdHand.api.\(provider.rawValue)"
    }
}

enum AIAPICredentialError: LocalizedError, Sendable {
    case emptyKey(AIAPIProvider)
    case invalidStoredValue(AIAPIProvider)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .emptyKey(provider):
            "Введите API-ключ \(provider.displayName)."
        case let .invalidStoredValue(provider):
            "Сохранённый ключ \(provider.displayName) повреждён. Удалите его и сохраните заново."
        case let .keychain(status):
            "Keychain не выполнил операцию (код \(status))."
        }
    }
}
