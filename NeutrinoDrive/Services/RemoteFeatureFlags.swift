import Foundation
import os.log

/// The server's feature flags this app acts on, fetched from `GET /api/v1/feature-flags` (public)
/// and cached in the App Group defaults, so the share extension and the Photos extension — which
/// never fetch anything themselves — follow them too.
///
/// There is one so far: `e2eeChunkedWrites` (neutrino#318), which decides whether uploads are
/// encrypted as NEB1. It is a rollout switch for a wire format, so the rules lean one way:
/// a server that doesn't declare the key (older than the flag) means **off**, and a fetch that fails
/// leaves the last answer in place rather than guessing.
enum RemoteFeatureFlags {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDrive",
                                       category: "RemoteFeatureFlags")

    /// Fetches the flags and caches the ones this app reads. Never throws: a failure keeps the
    /// cached values, which is the safe outcome for a switch.
    static func refresh(session: URLSession = .shared,
                        host: String = SharedStorage.serverHost,
                        defaults: UserDefaults = SharedStorage.defaults) async {
        guard let url = URL(string: host + "/api/v1/feature-flags") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                logger.warning("feature flags: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            try apply(data, to: defaults)
        } catch {
            logger.warning("feature flags not refreshed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Caches the flags in `data`, a `{ key: Bool }` map. A key the server doesn't send is off.
    static func apply(_ data: Data, to defaults: UserDefaults) throws {
        guard let flags = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let chunked = flags["e2eeChunkedWrites"] as? Bool ?? false
        defaults.set(chunked, forKey: E2EEUploader.chunkedWritesKey)
    }
}
