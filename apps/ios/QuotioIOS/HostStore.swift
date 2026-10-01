import Foundation
import Observation
import QuotioHostClient
import QuotioMobile
import WidgetKit

@MainActor @Observable
final class HostStore {
    var state = MobileState()
    /// The one problem shown in the connection banner; nil when the last read succeeded.
    var issue: ConnectionIssue?
    var refreshing = false
    var demo = false
    private let storage: MobileStorage?
    private let keychain: MobileKeychain
    private let makeClient: (QuotioHostConnection) -> QuotioHostHTTPClient
    private var generation = UUID()
    private var canSave = true

    init(storage: MobileStorage? = SharedContainer.storage, keychain: MobileKeychain = SharedContainer.keychain,
         makeClient: @escaping (QuotioHostConnection) -> QuotioHostHTTPClient = { QuotioHostHTTPClient(connection: $0) }) {
        self.storage = storage
        self.keychain = keychain
        self.makeClient = makeClient
        do {
            guard let storage else { throw MobileError.invalidCache }
            state = try storage.load()
        } catch { canSave = false; issue = .local(String(localized: "Saved connections could not be loaded.")) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
        if ProcessInfo.processInfo.arguments.contains("--blur-account-names") { state.blurAccountNames = true }
        if ProcessInfo.processInfo.arguments.contains("--offline") { issue = .unreachable }
        #endif
    }

    var selected: HostProfile? { state.hosts.first { $0.id == state.selectedHostID } }

    /// The issue to show for the selected Mac, including a pairing loss persisted from an earlier launch.
    var currentIssue: ConnectionIssue? { issue ?? (selected?.needsPairing == true ? .needsPairing : nil) }

    func togglePin(_ accountID: String) {
        guard let index = state.hosts.firstIndex(where: { $0.id == state.selectedHostID }) else { return }
        if !state.hosts[index].pinnedAccountIDs.insert(accountID).inserted { state.hosts[index].pinnedAccountIDs.remove(accountID) }
        persist()
    }

    func persist() {
        guard !demo, canSave else { return }
        do {
            guard let storage else { throw MobileError.invalidCache }
            try storage.save(state)
            WidgetCenter.shared.reloadAllTimelines()
        } catch { issue = .local(String(localized: "Changes could not be saved. Try again.")) }
    }

    func select(_ id: String) {
        generation = UUID()
        refreshing = false
        state.selectedHostID = id
        issue = nil
        persist()
    }

    func suspend() {
        generation = UUID()
        refreshing = false
    }

    func pair(name: String, origin: String, token: String, pairing: Pairing?) async throws {
        guard canSave else { throw MobileError.invalidCache }
        let url = try Connection.origin(origin)
        let id = try Connection.clientID(token)
        if let pairing {
            guard pairing.origin == origin, pairing.token == token else { throw MobileError.invalidConnection }
        }
        let client = makeClient(.init(baseURL: url, token: token, trustedCertificate: pairing?.certificate))
        let status = try await client.status()
        let snapshot = try await client.snapshot()
        let catalog: QuotioHostProviders = try await client.request("v2/providers")
        let names = catalog.providers.reduce(into: [String: String]()) { $0[$1.id] = $1.displayName }
        try Task.checkCancellation()
        try Connection.verify(status: status, snapshot: snapshot, token: token, expectedHostID: pairing?.hostID)
        if let pairing, pairing.expiresAt <= .now { throw MobileError.expiredCredential }
        let profile = HostProfile(id: snapshot.host.id,
                                  name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.host! : String(name.prefix(80)),
                                  origin: url, clientID: id, expiresAt: pairing?.expiresAt,
                                  snapshot: MobileSnapshot(snapshot, providerNames: names), certificate: pairing?.certificate)
        guard let storage else { throw MobileError.invalidCache }
        let oldToken = try keychain.read(profile.id)
        try keychain.save(token, host: profile.id)
        var next = demo ? MobileState() : state
        next.hosts.removeAll { $0.id == profile.id }
        next.hosts.append(profile)
        next.selectedHostID = profile.id
        do { try storage.save(next) }
        catch {
            if let oldToken { try keychain.save(oldToken, host: profile.id) }
            else { try keychain.delete(profile.id) }
            throw error
        }
        demo = false
        suspend()
        state = next
        issue = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refresh() async {
        guard !demo, !refreshing, let host = selected, !host.needsPairing else { return }
        let epoch = generation
        refreshing = true
        defer { if generation == epoch { refreshing = false } }
        do {
            guard host.expiresAt.map({ $0 > .now }) ?? true,
                  let token = try keychain.read(host.id) else { throw MobileError.expiredCredential }
            let client = makeClient(.init(baseURL: host.origin, token: token, trustedCertificate: host.certificate))
            let snapshot = try await client.snapshot()
            try Task.checkCancellation()
            guard generation == epoch, state.selectedHostID == host.id,
                  let index = state.hosts.firstIndex(where: { $0.id == host.id }) else { return }
            let names = (host.snapshot?.accounts ?? []).reduce(into: [String: String]()) { $0[$1.providerID] = $1.providerName }
            try state.hosts[index].accept(MobileSnapshot(snapshot, providerNames: names))
            issue = nil
            persist()
        } catch is CancellationError { }
        catch {
            guard generation == epoch, let index = state.hosts.firstIndex(where: { $0.id == host.id }) else { return }
            if case QuotioHostClientError.response(401, _) = error {
                state.hosts[index].needsPairing = true
                state.hosts[index].snapshot = nil
                persist()
            } else if case MobileError.expiredCredential = error {
                state.hosts[index].needsPairing = true
                state.hosts[index].snapshot = nil
                persist()
            }
            issue = ConnectionIssue(error)
        }
    }

    func remove(_ id: String) {
        do {
            if !demo { try keychain.delete(id) }
            suspend()
            state.hosts.removeAll { $0.id == id }
            if state.selectedHostID == id { state.selectedHostID = state.hosts.first?.id }
            if demo { demo = false; state = (try storage?.load()) ?? MobileState() }
            else { persist() }
        } catch { issue = .local(String(localized: "The saved credential could not be removed. Try again.")) }
    }

    func renameSelected(to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = state.selectedHostID,
              let index = state.hosts.firstIndex(where: { $0.id == id }),
              !name.isEmpty else { return }
        state.hosts[index].name = String(name.prefix(80))
        persist()
    }

    func showDemo() {
        do {
            guard let url = Bundle.main.url(forResource: "demo-snapshot", withExtension: "json") else { return }
            let snapshot = try QuotioHostSnapshot.decode(Self.rebased(Data(contentsOf: url), to: .now))
            demo = true
            suspend()
            state = MobileState()
            state.hosts = [HostProfile(id: snapshot.host.id, name: String(localized: "Demo Mac"),
                                      origin: URL(string: "https://demo.example.invalid")!, clientID: "demo", expiresAt: nil,
                                      snapshot: MobileSnapshot(snapshot))]
            state.selectedHostID = snapshot.host.id
            issue = nil
        } catch { issue = .local(String(localized: "The demo could not be loaded.")) }
    }

    /// Shifts every timestamp in the demo snapshot so it was generated `now`,
    /// keeping freshness and reset countdowns meaningful whenever the demo opens.
    static func rebased(_ data: Data, to now: Date) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generated = (json["generated_at"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }) else { return data }
        let offset = now.timeIntervalSince(generated)
        func shift(_ value: Any) -> Any {
            switch value {
            case let text as String:
                guard text.count == 20, let date = try? Date(text, strategy: .iso8601) else { return text }
                return date.addingTimeInterval(offset).formatted(.iso8601)
            case let array as [Any]: return array.map(shift)
            case let object as [String: Any]: return object.mapValues(shift)
            default: return value
            }
        }
        json = json.mapValues(shift)
        return try JSONSerialization.data(withJSONObject: json)
    }

    static func message(_ error: Error) -> String {
        switch error {
        case MobileError.invalidCache: String(localized: "Saved connections could not be loaded.")
        case MobileError.invalidConnection: String(localized: "Use an HTTPS address without a path, query or password.")
        case MobileError.readCredentialRequired: String(localized: "Use a read-only device token issued by Quotio on your computer.")
        case MobileError.wrongHost: String(localized: "This connection belongs to a different host. Pair it again.")
        case MobileError.expiredCredential, QuotioHostClientError.response(401, _): String(localized: "This device credential is no longer valid. Pair the host again.")
        case QuotioHostClientError.incompatible: String(localized: "This host uses an unsupported API. Update Quotio on the computer.")
        case QuotioHostClientError.response(503, _): String(localized: "The host is busy or its credential storage is locked. Retry after checking the host.")
        case let error as CocoaError where [.fileWriteNoPermission, .fileWriteOutOfSpace, .fileWriteVolumeReadOnly].contains(error.code):
            String(localized: "Changes could not be saved. Try again.")
        case is KeychainError: String(localized: "Secure storage is unavailable. Unlock your iPhone and try again.")
        default: String(localized: "Could not connect. Check the host, VPN and HTTPS certificate, then try again.")
        }
    }
}
