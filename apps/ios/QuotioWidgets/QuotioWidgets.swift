import AppIntents
import SwiftUI
import WidgetKit
import Charts
import QuotioMobile
import QuotioHostClient

struct QuotaChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quota window"
    static let defaultQuery = QuotaQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static func identifier(host: String, account: String, metric: String) -> String { "\(host)/\(account)/\(metric)" }
    var components: [String] { id.split(separator: "/").map(String.init) }
}
struct QuotaQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [QuotaChoice] {
        let all = try await suggestedEntities()
        return identifiers.map { id in all.first { $0.id == id } ?? QuotaChoice(id: id, title: String(localized: "Unavailable quota")) }
    }
    func suggestedEntities() async throws -> [QuotaChoice] {
        let state = try SharedContainer.storage?.load() ?? MobileState()
        return state.hosts.filter { !$0.needsPairing }.flatMap { host in
            (host.snapshot?.accounts ?? []).flatMap { account in
                account.metrics.map { metric in
                    QuotaChoice(id: QuotaChoice.identifier(host: host.id, account: account.id, metric: metric.id),
                                title: "\(host.name) · \(account.providerName) · \(state.blurAccountNames ? String(localized: "Account hidden") : account.name) · \(metric.label)")
                }
            }
        }
    }
}
struct QuotaIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quota"
    static let description = IntentDescription("Choose a host, account and quota window.")
    @Parameter(title: "Quota window") var quota: QuotaChoice?
    @Parameter(title: "Show used percentage", default: false) var showUsed: Bool
}
struct QuotaEntry: TimelineEntry {
    let date: Date
    var account: MobileSnapshot.Account?
    var metric: MobileSnapshot.Metric?
    var showUsed = false
    var stale = true
    var message: String?
    var url: URL?
}
struct QuotaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: .now, message: String(localized: "Quota")) }
    func snapshot(for configuration: QuotaIntent, in context: Context) async -> QuotaEntry {
        await entry(configuration, fetch: !context.isPreview)
    }
    func timeline(for configuration: QuotaIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let entry = await entry(configuration, fetch: true)
        var entries = [entry]
        let dates = [entry.account?.expiresAt, entry.metric?.resetsAt].compactMap { $0 }.filter { $0 > entry.date }.sorted()
        for date in Set(dates).sorted() { var stale = entry; stale = QuotaEntry(date: date, account: stale.account, metric: stale.metric, showUsed: stale.showUsed, stale: true, message: stale.message, url: stale.url); entries.append(stale) }
        return Timeline(entries: entries, policy: .after(.now.addingTimeInterval(1800)))
    }
    private func entry(_ configuration: QuotaIntent, fetch: Bool) async -> QuotaEntry {
        var result = QuotaEntry(date: .now, showUsed: configuration.showUsed)
        do {
            guard let storage = SharedContainer.storage else { throw MobileError.invalidCache }
            let state = try storage.load()
            guard let choice = configuration.quota, choice.components.count == 3,
                  let host = state.hosts.first(where: { $0.id == choice.components[0] }) else {
                result.message = String(localized: "Edit widget to choose quota"); return result
            }
            guard !host.needsPairing, host.expiresAt.map({ $0 > .now }) ?? true else {
                result.message = String(localized: "Pair the host again"); return result
            }
            var snapshot = host.snapshot
            var offline = !fetch
            if fetch {
                do {
                    guard let token = try SharedContainer.keychain.read(host.id) else { throw MobileError.expiredCredential }
                    // Use the shared client's no-redirect session; its request timeout bounds the widget read.
                    let client = QuotioHostHTTPClient(connection: .init(baseURL: host.origin, token: token, trustedCertificate: host.certificate))
                    let remote: QuotioHostSnapshot = try await client.request("v2/snapshot", timeout: 8)
                    try remote.validate()
                    guard remote.host.id == host.id else { throw MobileError.wrongHost }
                    if snapshot.map({ remote.revision >= $0.revision }) ?? true { snapshot = MobileSnapshot(remote) }
                } catch QuotioHostClientError.response(401, _) {
                    result.message = String(localized: "Pair the host again"); return result
                } catch MobileError.expiredCredential {
                    result.message = String(localized: "Open Quotio to reconnect"); return result
                } catch MobileError.wrongHost {
                    result.message = String(localized: "Host identity changed"); return result
                } catch { offline = true }
            }
            // Re-read deletion changes after the network suspension.
            let latest = try storage.load()
            guard latest.hosts.contains(where: { $0.id == host.id && $0.clientID == host.clientID && $0.origin == host.origin && $0.certificate == host.certificate && !$0.needsPairing }) else {
                result.message = String(localized: "Host removed"); return result
            }
            guard let account = snapshot?.account(choice.components[1]),
                  let metric = account.metrics.first(where: { $0.id == choice.components[2] }) else {
                result.message = String(localized: "Quota unavailable"); return result
            }
            result.account = account; result.metric = metric
            result.stale = offline || account.isStale(at: .now) || metric.resetsAt.map { $0 <= .now } == true
            var url = URLComponents(); url.scheme = "quotio"; url.host = "account"
            url.queryItems = [.init(name: "host", value: host.id), .init(name: "id", value: account.id)]
            result.url = url.url
        } catch { result.message = String(localized: "Open Quotio to connect") }
        return result
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family
    private var value: Double? { entry.metric?.remainingPercent.map { Double(QuotaFormat.displayPercent(remaining: $0, showUsed: entry.showUsed)) } }
    private var label: String {
        if let remaining = entry.metric?.remainingPercent { return QuotaFormat.percentText(remaining: remaining, showUsed: entry.showUsed) }
        return entry.metric?.state == "unlimited" ? String(localized: "Unlimited") : "—"
    }
    var body: some View {
        Group {
            if let message = entry.message { Text(message).font(.caption) }
            else {
                switch family {
                case .accessoryInline:
                    Text("\(entry.account?.providerName ?? "Quotio") · \(label) \(entry.stale ? "◷" : "")")
                case .accessoryCircular:
                    if let value {
                        Gauge(value: value, in: 0...100) {
                            Image(systemName: entry.stale ? "clock" : "chart.pie")
                        } currentValueLabel: { Text(label).font(.caption) }
                        .gaugeStyle(.accessoryCircular)
                        .accessibilityLabel(Text("\(label) \(entry.showUsed ? String(localized: "used") : String(localized: "left"))"))
                    } else {
                        Image(systemName: entry.metric?.state == "unlimited" ? "infinity" : "questionmark")
                            .accessibilityLabel(entry.metric?.state == "unlimited" ? Text("Unlimited") : Text("Quota unavailable"))
                    }
                default:
                    VStack(alignment: .leading, spacing: family == .accessoryRectangular ? 2 : 10) {
                        Text(entry.account?.providerName ?? "Quotio").font(.headline)
                        Text(entry.metric?.label ?? "").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline) {
                            Text(label).font(family == .accessoryRectangular ? .title2 : .largeTitle).monospacedDigit()
                            Text(entry.showUsed ? "used" : "left").font(.caption)
                        }
                        if family != .accessoryRectangular, let value { ProgressView(value: value, total: 100).tint(.green) }
                        if entry.stale { Label("Older data", systemImage: "clock").font(.caption2) }
                        else if let reset = entry.metric?.resetsAt { Text(reset, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                        if family == .systemLarge, let account = entry.account {
                            Divider()
                            if let analytics = account.analytics {
                                Chart(Array(analytics.days.suffix(30))) { day in
                                    BarMark(x: .value("Reported day", day.date), y: .value("Tokens", day.tokens)).foregroundStyle(.green)
                                }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 80)
                                Text("30 reported days").font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(account.metrics.filter { $0.id != entry.metric?.id }.prefix(2)) { metric in
                                HStack { Text(metric.label); Spacer(); Text(metric.remainingPercent.map { QuotaFormat.percentText(remaining: $0, showUsed: entry.showUsed) } ?? "—") }.font(.caption)
                            }
                            Spacer(minLength: 0)
                            if let date = account.fetchedAt { Text("Observed \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.containerBackground(.background, for: .widget).widgetURL(entry.url).privacySensitive()
    }
}

@main struct QuotioWidgets: Widget {
    let kind = "QuotioQuota"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuotaIntent.self, provider: QuotaProvider()) { QuotaWidgetView(entry: $0) }
            .configurationDisplayName("Quota")
            .description("See quota and reset times from your computer.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
