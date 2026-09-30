import Foundation
import Testing
@testable import QuotioMobile
import QuotioHostClient

private let en = Locale(identifier: "en_US")

private func demo() throws -> MobileSnapshot {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return MobileSnapshot(try QuotioHostSnapshot.decode(Data(contentsOf: root.appendingPathComponent("QuotioIOS/demo-snapshot.json"))))
}

@Test func creditsDecodeFromHostAmounts() throws {
    let amp = try #require(try demo().accounts.first { $0.providerID == "amp" })
    let credits = try #require(amp.metrics.first { $0.id == "individual-credits" })
    #expect(credits.amounts == .init(remaining: 136.57, limit: nil, unit: "USD"))
    #expect(credits.content(locale: en) == .amount("$136.57"))
    #expect(amp.valueMetrics.map(\.id) == ["individual-credits", "workspace-credits"])
    #expect(amp.tileGroups.flatMap(\.metrics).map(\.id) == ["agent-usage", "orb-usage"])
    #expect(amp.planBadge == "Megawatt")

    let codex = try #require(try demo().accounts.first { $0.id == "codex-work" })
    #expect(codex.metrics.first { $0.id == "extra-usage" }?.content(locale: en) == .amount("62,500 credits"))
}

@Test func groupsIdentityAndTierSurviveMapping() throws {
    let snapshot = try demo()
    let factory = try #require(snapshot.accounts.first { $0.providerID == "factory" })
    #expect(factory.tileGroups.map(\.name) == ["Standard", "Core"])
    #expect(factory.tileGroups.map(\.metrics.count) == [3, 3])
    #expect(factory.identity == "person@example.test")
    let antigravity = try #require(snapshot.accounts.first { $0.providerID == "antigravity" })
    #expect(antigravity.planBadge == "Standard")
    let kiro = try #require(snapshot.accounts.first { $0.providerID == "kiro" })
    #expect(kiro.identity == nil)
    #expect(!kiro.hasData)
    #expect(kiro.emptyReason == "Not loaded yet")
}

