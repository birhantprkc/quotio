import Foundation
import QuotioApplication
import QuotioDomain

public final class UserDefaultsProxyRuntimeMetadataRepository:
    ProxyRuntimeMetadataRepository,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let identity: RuntimeIdentity

    public init(defaults: UserDefaults = .standard, identity: RuntimeIdentity = .production) {
        self.defaults = defaults
        self.identity = identity
    }

    public func loadPort() -> UInt16 {
        let storedPort = defaults.integer(forKey: "proxyPort")
        guard storedPort > 0, storedPort < 65_536 else { return identity.defaultProxyPort }
        return UInt16(storedPort)
    }

    public func savePort(_ port: UInt16) {
        defaults.set(Int(port), forKey: "proxyPort")
    }

    public func loadLegacyInstalledVersion() -> String? {
        defaults.string(forKey: "installedProxyVersion_upstream")
    }

    public func saveLegacyInstalledVersion(_ version: String) {
        defaults.set(version, forKey: "installedProxyVersion_upstream")
    }

    public func loadLastUpdateCheckDate() -> Date? {
        defaults.object(forKey: "lastProxyUpdateCheckDate") as? Date
    }

    public func saveLastUpdateCheckDate(_ date: Date) {
        defaults.set(date, forKey: "lastProxyUpdateCheckDate")
    }
}
