import Foundation

/// Owns the credential and hands out usable access tokens to whichever process asks — the app or
/// the File Provider extension.
///
/// The extension is launched by `fileproviderd` with the app possibly not running, so refresh has
/// to happen here rather than being delegated to the app over IPC.
public actor TokenProvider {

    public enum RefreshOutcome: Sendable {
        case refreshed
        case usedCached
    }

    private let config: CloudDiskConfig
    private let store: CredentialStore
    private let exchanger: TokenExchanging
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    /// Coalesces concurrent refreshes. Ten simultaneous extension calls must cause one token
    /// request, not ten: Google's refresh endpoint is rate limited and parallel refreshes of the
    /// same grant are wasteful.
    private var inflight: Task<GoogleCredential, Error>?
    private var inflightGeneration: UInt64 = 0

    public init(config: CloudDiskConfig,
                store: CredentialStore,
                exchanger: TokenExchanging,
                transport: HTTPTransport = URLSessionTransport.shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.store = store
        self.exchanger = exchanger
        self.transport = transport
        self.now = now
    }

    // MARK: Credential lifecycle

    public func storedCredential() throws -> GoogleCredential? {
        try store.load()
    }

    public func save(_ credential: GoogleCredential) throws {
        try store.save(credential)
    }

    /// Signs out locally, then asks Google to revoke the refresh grant so a stale keychain copy in
    /// another process cannot keep working.
    public func signOut() async {
        if let credential = try? store.load() {
            await exchanger.revoke(token: credential.refreshToken)
        }
        inflight?.cancel()
        clearInflight()
        try? store.delete()
    }

    public var accountEmail: String? {
        (try? store.load())?.accountEmail
    }

    // MARK: Tokens

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        try await credential(forceRefresh: forceRefresh).accessToken
    }

    public func credential(forceRefresh: Bool = false) async throws -> GoogleCredential {
        guard let stored = try store.load() else {
            throw DriveError.notAuthenticated(revoked: false)
        }

        if !forceRefresh && !stored.needsRefresh(at: now()) {
            return stored
        }

        if let inflight {
            return try await inflight.value
        }

        inflightGeneration &+= 1
        let generation = inflightGeneration
        let task = Task { [exchanger, config, store, now, stored] in
            let result = try await exchanger.refresh(
                refreshToken: stored.refreshToken,
                clientID: config.clientID
            )
            var refreshed = stored
            refreshed.accessToken = result.accessToken
            refreshed.tokenExpiration = now().addingTimeInterval(result.expiresIn)
            if let scope = result.scope, !scope.isEmpty {
                refreshed.scope = scope
            }
            try store.save(refreshed)
            return refreshed
        }
        inflight = task

        do {
            let refreshed = try await task.value
            clearInflight(ifGeneration: generation)
            return refreshed
        } catch {
            clearInflight(ifGeneration: generation)
            throw error
        }
    }

    private func clearInflight() {
        inflight = nil
    }

    private func clearInflight(ifGeneration generation: UInt64) {
        if generation == inflightGeneration {
            inflight = nil
        }
    }

    // MARK: Authorized requests

    /// Sends an authorized request, refreshing once and retrying once if Google rejects the token.
    ///
    /// This is the only way DriveService should reach the network: it keeps the 401 path from being
    /// re-implemented (and got wrong) at every call site.
    public func authorizedSend(_ makeRequest: @escaping @Sendable (String) -> URLRequest,
                               uploadingFile: URL? = nil,
                               writingResponseTo destination: URL? = nil) async throws -> HTTPResponse {
        var token = try await accessToken()
        var response: HTTPResponse
        var attemptedRefresh = false

        while true {
            let request = makeRequest(token)
            response = try await transport.send(request,
                                                uploadingFile: uploadingFile,
                                                writingResponseTo: destination)

            if response.statusCode != 401 {
                return response
            }
            if attemptedRefresh {
                // A fresh token that is still refused means the grant is revoked or the scope is
                // insufficient, not that the token expired. Surface the API error rather than loop.
                return response
            }
            do {
                token = try await accessToken(forceRefresh: true)
                attemptedRefresh = true
            } catch let error as DriveError {
                // Revoked credentials must not be reported as a transient network failure.
                if case .notAuthenticated = error { throw error }
                return response
            }
        }
    }
}
