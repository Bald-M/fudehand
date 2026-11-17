import Foundation
import Security

/// 模型 API key 只保存在当前用户的钥匙串中，按模型提供方区分。
enum Keychain {
    private static let service = "ui-atlas.agent"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法保存到钥匙串（\(status)）" }
}
