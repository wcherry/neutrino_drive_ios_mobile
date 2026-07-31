import Foundation
import Security

enum KeychainService {

    // MARK: - Shared access group

    /// The Keychain access group to write new items into, or `nil` to use the app's default
    /// group (the pre-share-extension behaviour).
    ///
    /// Resolved once, from a real entitlement probe rather than from a build flag:
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` unless the running
    /// bundle actually carries the App Group entitlement. The app and the share extension both
    /// declare it; the unit-test bundle does not. So tests keep using the default group and
    /// behave exactly as they did before this file changed, while the app and extension share
    /// one group and can therefore read each other's items.
    ///
    /// `resolvedAccessGroup` is a `var` and not a `let` because a Keychain call may still be
    /// rejected with `errSecMissingEntitlement` (App Group present but `keychain-access-groups`
    /// missing or mismatched). In that case it is cleared permanently and every subsequent call
    /// falls back to the default group — losing extension visibility, but never losing the
    /// user's keys.
    private static var resolvedAccessGroup: String? = {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStorage.appGroupIdentifier
        ) != nil else { return nil }
        return SharedStorage.keychainAccessGroup
    }()

    /// Exposed for diagnostics and tests. `nil` means "default group".
    static var accessGroup: String? { resolvedAccessGroup }

    private static func disableSharedAccessGroup() {
        resolvedAccessGroup = nil
    }

    /// `errSecMissingEntitlement` / `errSecNoAccessForItem` mean the access group is not usable
    /// by this binary. Anything else is a real failure and must not silently widen access.
    private static func isEntitlementFailure(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNoAccessForItem
    }

    // MARK: - Save

    /// Save or update a string value for the given key.
    /// Returns true on success.
    ///
    /// When a shared access group is in effect, the item is first deleted from *every*
    /// accessible group and then re-added into the shared one. Without that, an item already
    /// living in the default group would coexist with a new shared-group item under the same
    /// account, and `load` — which searches all groups — could return either. Delete-then-add
    /// guarantees exactly one item, always in the group the extension can see.
    @discardableResult
    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        guard let group = resolvedAccessGroup else {
            return saveInDefaultGroup(data, forKey: key)
        }

        // Clear any copy in any accessible group, then add into the shared group.
        var deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        deleteQuery[kSecAttrAccessGroup] = group
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: group,
            kSecValueData: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return true }

        if isEntitlementFailure(status) {
            disableSharedAccessGroup()
            return saveInDefaultGroup(data, forKey: key)
        }
        return false
    }

    /// The original (pre-access-group) save path, preserved verbatim.
    private static func saveInDefaultGroup(_ data: Data, forKey key: String) -> Bool {
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
    ///
    /// Deliberately queried **without** `kSecAttrAccessGroup`: an unqualified search spans
    /// every group in the caller's `keychain-access-groups` entitlement, so this finds items
    /// whether they were written before the shared group existed or after. That is also why
    /// no read-path migration is required.
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

    /// Delete the item for the given key, from every accessible access group.
    /// Returns true if at least one item was found and deleted.
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        // An unqualified delete does not always reach items in a non-default group, so make a
        // second explicit pass when one is in effect.
        var deletedFromGroup = false
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup] = group
            deletedFromGroup = SecItemDelete(query as CFDictionary) == errSecSuccess
        }

        return status == errSecSuccess || deletedFromGroup
    }

    // MARK: - Migration

    /// Relocates the app's known Keychain items into the shared access group, so a user who
    /// imported their key before the share extension shipped does not have to re-import it for
    /// sharing to work.
    ///
    /// Idempotent and safe to call on every launch: `save` already performs delete-then-add
    /// into the shared group, so re-running this on already-migrated items is a no-op in
    /// effect. A no-op entirely when no shared group is in effect.
    ///
    /// Values that fail to reload after the round trip are **not** deleted — `save` only
    /// removes the old copy once it holds the value in memory, and a failed add leaves the
    /// caller able to retry on next launch.
    static func migrateToSharedAccessGroupIfNeeded() {
        guard resolvedAccessGroup != nil else { return }
        let keys = [
            SharedStorage.Keys.accessToken,
            SharedStorage.Keys.refreshToken,
            SharedStorage.Keys.publicKey,
            SharedStorage.Keys.privateKey,
            SharedStorage.Keys.keyVersion,
        ]
        for key in keys {
            guard let value = load(forKey: key) else { continue }
            save(value, forKey: key)
        }
    }
}
