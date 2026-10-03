//
//  AppIdentity.swift
//  Quotio App
//

import Foundation
import CryptoKit
import QuotioDomain

nonisolated enum AppIdentity {
    static let productionBundleIdentifier = RuntimeIdentity.productionBundleIdentifier
    static let legacyBundleIdentifiers = [
        "dev.quotio.desktop",
        "proseek.io.vn.Quotio",
    ]

    private static let userDefaultsMigrationKey = "migratedToByTrongAppIdentity"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    }

    static var isProduction: Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    static var runtimeIdentity: RuntimeIdentity {
        RuntimeIdentity(bundleIdentifier: bundleIdentifier)
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Quotio"
    }

    static func keychainService(suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }

    static func quotioCLIVaultNamespace(for bundleIdentifier: String = bundleIdentifier) -> String {
        guard bundleIdentifier != productionBundleIdentifier else { return "quotio-macos" }
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
        return "quotio-macos-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyKeychainServices(suffix: String) -> [String] {
        legacyBundleIdentifiers.map { "\($0).\(suffix)" } + ["com.quotio.\(suffix)"]
    }

    @discardableResult
    static func migrateLegacyUserDefaults(
        defaults: UserDefaults = .standard,
        currentBundleIdentifier: String = bundleIdentifier
    ) -> Bool {
        guard currentBundleIdentifier == productionBundleIdentifier else { return false }

        var currentDomain = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        guard currentDomain[userDefaultsMigrationKey] as? Bool != true else { return false }

        let legacyDomains = legacyBundleIdentifiers.compactMap {
            defaults.persistentDomain(forName: $0)
        }
        currentDomain = mergingUserDefaults(current: currentDomain, legacyDomains: legacyDomains)
        currentDomain[userDefaultsMigrationKey] = true
        defaults.setPersistentDomain(currentDomain, forName: currentBundleIdentifier)
        return true
    }

    static func mergingUserDefaults(
        current: [String: Any],
        legacyDomains: [[String: Any]]
    ) -> [String: Any] {
        var merged = current
        for legacyDomain in legacyDomains {
            for (key, value) in legacyDomain where merged[key] == nil {
                merged[key] = value
            }
        }
        return merged
    }
}
