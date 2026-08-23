import Foundation
import Security

protocol OpenRouterCredentialStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

struct KeychainOpenRouterCredentialStore: OpenRouterCredentialStoring {
    private let service = "studio.moonbay.ThirdHand.openrouter"
    private let account = "api-key"

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw OpenRouterCredentialError(status: status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            throw OpenRouterCredentialError.invalidStoredValue
        }
        return key
    }

    func saveAPIKey(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenRouterCredentialError.emptyKey
        }
        let value = Data(normalized.utf8)
        let update: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            update as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OpenRouterCredentialError(status: updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = value
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenRouterCredentialError(status: addStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterCredentialError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}

enum OpenRouterCredentialError: LocalizedError, Sendable {
    case emptyKey
    case invalidStoredValue
    case keychain(OSStatus)

    init(status: OSStatus) {
        self = .keychain(status)
    }

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            "Введите API-ключ OpenRouter."
        case .invalidStoredValue:
            "Сохранённый ключ OpenRouter повреждён. Удалите его и сохраните заново."
        case let .keychain(status):
            "Keychain не выполнил операцию (код \(status))."
        }
    }
}
