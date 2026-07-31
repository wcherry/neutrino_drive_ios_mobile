import Foundation

// MARK: - SharedStorage

/// Storage identifiers and accessors shared between the host app and the share extension.
///
/// These constants used to live on `AuthService` / `KeyImportService`, which are *not*
/// compiled into the share extension (they pull in `DriveService`, SwiftUI view models, and
/// the whole object graph). Extracting them here keeps the extension's shared-source set
/// small — see "Code-sharing strategy" in
/// `agent_docs/plans/feature-phase2-biometrics-share-background.md`.
///
/// The original names are preserved as aliases on their old owners, so every existing call
/// site and test continues to compile unchanged.
enum SharedStorage {

    // MARK: - Group identifiers

    /// App Group shared by the app and the share extension. Used for the server-host
    /// override and the extension's staging directory.
    static let appGroupIdentifier = "group.com.neutrino.drive"

    /// Keychain access group, so the extension can read the access token and the
    /// encryption-key material the app imported.
    ///
    /// The `$(AppIdentifierPrefix)` placeholder is substituted by the entitlements system at
    /// build time; the Security framework resolves the bare form below against the app's
    /// `keychain-access-groups` entitlement.
    static let keychainAccessGroup = "com.neutrino.drive.shared"

    // MARK: - Keys

    enum Keys {
        static let accessToken  = "nd.access_token"
        static let refreshToken = "nd.refresh_token"
        static let serverHost   = "nd.server_host"

        static let publicKey  = "nd.encryption.public_key"
        static let privateKey = "nd.encryption.private_key"
        static let keyVersion = "nd.encryption.key_version"
    }

    static let defaultHost = "http://localhost:8080"

    // MARK: - Defaults

    /// `UserDefaults` visible to both the app and the extension. Falls back to
    /// `.standard` when the App Group entitlement is missing (unit tests, or a build without
    /// the capability), so nothing ever crashes on a nil suite.
    static let defaults: UserDefaults = {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }()

    /// Server host override. Reads the App Group suite first so the extension sees whatever
    /// host the user configured in the app's login screen, falling back to `.standard` for
    /// installs that predate the App Group, then to `defaultHost`.
    static var serverHost: String {
        if let shared = defaults.string(forKey: Keys.serverHost) { return shared }
        if let local = UserDefaults.standard.string(forKey: Keys.serverHost) { return local }
        return defaultHost
    }

    /// Writes the host to both suites, so a host set before this build shipped and a host set
    /// after it agree.
    static func setServerHost(_ host: String) {
        defaults.set(host, forKey: Keys.serverHost)
        UserDefaults.standard.set(host, forKey: Keys.serverHost)
    }

    // MARK: - Preconditions

    /// True when all three key-material entries are present in the Keychain.
    ///
    /// Duplicates `KeyImportService.hasStoredKeys()` deliberately: the extension needs this
    /// check but must not compile `KeyImportService` (which drags in CryptoKit validation and
    /// the import UI's error surface). `KeyImportService.hasStoredKeys()` now delegates here,
    /// so there is exactly one implementation despite the two entry points.
    static func hasStoredKeys() -> Bool {
        KeychainService.load(forKey: Keys.publicKey)  != nil &&
        KeychainService.load(forKey: Keys.privateKey) != nil &&
        KeychainService.load(forKey: Keys.keyVersion) != nil
    }

    static func accessToken() -> String? {
        KeychainService.load(forKey: Keys.accessToken)
    }
}
