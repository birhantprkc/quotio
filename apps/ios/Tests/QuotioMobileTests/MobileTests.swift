import Foundation
import Testing
@testable import QuotioMobile
import QuotioHostClient

@Test func rejectsUnsafeOriginsAndOwnerTokens() throws {
    for value in ["http://192.168.1.10", "https://user:pass@host.test", "https://host.test/path", "https://host.test?q=secret", "https://host.test#secret", "https://host.test:99999"] {
        #expect(throws: (any Error).self) { try Connection.origin(value) }
    }
    #expect(try Connection.origin("https://host.test:443").host == "host.test")
    #expect(throws: (any Error).self) { try Connection.clientID("owner-token") }
}

private func fixture() throws -> QuotioHostSnapshot {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try QuotioHostSnapshot.decode(Data(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("apps/cli/tests/fixtures/contracts/snapshot-v2.json")))
}

@Test func snapshotsKeepHostIdentityAndUnknownQuota() throws {
    let raw = try fixture()
    let snapshot = MobileSnapshot(raw)
    #expect(snapshot.accounts.count == raw.accounts.count)
    #expect(snapshot.accounts[0].metrics.isEmpty)
    var host = HostProfile(id: "other", name: "Same name", origin: URL(string: "https://host.test")!, clientID: "read", expiresAt: nil, snapshot: nil)
    #expect(throws: (any Error).self) { try host.accept(snapshot) }
    host.id = snapshot.hostID
    try host.accept(snapshot)
    #expect(host.snapshot?.revision == snapshot.revision)
}

@Test func cacheRoundTripAndCorruptionDoNotBecomeEmptyAccounts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = MobileStorage(directory: directory)
    #expect(try storage.load().hosts.isEmpty)
    var state = MobileState()
    let snapshot = MobileSnapshot(try fixture())
    state.hosts = [HostProfile(id: snapshot.hostID, name: "Host", origin: URL(string: "https://host.test")!, clientID: "read", expiresAt: nil, snapshot: snapshot)]
    state.blurAccountNames = true
    try storage.save(state)
    #expect(try storage.load().hosts.first?.snapshot?.accounts.count == snapshot.accounts.count)
    #expect(try storage.load().blurAccountNames)
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("state.json"))
    #expect(throws: (any Error).self) { try storage.load() }
}

@Test func pairingRejectsExpiredAndMismatchedCredentials() throws {
    let id = String(repeating: "a", count: 43)
    let token = "qclient.\(id).\(String(repeating: "b", count: 43))"
    func payload(client: String, expiration: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["pairing_version": 2, "origin": "https://host.test", "host_name": "Test Mac", "host_id": "host", "client_id": client, "expires_at": expiration, "token": token, "certificate": Data([1]).base64EncodedString()])
    }
    let now = Date(timeIntervalSince1970: 0)
    #expect(try Pairing.decode(payload(client: id, expiration: "2026-01-01T00:00:00Z"), now: now).clientID == id)
    #expect(throws: (any Error).self) { try Pairing.decode(payload(client: "other", expiration: "2026-01-01T00:00:00Z"), now: now) }
    #expect(throws: (any Error).self) { try Pairing.decode(payload(client: id, expiration: "1970-01-01T00:00:00Z"), now: now) }
}

@Test func oldRevisionCannotReplaceNewSnapshotAndWrongTokenScopeFails() throws {
    let raw = try fixture()
    let snapshot = MobileSnapshot(raw)
    var host = HostProfile(id: snapshot.hostID, name: "Test", origin: URL(string: "https://host.test")!, clientID: "id", expiresAt: nil, snapshot: snapshot)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apps/cli/tests/fixtures/contracts/snapshot-v2.json"))) as? [String: Any])
    json["revision"] = 0
    let older = try QuotioHostSnapshot.decode(JSONSerialization.data(withJSONObject: json))
    try host.accept(MobileSnapshot(older))
    #expect(host.snapshot?.revision == snapshot.revision)
    let id = String(repeating: "a", count: 43)
    let token = "qclient.\(id).\(String(repeating: "b", count: 43))"
    let data = try JSONSerialization.data(withJSONObject: ["schema_version":2, "api_version":2, "client_id":id, "access_mode":"manage", "ready":true, "refreshing":false])
    let status = try makeQuotioHostDecoder().decode(QuotioHostStatus.self, from: data)
    #expect(throws: (any Error).self) { try Connection.verify(status: status, snapshot: raw, token: token, expectedHostID: raw.host.id) }
}

