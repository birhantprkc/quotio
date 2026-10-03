import XCTest
@testable import Quotio

final class AppIdentityTests: XCTestCase {
    func testVaultNamespacesKeepNonproductionCredentialsSeparate() {
        XCTAssertEqual(
            AppIdentity.quotioCLIVaultNamespace(for: AppIdentity.productionBundleIdentifier),
            "quotio-macos"
        )
        let development = AppIdentity.quotioCLIVaultNamespace(for: "app.bytrong.quotio.dev")
        XCTAssertNotEqual(development, "quotio-macos")
        XCTAssertLessThanOrEqual(development.count, 32)
        XCTAssertTrue(development.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    func testBetaDoesNotMigrateLegacyDefaults() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sentinel", forKey: "existing")
        let betaDomainBefore = defaults.persistentDomain(forName: "app.bytrong.quotio.beta") ?? [:]
        XCTAssertFalse(AppIdentity.migrateLegacyUserDefaults(
            defaults: defaults, currentBundleIdentifier: "app.bytrong.quotio.beta"
        ))
        XCTAssertEqual(defaults.string(forKey: "existing"), "sentinel")
        let betaDomainAfter = defaults.persistentDomain(forName: "app.bytrong.quotio.beta") ?? [:]
        XCTAssertEqual(betaDomainBefore as NSDictionary, betaDomainAfter as NSDictionary)
    }

    func testApplicationBundleContainsExecutableQuotioCLIHelper() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/quotio-cli")

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    func testLegacyDefaultsMergePreservesCurrentValuesAndNewestLegacyDomain() {
        let merged = AppIdentity.mergingUserDefaults(
            current: ["existing": "current"],
            legacyDomains: [
                ["existing": "legacy", "legacyOnly": "newest"],
                ["legacyOnly": "oldest", "oldestOnly": true],
            ]
        )

        XCTAssertEqual(merged["existing"] as? String, "current")
        XCTAssertEqual(merged["legacyOnly"] as? String, "newest")
        XCTAssertEqual(merged["oldestOnly"] as? Bool, true)
    }
}
