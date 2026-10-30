import Foundation

/// The Google OAuth material CloudDisk needs, shared between the container app and the
/// File Provider extension through the keychain.
public struct GoogleCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var tokenExpiration: Date
    public var scope: String?
    public var accountEmail: String?
    public var accountIdentifier: String?
    public var displayName: String?

    public init(accessToken: String, refreshToken: String, tokenExpiration: Date,
                scope: String? = nil, accountEmail: String? = nil,
                accountIdentifier: String? = nil, displayName: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiration = tokenExpiration
        self.scope = scope
        self.accountEmail = accountEmail
        self.accountIdentifier = accountIdentifier
        self.displayName = displayName
    }

    /// Refresh this long before Google's own expiry so a request never starts with a token that
    /// will die mid-flight.
    public static let refreshLeeway: TimeInterval = 120

    public func needsRefresh(at date: Date = .now) -> Bool {
        tokenExpiration.timeIntervalSince(date) <= Self.refreshLeeway
    }

    /// Deliberately redacted: this type is what a `print(error)` or a crash-log `description`
    /// will surface, and neither may contain a token.
    public var redactedSummary: String {
        let suffix = accessToken.isEmpty ? "" : "…\(accessToken.suffix(4))"
        return "GoogleCredential(email: \(accountEmail ?? "unknown"), access: <redacted\(suffix)>, "
            + "refresh: <redacted>, expires: \(tokenExpiration), scope: \(scope ?? "-"))"
    }
}

extension GoogleCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { redactedSummary }
    public var debugDescription: String { redactedSummary }
}

/// Where the credential lives. Two implementations: the shared keychain (production) and an
/// in-memory store (tests).
public protocol CredentialStore: Sendable {
    func load() throws -> GoogleCredential?
    func save(_ credential: GoogleCredential) throws
    func delete() throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GoogleCredential?

    public init(credential: GoogleCredential? = nil) {
        self.stored = credential
    }

    public func load() throws -> GoogleCredential? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ credential: GoogleCredential) throws {
        lock.lock(); defer { lock.unlock() }
        stored = credential
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
