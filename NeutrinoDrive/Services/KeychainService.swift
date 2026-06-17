import Foundation
import Security

enum KeychainService {

    // MARK: - Save

    /// Save or update a string value for the given key.
    /// Returns true on success.
    @discardableResult
    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return true
        }

        if addStatus == errSecDuplicateItem {
            let searchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            let updateAttributes: [CFString: Any] = [
                kSecValueData: data
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
            return updateStatus == errSecSuccess
        }

        return false
    }

    // MARK: - Load

    /// Load a string value for the given key.
    /// Returns nil if not found.
    static func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Delete

    /// Delete the item for the given key.
    /// Returns true if the item was found and deleted.
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