@Test func snapshotsCachedByOlderBuildsStillDecode() throws {
    let old = #"{"id":"w","name":"Weekly","state":"available","remainingPercent":40,"fetchedAt":0}"#
    let metric = try JSONDecoder().decode(MobileSnapshot.Metric.self, from: Data(old.utf8))
    #expect(metric.group == nil && metric.amounts == nil)
    let state = try JSONDecoder().decode(MobileState.self, from: Data(#"{"version":1,"hosts":[],"hideValues":true,"showUsed":false}"#.utf8))
    #expect(state.blurAccountNames && state.providerOrder.isEmpty && !state.lowFirst && state.density == .comfortable)
}

@Test func percentRuleTruncatesAndUsedComplementsDisplayedRemaining() {
    #expect(QuotaFormat.displayRemaining(47.6) == 47)
    #expect(QuotaFormat.displayRemaining(99.99) == 99)
    #expect(QuotaFormat.displayRemaining(0.4) == 0)
    #expect(QuotaFormat.displayRemaining(120) == 100)
    #expect(QuotaFormat.displayRemaining(-3) == 0)
    #expect(QuotaFormat.displayPercent(remaining: 47.6, showUsed: true) == 53)
    #expect(QuotaFormat.percentText(remaining: 47.6, showUsed: false, locale: en) == "47%")
    #expect(QuotaFormat.level(remaining: 50.9) == .low)
    #expect(QuotaFormat.level(remaining: 51) == .healthy)
    #expect(QuotaFormat.level(remaining: 20) == .low)
    #expect(QuotaFormat.level(remaining: 19.9) == .critical)
    #expect(QuotaFormat.level(remaining: nil) == .unknown)
}

@Test func countdownsAndAmountsUseLocalizedCompactUnits() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(QuotaFormat.countdown(to: now.addingTimeInterval(90_000 + 22 * 60), from: now, locale: en) == "1d 1h")
    #expect(QuotaFormat.countdown(to: now.addingTimeInterval(4 * 3600 + 22 * 60 + 30), from: now, locale: en) == "4h 22m")
    #expect(QuotaFormat.countdown(to: now.addingTimeInterval(20), from: now, locale: en) == "1m")
    #expect(QuotaFormat.countdown(to: now, from: now, locale: en) == nil)
    #expect(QuotaFormat.amount(0, unit: "USD", locale: en) == "$0")
    #expect(QuotaFormat.amount(136.57, unit: "USD", locale: Locale(identifier: "vi_VN")).replacingOccurrences(of: "\u{a0}", with: " ") == "136,57 US$")
}

@Test func providerLabelsBecomeReadableNames() {
    #expect(DisplayNames.metricLabel("Gemini Models gemini-weekly") == "Gemini · Weekly")
    #expect(DisplayNames.metricLabel("Claude and GPT Models claude-session") == "Claude and GPT · Session")
    #expect(DisplayNames.metricLabel("5 hours") == "5h window")
    #expect(DisplayNames.metricLabel("weekly") == "Weekly")
    #expect(DisplayNames.metricLabel("Codex Spark Weekly") == "Codex Spark · Weekly")
    #expect(DisplayNames.metricLabel("Amp Free daily") == "Amp Free · Daily")
    #expect(DisplayNames.metricLabel("Premium interactions") == "Premium requests")
    #expect(DisplayNames.metricLabel("Workspace bytrong credits") == "Workspace bytrong credits")
    #expect(DisplayNames.metricLabel("gemini-2.5-pro") == "Gemini 2.5 Pro")
    #expect(DisplayNames.prettified("devin-desktop") == "Devin Desktop")
    #expect(DisplayNames.accountState("ready") == "Active")
    #expect(DisplayNames.accountState("some_new_state") == "Some New State")
    #expect(DisplayNames.plan("individual") == "Individual")
    #expect(DisplayNames.plan("unknown").isEmpty)
    #expect(DisplayNames.issue("rate_limited") == "Rate limited by provider")
}

@Test func resetDescriptionsParseIntoStructuredHints() {
    var days = DateComponents(); days.day = 18
    #expect(DisplayNames.resetHint("upon renewal in 18 days") == .renewal(days))
    #expect(DisplayNames.shortReset(.renewal(days), locale: en) == "18d")
    #expect(DisplayNames.longReset(.renewal(days), locale: en) == "Resets on renewal in 18 days")
    #expect(DisplayNames.resetHint("daily") == .daily)
    #expect(DisplayNames.resetHint("billing period ends 2026-10-01 (timezone unspecified)") == .periodEnds(DateComponents(year: 2026, month: 10, day: 1)))
    #expect(DisplayNames.resetHint("replenishes +$0.42/hour") == .replenishes(rate: "+$0.42"))
    #expect(DisplayNames.resetHint("something new") == .other("something new"))
}

@Test func notLoadedIsNoDataWhileExpiredFreshDataIsStale() throws {
    let snapshot = try demo()
    let later = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(try #require(snapshot.accounts.first { $0.providerID == "kiro" }).isStale(at: later) == false)
    #expect(try #require(snapshot.accounts.first { $0.id == "codex-demo" }).isStale(at: later))
}

@Test func sectionsGroupByProviderAndHonorOrderAndLowFirst() throws {
    let snapshot = try demo()
    let hostOrder = snapshot.sections(order: [], lowFirst: false, pinned: []).map(\.providerID)
    #expect(hostOrder.first == "codex")
    #expect(snapshot.sections(order: [], lowFirst: false, pinned: []).first?.accounts.count == 2)
    #expect(snapshot.sections(order: ["amp", "kiro"], lowFirst: false, pinned: []).prefix(2).map(\.providerID) == ["amp", "kiro"])
    let low = snapshot.sections(order: [], lowFirst: true, pinned: [])
    #expect(low.first?.providerID == "factory")
    #expect(low.last?.providerID == "kiro")
    let codex = try #require(low.first { $0.providerID == "codex" })
    #expect(codex.accounts.first?.id == "codex-demo")
    let pinned = snapshot.sections(order: [], lowFirst: true, pinned: ["codex-work"]).first { $0.providerID == "codex" }
    #expect(pinned?.accounts.first?.id == "codex-work")
}

@Test func connectionErrorsMapToOneSpecificIssue() {
    #expect(ConnectionIssue(QuotioHostClientError.response(401, "unauthorized")) == .needsPairing)
    #expect(ConnectionIssue(MobileError.expiredCredential).needsPairing)
    #expect(ConnectionIssue(URLError(.serverCertificateUntrusted)) == .untrusted)
    #expect(ConnectionIssue(URLError(.cancelled)) == .untrusted)
    #expect(ConnectionIssue(URLError(.timedOut)) == .unreachable)
    #expect(ConnectionIssue(QuotioHostClientError.response(503, "server_busy")) == .busy)
    #expect(ConnectionIssue(QuotioHostClientError.incompatible) == .incompatible)
    #expect(!ConnectionIssue.unreachable.steps.isEmpty)
}
