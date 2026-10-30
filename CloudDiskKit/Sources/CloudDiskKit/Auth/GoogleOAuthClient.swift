import Foundation

/// Result of an OAuth2 refresh exchange.
public struct TokenRefreshResult: Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: TimeInterval
    public let scope: String?

    public init(accessToken: String, expiresIn: TimeInterval, scope: String?) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.scope = scope
    }
}

/// The token endpoint, behind a protocol so `TokenProvider` can be tested without Google.
public protocol TokenExchanging: Sendable {
    func refresh(refreshToken: String, clientID: String) async throws -> TokenRefreshResult
    func revoke(token: String) async
}

public struct GoogleOAuthClient: TokenExchanging {
    private let transport: HTTPTransport
    private let tokenURL: URL
    private let revokeURL: URL

    public init(transport: HTTPTransport = URLSessionTransport.shared,
                tokenURL: URL = URL(string: CloudDiskConfig.googleTokenURLString)!,
                revokeURL: URL = URL(string: CloudDiskConfig.googleRevokeURLString)!) {
        self.transport = transport
        self.tokenURL = tokenURL
        self.revokeURL = revokeURL
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let scope: String?
        let token_type: String?
    }

    public func refresh(refreshToken: String, clientID: String) async throws -> TokenRefreshResult {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]).data(using: .utf8)

        let response = try await transport.send(request)

        guard response.isSuccess, let body = response.data else {
            // Google answers refresh failures with 400 and `error: invalid_grant`.
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                let revoked = Self.containsInvalidGrant(response.data)
                throw revoked ? DriveError.notAuthenticated(revoked: true)
                              : DriveError.notAuthenticated(revoked: false)
            }
            if (500..<600).contains(response.statusCode) {
                throw DriveError.serverTransient(statusCode: response.statusCode,
                                                 detail: "token endpoint")
            }
            throw DriveError.invalidResponse(detail: "token endpoint returned \(response.statusCode)")
        }

        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: body)
        } catch {
            throw DriveError.invalidResponse(detail: "token endpoint returned undecodable JSON")
        }

        guard !decoded.access_token.isEmpty else {
            throw DriveError.invalidResponse(detail: "token endpoint returned an empty access token")
        }

        return TokenRefreshResult(
            accessToken: decoded.access_token,
            expiresIn: TimeInterval(decoded.expires_in ?? 3600),
            scope: decoded.scope
        )
    }

    /// Best-effort revocation. Failure is not actionable for the user — the local credential is
    /// deleted either way — so this never throws.
    public func revoke(token: String) async {
        var components = URLComponents(url: revokeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await transport.send(request)
    }

    private static func containsInvalidGrant(_ data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("invalid_grant")
    }

    static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(Self.escape($0.key))=\(Self.escape($0.value))" }
            .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
