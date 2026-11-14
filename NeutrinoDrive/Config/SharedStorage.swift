import Foundation
import NeutrinoCore

// MARK: - SharedStorage

/// Storage identifiers shared between the host app and the share extension.
///
/// Most of what used to live here is now `NeutrinoCore` — `NeutrinoAppConfig` owns the App Group,
/// the Keychain access group and the `nd.*` key names, and `NeutrinoStorage` owns the dual-suite
/// server-host read that lets the extension see the host the login screen configured.
///
/// What remains is the Drive-only half plus the aliases every existing call site uses. The type is
/// kept rather than deleted for the reason it was created: the extension needs these identifiers
/// without compiling `DriveService`, the view models and the rest of the object graph, and every
/// name below still resolves without any of that.
enum SharedStorage {

    // MARK: - Group identifiers

    /// App Group shared by the app and the share extension. Used for the server-host override and
    /// the extension's staging directory.
    static var appGroupIdentifier: String {
        NeutrinoApp.current.appGroupIdentifier ?? "group.com.neutrino.drive"
    }

    /// Keychain access group, so the extension can read the access token and the encryption-key
    /// material the app imported.
    static var keychainAccessGroup: String {
        NeutrinoApp.current.keychainAccessGroup ?? "com.neutrino.drive.shared"
    }

    // MARK: - Keys

    /// The `nd.*` account strings. Derived from `NeutrinoAppConfig` rather than spelled out, so
    /// there is one definition of the namespace and the package's tests pin it.
    enum Keys {
        static var accessToken:  String { NeutrinoApp.current.accessTokenKey }
        static var refreshToken: String { NeutrinoApp.current.refreshTokenKey }
        static var serverHost:   String { NeutrinoApp.current.serverHostKey }

        static var publicKey:  String { NeutrinoApp.current.publicKeyKey }
        static var privateKey: String { NeutrinoApp.current.privateKeyKey }
        static var keyVersion: String { NeutrinoApp.current.keyVersionKey }

        /// The account's *retired* identity keys, as one JSON array — see `KeyArchive`. In the
        /// shared group with the active key: the share extension uploads, and an upload seals to
        /// the active key, but a download it triggers can need an older one.
        static var archivedKeys: String { NeutrinoApp.current.archivedKeysKey }

        /// The symmetric key that encrypts this account's search-index snapshot (base64url).
        ///
        /// Drive-only, and the reason this type still exists: search is not a Neutrino-wide
        /// concept, so the key stays here rather than in the shared config. Device-local — not read
        /// by the share extension, so it lives in the default Keychain group rather than the shared
        /// one. See `SearchIndexSyncService`.
        static let searchIndexKey = "nd.search.index_key"
    }

    static var defaultHost: String { NeutrinoApp.current.defaultHost }

    // MARK: - Defaults

    /// `UserDefaults` visible to both the app and the extension.
    static var defaults: UserDefaults { NeutrinoStorage.defaults }

    /// Server host override, reading the App Group suite first and falling back to `.standard` for
    /// installs that predate the group.
    static var serverHost: String { NeutrinoStorage.serverHost }

    /// Writes the host to both suites, so a host set before the App Group shipped and a host set
    /// after it agree.
    static func setServerHost(_ host: String) {
        NeutrinoStorage.setServerHost(host)
    }

    // MARK: - Preconditions

    /// True when all three key-material entries are present in the Keychain.
    static func hasStoredKeys() -> Bool {
        NeutrinoStorage.hasStoredKeys()
    }

    static func accessToken() -> String? {
        NeutrinoStorage.accessToken()
    }
}
