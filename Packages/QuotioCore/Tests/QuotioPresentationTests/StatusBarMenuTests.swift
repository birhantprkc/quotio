import AppKit
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class StatusBarMenuSnapshotMapperTests: XCTestCase {
    func testMetricGroupsPreserveHostOrderAndExcludeExtraUsage() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "5 hours", percentage: 50, resetTime: "", group: "Standard"),
            QuotaMetric(name: "Weekly", percentage: 60, resetTime: "", group: "Standard"),
            QuotaMetric(name: "5 hours", percentage: 70, resetTime: "", group: "Core"),
            QuotaMetric(name: "Extra usage", percentage: -1, resetTime: "", presentation: .amount(value: 0, unit: .credits, semantics: .balance))
        ])
        XCTAssertEqual(quota.metricGroups.map(\.name), ["Standard", "Core"])
        XCTAssertEqual(quota.metricGroups.map { $0.models.count }, [2, 1])
        XCTAssertEqual(quota.models.filter(\.isStandaloneMetric).count, 1)
    }

    func testDisabledAccountsMatchOpaqueIDsExactly() {
        let disabled = Account.make(providerID: .init(rawValue: "codex"), accountKey: "Account-A", source: .nativeCredential, status: .disabled)
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [disabled],
            quota: QuotaSnapshot(quotas: [.codex: ["Account-A": ProviderQuota(), "account-a": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertEqual(snapshot.providers.first?.accounts.map(\.id.accountKey), ["account-a"])
    }

    func testMenuUsesHostProviderNamesWithoutAClientProviderSwitch() throws {
        let provider = try XCTUnwrap(QuotaProvider(rawValue: "future-provider"))
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(providerNames: [provider: "Host Provider Name"], quotas: [provider: ["account": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(), language: .english
        )
        XCTAssertEqual(snapshot.providers.first?.displayName, "Host Provider Name")
        XCTAssertFalse(snapshot.canRefresh)
        XCTAssertEqual(snapshot.providers.first?.supportsScopedRefresh, false)
        XCTAssertEqual(snapshot.providers.first?.accounts.first?.isRefreshBlocked, true)
    }

    func testDisabledProviderIsHiddenDespiteCachedQuota() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [.claude: ["Work": ProviderQuota()]]),
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            language: .english,
            trackingPreferences: .init(disabledProviders: [.claude])
        )
        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertNil(snapshot.selectedProvider)
    }

    func testMonitorSnapshotMapsProvidersAccountsStateAndDisplaySettings() throws {
        let enabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.amp.rawValue),
            accountKey: "monitor@example.com",
            source: .nativeCredential
        )
        let disabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let quota = QuotaSnapshot(
            canRefresh: true,
            quotas: [
                .antigravity: [
                    "alpha-key": ProviderQuota(accountDisplayName: "alpha@example.com"),
                    "zulu-key": ProviderQuota(accountDisplayName: "Zulu@example.com"),
                ],
                .claude: [
                    "claude-key": ProviderQuota(accountDisplayName: "claude@example.com"),
                ],
            ],
            refreshingProviders: [.antigravity]
        )
        let preferences = MenuBarPreferences(
            selectedProvider: .amp,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .ring,
            hideSensitiveInfo: true,
            modelAggregationMode: .average
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [enabledMonitorAccount, disabledMonitorAccount],
            quota: quota,
            menuBarPreferences: preferences,
            language: .vietnamese
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .claude])
        XCTAssertNil(snapshot.selectedProvider)
        XCTAssertTrue(snapshot.isLoadingQuotas)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayMode, .remaining)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayStyle, .ring)
        XCTAssertTrue(snapshot.displaySettings.hideSensitiveInfo)
        XCTAssertEqual(snapshot.displaySettings.modelAggregationMode, .average)
        XCTAssertEqual(snapshot.language, .vietnamese)

        let antigravity = try XCTUnwrap(snapshot.providers.first { $0.provider == .antigravity })
        XCTAssertTrue(antigravity.isRefreshing)
        XCTAssertTrue(antigravity.supportsScopedRefresh)
        XCTAssertEqual(antigravity.accounts.map(\.email), [
            "alpha@example.com",
            "Zulu@example.com",
        ])
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshing))
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshBlocked))
    }

    func testSnapshotUsesOnlyHostProviderData() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .antigravity: ["antigravity": ProviderQuota()],
                .claude: ["claude": ProviderQuota()],
                .codex: ["codex": ProviderQuota()],
            ]),
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            language: .english
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .claude, .codex])
        XCTAssertEqual(snapshot.selectedProvider, .claude)
    }

    func testSnapshotOnlyIncludesEnabledAccountsWithQuota() {
        let disabledAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.claude.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            monitorAccounts: [disabledAccount],
            quota: QuotaSnapshot(quotas: [
                .claude: ["disabled@example.com": ProviderQuota()],
                .codex: ["enabled@example.com": ProviderQuota()],
            ]),
            menuBarPreferences: MenuBarPreferences(),
            language: .english
        )

        XCTAssertEqual(snapshot.providers.map(\.provider), [.codex])
        XCTAssertEqual(snapshot.providers.first?.accounts.map(\.email), ["enabled@example.com"])
    }
}