@Test func staleQuotaAndCalendarKeysArePreserved() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try QuotioHostSnapshot.decode(Data(contentsOf: root.appendingPathComponent("QuotioIOS/demo-snapshot.json")))
    let account = try #require(MobileSnapshot(raw).accounts.first { $0.providerID == "codex" })
    #expect(account.analytics?.days.first?.date == "2026-08-30")
    var creditJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    creditJSON["resetCount"] = 2
    creditJSON["resetExpirations"] = [now.addingTimeInterval(-1).timeIntervalSinceReferenceDate, now.addingTimeInterval(60).timeIntervalSinceReferenceDate]
    let credits = try JSONDecoder().decode(MobileSnapshot.Account.self, from: JSONSerialization.data(withJSONObject: creditJSON))
    #expect(credits.availableResets(at: now) == 1)
    #expect(credits.availableResets(at: now.addingTimeInterval(60)) == 0)
    #expect(account.metrics.first?.remainingPercent == 39)
    #expect(account.isStale(at: Date(timeIntervalSince1970: 2_000_000_000)))
    #expect(account.metrics.first?.remainingPercent == 39)
}

@Test func versionTwoPairingSupportsProxiesAndPersistsDirectTrust() throws {
    let id = String(repeating: "a", count: 43)
    var json: [String: Any] = ["pairing_version": 2, "origin": "https://192.168.1.10:6768", "host_name": "Test Mac", "host_id": "host", "client_id": id,
                             "expires_at": "2030-01-01T00:00:00Z", "token": "qclient.\(id).\(String(repeating: "b", count: 43))"]
    let now = Date(timeIntervalSince1970: 0)
    #expect(try Pairing.decode(JSONSerialization.data(withJSONObject: json), now: now).certificate == nil)
    let certificate = Data([1, 2, 3])
    json["certificate"] = certificate.base64EncodedString()
    let pairing = try Pairing.decode(JSONSerialization.data(withJSONObject: json), now: now)
    #expect(pairing.certificate == certificate)
    #expect(pairing.hostName == "Test Mac")
    let profile = HostProfile(id: "host", name: "Mac", origin: try Connection.origin(pairing.origin), clientID: id,
                              expiresAt: pairing.expiresAt, snapshot: nil, certificate: pairing.certificate)
    #expect(try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(profile)).certificate == certificate)
    json["pairing_version"] = 1
    #expect(throws: (any Error).self) { try Pairing.decode(JSONSerialization.data(withJSONObject: json), now: now) }
    json["pairing_version"] = 2
    json["certificate"] = ""
    #expect(throws: (any Error).self) { try Pairing.decode(JSONSerialization.data(withJSONObject: json), now: now) }
}

@Test func savingStateExcludesOnlyTheOwnedFileFromBackup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keys: Set<URLResourceKey> = [.isExcludedFromBackupKey]
    let original = try directory.resourceValues(forKeys: keys).isExcludedFromBackup
    let storage = MobileStorage(directory: directory)
    try storage.save(MobileState())
    // iOS owns App Group root metadata. Saving must not try to modify that container.
    #expect(try directory.resourceValues(forKeys: keys).isExcludedFromBackup == original)
    #expect(try directory.appendingPathComponent("state.json").resourceValues(forKeys: keys).isExcludedFromBackup == true)
    #expect(try storage.load().hosts.isEmpty)
}
