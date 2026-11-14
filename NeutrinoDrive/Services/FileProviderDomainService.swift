import Foundation
import FileProvider
import os.log

// MARK: - FileProviderDomainService

/// Registers and removes the `NSFileProviderDomain` that puts "Neutrino Drive" in the Files app
/// and in every document picker.
///
/// **A replicated extension has no implicit default domain.** Unlike the deprecated
/// `NSFileProviderExtension`, `NSFileProviderReplicatedExtension` never appears anywhere until
/// the containing app calls `NSFileProviderManager.add(_:)`. Shipping the extension target alone
/// would produce a bundle with an extension nobody can reach.
///
/// ## Why registration is tied to auth *and* keys
///
/// The domain is added only when the user is signed in **and** has imported their encryption
/// keys, and removed as soon as either goes away. A domain registered for a signed-out user
/// would leave a permanently failing "Neutrino Drive" location in the Files app — every
/// enumeration returning `notAuthenticated`, with no way for the user to tell a broken product
/// from an unconfigured one. Worse, a domain registered without keys would list files that can
/// never be opened, because materialization needs the private key to unseal each DEK.
enum FileProviderDomainService {

    static let domainIdentifier = NSFileProviderDomainIdentifier("com.neutrino.drive.domain")
    static let displayName = "Neutrino Drive"

    private static var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
               category: "FileProviderDomain")
    }

    /// Whether the domain *should* currently exist.
    ///
    /// A pure function so the policy — not the `NSFileProviderManager` call — is the thing that
    /// can be reasoned about and tested.
    static func shouldRegisterDomain(isAuthenticated: Bool, hasKeys: Bool) -> Bool {
        FeatureFlags.filesAppIntegration && isAuthenticated && hasKeys
    }

    // MARK: - Lifecycle

    /// Brings the registered domain into line with the current auth/key state. Safe to call on
    /// every launch and on every auth change; adding an existing domain is a no-op.
    static func synchronize(isAuthenticated: Bool, hasKeys: Bool) async {
        if shouldRegisterDomain(isAuthenticated: isAuthenticated, hasKeys: hasKeys) {
            await register()
        } else {
            await unregister()
        }
    }

    static func register() async {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
        do {
            try await NSFileProviderManager.add(domain)
            logger.debug("File Provider domain registered")
        } catch {
            // Not fatal: the app works without the Files-app location. Logged rather than
            // surfaced, because there is no action the user could take.
            logger.error("failed to register File Provider domain: \(error, privacy: .public)")
        }
    }

    static func unregister() async {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
        do {
            try await NSFileProviderManager.remove(domain)
            logger.debug("File Provider domain removed")
        } catch {
            logger.error("failed to remove File Provider domain: \(error, privacy: .public)")
        }
    }

    /// Asks the system to re-enumerate, after a change the app made that the Files app cannot
    /// learn about on its own.
    ///
    /// This is the *only* push signal available. The backend has no change feed, so a change
    /// made on the web or another device still surfaces only when the Files app re-enumerates
    /// of its own accord — see `FileProviderEnumerator`.
    static func signalWorkingSetChange() {
        guard FeatureFlags.filesAppIntegration else { return }
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { error in
            if let error {
                logger.error("signalEnumerator failed: \(error, privacy: .public)")
            }
        }
    }
}