@MainActor
final class StatusBarMenuRendererTests: XCTestCase {
    func testQuotaCardHeightDoesNotDependOnResetAvailability() throws {
        _ = NSApplication.shared
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, quit: {}, menuNeedsRebuild: {}
        ))
        let scenarios: [(QuotaProvider, [(String, String?)])] = [
            (.antigravity, [("Session", nil), ("Weekly", nil), ("Claude Session", nil), ("Claude Weekly", nil)]),
            (.factoryDroid, [("5 hours", "Standard"), ("Weekly", "Standard"), ("Monthly", "Standard"), ("5 hours", "Core"), ("Weekly", "Core"), ("Monthly", "Core")])
        ]
        for (provider, metrics) in scenarios {
            func cardHeight(_ resetTimes: [String]) throws -> CGFloat {
                let models = metrics.enumerated().map { index, metric in
                    QuotaMetric(name: metric.0, percentage: 50, resetTime: resetTimes[index], group: metric.1)
                }
                let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [], quota: QuotaSnapshot(quotas: [provider: ["Account": ProviderQuota(models: models)]]),
                    menuBarPreferences: MenuBarPreferences(selectedProvider: provider, quotaDisplayStyle: .card), language: .english
                )
                let renderer = StatusBarMenuRenderer(snapshot: snapshot, commands: commands)
                let menu = renderer.buildMenu()
                let item = try XCTUnwrap(menu.items.first { $0.title == "Account" })
                return try XCTUnwrap(item.view).bounds.height
            }
            let future = "2099-01-01T00:00:00Z"
            let expected = try cardHeight(Array(repeating: future, count: metrics.count))
            for resetTimes in [
                Array(repeating: "", count: metrics.count),
                metrics.indices.map { $0.isMultiple(of: 2) ? "" : future },
                Array(repeating: "invalid", count: metrics.count),
                Array(repeating: "2000-01-01T00:00:00Z", count: metrics.count)
            ] {
                XCTAssertEqual(try cardHeight(resetTimes), expected, accuracy: 0.5, provider.rawValue)
            }
        }
    }

    func testProviderFilterHidesItemsWithoutReplacingTrackedMenuContents() {
        var selections: [QuotaProvider?] = []
        let controller = StatusBarProviderFilterController(selectedProvider: nil) {
            selections.append($0)
        }
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        let codexItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        let providerHeader = NSMenuItem(title: "Header", action: nil, keyEquivalent: "")
        menu.items = [providerHeader, claudeItem, codexItem]
        controller.register(providerHeader, scope: .allProvidersOnly)
        controller.register(claudeItem, scope: .provider(.claude))
        controller.register(codexItem, scope: .provider(.codex))
        controller.activate(in: menu)
        let originalItems = menu.items.map(ObjectIdentifier.init)

        controller.select(.claude)

        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), originalItems)
        XCTAssertTrue(providerHeader.isHidden)
        XCTAssertFalse(claudeItem.isHidden)
        XCTAssertTrue(codexItem.isHidden)
        XCTAssertEqual(selections, [.claude])
    }

}

@MainActor
final class StatusBarCommandDispatcherTests: XCTestCase {
    func testPairingDoesNotOpenMainWindowOrRefreshQuota() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) { recorder.rebuildCount += 1 }
        dispatcher.dispatch(.pairIPhone)
        XCTAssertEqual(recorder.pairIPhoneCount, 1)
        XCTAssertEqual(recorder.openAppCount, 0)
        XCTAssertEqual(recorder.rebuildCount, 0)
        XCTAssertTrue(recorder.asyncCommands.isEmpty)
    }

    func testAsyncCommandsRouteAndRebuildAfterCompletion() async {
        let recorder = StatusBarCommandRecorder()
        let rebuilds = expectation(description: "menu rebuilt after async commands")
        rebuilds.expectedFulfillmentCount = 3
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
            rebuilds.fulfill()
        }

        dispatcher.dispatch(.refreshAll)
        dispatcher.dispatch(.refreshProvider(.claude))
        dispatcher.dispatch(.refreshAccount(QuotaAccountID(provider: .codex, accountKey: "person@example.com")))

        await fulfillment(of: [rebuilds], timeout: 1)
        XCTAssertEqual(Set(recorder.asyncCommands), Set([
            "refreshAll",
            "refreshProvider:claude",
            "refreshAccount:codex:person@example.com",
        ]))
        XCTAssertEqual(recorder.rebuildCount, 3)
    }

    func testSynchronousCommandsRouteWithoutUnnecessaryRebuilds() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.openApp)
        dispatcher.dispatch(.quit)
        dispatcher.dispatch(.selectProvider(.claude))
        dispatcher.dispatch(.selectProvider(nil))

        XCTAssertEqual(recorder.selectedProviders, [.claude, nil])
        XCTAssertEqual(recorder.openAppCount, 1)
        XCTAssertEqual(recorder.quitCount, 1)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    private func makeDispatcher(
        recorder: StatusBarCommandRecorder,
        menuNeedsRebuild: @escaping () -> Void
    ) -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: { recorder.asyncCommands.append("refreshAll") },
            refreshProvider: { provider in
                recorder.asyncCommands.append("refreshProvider:\(provider.rawValue)")
            },
            refreshAccount: { account in
                recorder.asyncCommands.append(
                    "refreshAccount:\(account.provider.rawValue):\(account.accountKey)"
                )
            },
            selectProvider: { recorder.selectedProviders.append($0) },
            pairIPhone: { recorder.pairIPhoneCount += 1 },
            openApp: { recorder.openAppCount += 1 },
            quit: { recorder.quitCount += 1 },
            menuNeedsRebuild: menuNeedsRebuild
        ))
    }
}

@MainActor
private final class StatusBarCommandRecorder {
    var asyncCommands: [String] = []
    var selectedProviders: [QuotaProvider?] = []
    var pairIPhoneCount = 0
    var openAppCount = 0
    var quitCount = 0
    var rebuildCount = 0
}
