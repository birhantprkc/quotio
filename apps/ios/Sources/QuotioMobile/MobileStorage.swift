import Foundation
import Security

public enum Density: String, Codable, Sendable, CaseIterable {
    case compact, comfortable
}

public struct MobileState: Codable, Sendable {
    public var version = 1
    public var hosts: [HostProfile] = []
    public var selectedHostID: String?
    public var blurAccountNames = false
    public var showUsed = false
    /// Provider IDs in the user's order; providers not listed follow in host order.
    public var providerOrder: [String] = []
    public var lowFirst = false
    public var density = Density.comfortable
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, hosts, selectedHostID, showUsed, providerOrder, lowFirst, density
        case blurAccountNames = "hideValues"
    }

    /// Display preferences added after version 1 fall back to defaults when absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hosts = try container.decode([HostProfile].self, forKey: .hosts)
        selectedHostID = try container.decodeIfPresent(String.self, forKey: .selectedHostID)
        blurAccountNames = try container.decode(Bool.self, forKey: .blurAccountNames)
        showUsed = try container.decode(Bool.self, forKey: .showUsed)
        providerOrder = try container.decodeIfPresent([String].self, forKey: .providerOrder) ?? []
        lowFirst = try container.decodeIfPresent(Bool.self, forKey: .lowFirst) ?? false
        density = try container.decodeIfPresent(Density.self, forKey: .density) ?? .comfortable
    }
}

public struct MobileStorage: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> MobileState {
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MobileState() }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw MobileError.invalidCache }
        let state = try JSONDecoder().decode(MobileState.self, from: data)
        guard state.version == 1, Set(state.hosts.map(\.id)).count == state.hosts.count else { throw MobileError.invalidCache }
        return state
    }
    public func save(_ state: MobileState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        #endif
        // iOS owns the App Group root. Only change metadata on the file we own.
        var excluded = directory.appendingPathComponent("state.json")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}

public struct MobileKeychain: Sendable {
    private let accessGroup: String?
    private let service: String
    public init(accessGroup: String? = nil, service: String = "app.quotio.ios.hosts") { self.accessGroup = accessGroup; self.service = service }
    private func query(_ host: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: host]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
    public func read(_ host: String) throws -> String? {
        var query = query(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return token
    }
    public func save(_ token: String, host: String) throws {
        let query = query(host)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    public func delete(_ host: String) throws {
        let status = SecItemDelete(query(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
public struct KeychainError: Error, Sendable {
    public let status: OSStatus
}
