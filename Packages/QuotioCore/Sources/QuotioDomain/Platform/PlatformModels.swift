import Foundation

public enum ApplicationUpdatePolicy: Equatable, Sendable {
    case sparkle
    case manualDownload
}

public struct ApplicationUpdateSnapshot: Equatable, Sendable {
    public var policy: ApplicationUpdatePolicy
    public var isInitialized: Bool
    public var isChecking: Bool
    public var canCheck: Bool
    public var lastCheckDate: Date?
    public var channel: UpdateChannel

    public init(
        isInitialized: Bool = false,
        isChecking: Bool = false,
        canCheck: Bool = false,
        lastCheckDate: Date? = nil,
        channel: UpdateChannel = .stable,
        policy: ApplicationUpdatePolicy = .sparkle
    ) {
        self.isInitialized = isInitialized
        self.isChecking = isChecking
        self.canCheck = canCheck
        self.lastCheckDate = lastCheckDate
        self.channel = channel
        self.policy = policy
    }
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)

    public var isEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }
}

public enum LaunchAtLoginFailure: Error, Equatable, Sendable {
    case registrationFailed(String)
    case unregistrationFailed(String)
}

public struct LaunchAtLoginSnapshot: Equatable, Sendable {
    public var status: LaunchAtLoginStatus
    public var isInApplicationsFolder: Bool

    public init(status: LaunchAtLoginStatus, isInApplicationsFolder: Bool) {
        self.status = status
        self.isInApplicationsFolder = isInApplicationsFolder
    }
}

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum SemanticNotification: Equatable, Sendable {
    case quotaLow(id: String, provider: String, account: String, remainingPercent: Double)
    case accountCooling(provider: String, account: String)
    case proxyCrashed(exitCode: Int32)
    case proxyStarted
    case proxyUpdateAvailable(version: String)
    case proxyUpdateSucceeded(version: String)
    case proxyUpdateFailed(version: String, failure: ProxyFailure)
    case proxyRolledBack(version: String)
}

public struct NotificationSettingsSnapshot: Equatable, Sendable {
    public var preferences: NotificationPreferences
    public var authorizationStatus: NotificationAuthorizationStatus

    public init(
        preferences: NotificationPreferences,
        authorizationStatus: NotificationAuthorizationStatus = .notDetermined
    ) {
        self.preferences = preferences
        self.authorizationStatus = authorizationStatus
    }
}
