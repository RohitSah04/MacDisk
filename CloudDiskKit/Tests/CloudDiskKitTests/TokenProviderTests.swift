import XCTest
@testable import CloudDiskKit

/// The token lifecycle the app and the File Provider extension share, exercised without Google.
///
/// These cases cover the four behaviours that decide whether a Finder session survives a long
/// afternoon: use a valid token, refresh before it dies, refresh exactly once on a 401, and turn a
/// revoked grant into something the user can act on.
final class TokenProviderTests: XCTestCase {

    // MARK: Cached tokens

    func testACurrentTokenIsUsedWithoutTouchingTheTokenEndpoint() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport)

        let token = try await env.tokens.accessToken()
        XCTAssertEqual(token, "cached-access-token")
        XCTAssertEqual(env.exchanger.refreshCount, 0)
        XCTAssertEqual(transport.requestCount, 0, "reading a token must not call Drive")

        _ = try await env.service.childrenPage(parentID: "folderABC123")
        XCTAssertEqual(transport.header("Authorization", at: 0), "Bearer cached-access-token")
        XCTAssertEqual(env.exchanger.refreshCount, 0)
    }

    func testARequestNeverCarriesTheRefreshToken() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport,
                                           credential: DriveTestEnvironment.expiringCredential())

        _ = try await env.service.childrenPage(parentID: "folderABC123")
        let auth = transport.header("Authorization", at: 0) ?? ""
        XCTAssertTrue(auth.hasPrefix("Bearer fresh-token"), auth)
        XCTAssertFalse(auth.contains("stored-refresh-token"))
    }

    func testARefreshUsesTheStoredRefreshTokenAndPersistsWhatGoogleReturned() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let exchanger = StubTokenExchange(script: [
            .token("fresh-token", expiresIn: 1800, scope: "https://www.googleapis.com/auth/drive.readonly")
        ])
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger,
                                           credential: DriveTestEnvironment.expiringCredential())

        let token = try await env.tokens.accessToken()
        XCTAssertEqual(token, "fresh-token")
        XCTAssertEqual(exchanger.recordedRefreshTokens, ["stored-refresh-token"])
        XCTAssertEqual(exchanger.recordedClientIDs, [env.config.clientID])

        let stored = try env.store.load()
        XCTAssertEqual(stored?.accessToken, "fresh-token")
        // Expiry is measured from the injected clock, so a test can prove the arithmetic.
        XCTAssertEqual(stored?.tokenExpiration,
                       DriveTestEnvironment.referenceDate.addingTimeInterval(1800))
        XCTAssertEqual(stored?.scope, "https://www.googleapis.com/auth/drive.readonly")
        // The refresh token is what makes re-auth possible; losing it would force a new sign-in.
        XCTAssertEqual(stored?.refreshToken, "stored-refresh-token")
    }

    func testAnEmptyScopeFromGoogleDoesNotOverwriteTheKnownOne() async throws {
        let transport = StubTransport(script: [])
        let exchanger = StubTokenExchange(script: [.token("fresh-token", expiresIn: 600, scope: "")])
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger,
                                            credential: DriveTestEnvironment.expiringCredential())

        _ = try await env.tokens.accessToken()
        let stored = try env.store.load()
        XCTAssertEqual(stored?.scope, "https://www.googleapis.com/auth/drive")
    }

    // MARK: 401 handling

    func testAnExpiredTokenIsRefreshedAndTheRequestReplayedOnce() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 401, message: "Invalid Credentials"),
            .json(DriveJSON.file(id: "fileAAA123", name: "notes.txt", version: "rev-2"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let file = try await env.service.file(id: "fileAAA123")
        XCTAssertEqual(file.name, "notes.txt")
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(transport.header("Authorization", at: 0), "Bearer cached-access-token")
        XCTAssertEqual(transport.header("Authorization", at: 1), "Bearer fresh-token")
        XCTAssertEqual(env.exchanger.refreshCount, 1)
    }

    func testAFreshTokenThatIsStillRefusedDoesNotLoop() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 401, message: "Invalid Credentials"),
            .googleError(status: 401, message: "invalid_client")
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.file(id: "fileAAA123")
            XCTFail("a refused token must not be reported as success")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: false))
        }
        XCTAssertEqual(transport.requestCount, 2, "one replay, no more")
        XCTAssertEqual(env.exchanger.refreshCount, 1)
    }

    func testARevokedGrantBecomesAReconnectPromptNotARetry() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let exchanger = StubTokenExchange(script: [
            .failure(.notAuthenticated(revoked: true))
        ])
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger,
                                           credential: DriveTestEnvironment.expiringCredential())

        do {
            _ = try await env.service.childrenPage(parentID: "folderABC123")
            XCTFail("revoked consent must throw")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: true))
            XCTAssertTrue(error.requiresUserAction)
        }
        XCTAssertEqual(transport.requestCount, 0, "nothing to send without a token")
    }

    func testATransientRefreshFailureStillSurfacesAsAnAuthenticationError() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 401, message: "Invalid Credentials")
        ])
        let exchanger = StubTokenExchange(script: [
            .failure(.serverTransient(statusCode: 503, detail: "token endpoint"))
        ])
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger)

        do {
            _ = try await env.service.file(id: "fileAAA123")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: false))
        }
        // The cached credential is not destroyed by a failed refresh: the next attempt can work.
        XCTAssertEqual(try env.store.load()?.accessToken, "cached-access-token")
    }

    func testNoCredentialMeansNoRequest() async throws {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport, credential: nil)

        do {
            _ = try await env.service.about()
            XCTFail("expected notAuthenticated")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: false))
        }
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(env.exchanger.refreshCount, 0)
    }

    // MARK: Coalescing

    func testTenSimultaneousCallersCauseOneTokenRequest() async throws {
        let transport = StubTransport(script: [])
        let exchanger = StubTokenExchange()
        exchanger.delay = 0.25
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger,
                                           credential: DriveTestEnvironment.expiringCredential())
        let tokens = env.tokens

        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        return try await tokens.accessToken()
                    } catch {
                        return "failed: \(error)"
                    }
                }
            }
            var collected: [String] = []
            for await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(Set(results), ["fresh-token"])
        XCTAssertEqual(exchanger.refreshCount, 1, "parallel refreshes must coalesce")
    }

    // MARK: Sign-out

    func testSignOutRevokesTheRefreshGrantAndDeletesTheCredential() async throws {
        let transport = StubTransport(script: [])
        let exchanger = StubTokenExchange()
        let env = DriveTestEnvironment.make(transport: transport, exchanger: exchanger)

        await env.tokens.signOut()

        XCTAssertEqual(exchanger.recordedRevokedTokens, ["stored-refresh-token"])
        XCTAssertNil(try env.store.load())

        do {
            _ = try await env.tokens.accessToken()
            XCTFail("signed out")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: false))
        }
    }

    func testSignOutWithoutAGrantStillClearsLocalState() async throws {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport, credential: nil)
        await env.tokens.signOut()
        XCTAssertNil(try env.store.load())
        XCTAssertEqual(env.exchanger.revokeCount, 0)
    }

    // MARK: Secret hygiene

    func testCredentialNeverPrintsItsTokens() {
        let credential = GoogleCredential(accessToken: "ya29.SECRET-ACCESS-VALUE-9999",
                                         refreshToken: "1//SECRET-REFRESH-VALUE-8888",
                                         tokenExpiration: DriveTestEnvironment.referenceDate,
                                         scope: "https://www.googleapis.com/auth/drive",
                                         accountEmail: "user@example.com")
        // A crash report, an NSException reason or a `print()` all go through one of these two.
        let printed = String(describing: credential) + " " + String(reflecting: credential)
        XCTAssertFalse(printed.contains("SECRET-ACCESS-VALUE-9999"))
        XCTAssertFalse(printed.contains("SECRET-REFRESH-VALUE-8888"))
        XCTAssertFalse(printed.contains("1//"))
        XCTAssertTrue(printed.contains("user@example.com"))
    }
}

/// The real token endpoint client, driven by the stub transport.
///
/// `TokenProvider` is tested against a fake exchanger, so this is where the actual wire format —
/// the form-encoded refresh body, the `invalid_grant` distinction and revocation — gets pinned down.
final class GoogleOAuthClientTests: XCTestCase {

    private func client(_ transport: StubTransport) -> GoogleOAuthClient {
        GoogleOAuthClient(transport: transport)
    }

    func testRefreshPostsAFormEncodedGrantAndParsesTheResponse() async throws {
        let transport = StubTransport(script: [
            .json(["access_token": "ya29.new-token", "expires_in": 1234,
                   "scope": "https://www.googleapis.com/auth/drive", "token_type": "Bearer"])
        ])
        let result = try await client(transport).refresh(
            refreshToken: "1//refresh", clientID: "client-123")

        XCTAssertEqual(result.accessToken, "ya29.new-token")
        XCTAssertEqual(result.expiresIn, 1234)
        XCTAssertEqual(result.scope, "https://www.googleapis.com/auth/drive")

        XCTAssertEqual(transport.method(at: 0), "POST")
        XCTAssertEqual(transport.host(at: 0), "oauth2.googleapis.com")
        XCTAssertEqual(transport.path(at: 0), "/token")
        XCTAssertEqual(transport.header("Content-Type", at: 0), "application/x-www-form-urlencoded")
        let body = transport.bodyText(at: 0) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("refresh_token=1%2F%2Frefresh"), body)
        XCTAssertTrue(body.contains("client_id=client-123"), body)
    }

    func testMissingExpiresInFallsBackToGooglesOneHour() async throws {
        let transport = StubTransport(script: [.json(["access_token": "ya29.token"])])
        let result = try await client(transport).refresh(refreshToken: "1//r", clientID: "c")
        XCTAssertEqual(result.expiresIn, 3600)
        XCTAssertNil(result.scope)
    }

    func testInvalidGrantIsReportedAsRevokedConsent() async throws {
        let transport = StubTransport(script: [
            .text(#"{"error":"invalid_grant","error_description":"Bad Request"}"#, status: 400)
        ])
        do {
            _ = try await client(transport).refresh(refreshToken: "1//dead", clientID: "c")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: true))
        }
    }

    func testA401WithoutInvalidGrantIsNotClaimedAsRevoked() async throws {
        let transport = StubTransport(script: [.text("Unauthorized", status: 401)])
        do {
            _ = try await client(transport).refresh(refreshToken: "1//r", clientID: "c")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: false))
        }
    }

    func testTokenEndpointOutagesStayRetryable() async throws {
        let transport = StubTransport(script: [.text("Backend Error", status: 503)])
        do {
            _ = try await client(transport).refresh(refreshToken: "1//r", clientID: "c")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(error, .serverTransient(statusCode: 503, detail: "token endpoint"))
        }
    }

    func testAnUnusableSuccessBodyBecomesAnInvalidResponse() async throws {
        let garbage = StubTransport(script: [.text("<html>login</html>")])
        do {
            _ = try await client(garbage).refresh(refreshToken: "1//r", clientID: "c")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            XCTAssertEqual(error, .invalidResponse(detail: "token endpoint returned undecodable JSON"))
        }

        let empty = StubTransport(script: [.json(["access_token": ""])])
        do {
            _ = try await client(empty).refresh(refreshToken: "1//r", clientID: "c")
            XCTFail("expected a failure")
        } catch let error as DriveError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testRevokePostsTheTokenAndNeverThrows() async {
        let transport = StubTransport(script: [.googleError(status: 500, message: "boom")])
        await client(transport).revoke(token: "1//refresh")
        XCTAssertEqual(transport.method(at: 0), "POST")
        XCTAssertEqual(transport.path(at: 0), "/revoke")
        XCTAssertEqual(transport.queryItems(at: 0)["token"], "1//refresh")

        let exhausted = StubTransport(script: [])
        await client(exhausted).revoke(token: "1//refresh")
        XCTAssertEqual(exhausted.requestCount, 1)
    }

    func testFormEncodingSortsAndEscapesForURLs() {
        let encoded = GoogleOAuthClient.formEncoded([
            "refresh_token": "1//a b+c&d", "grant_type": "refresh_token", "client_id": "c"
        ])
        XCTAssertEqual(encoded, "client_id=c&grant_type=refresh_token&refresh_token=1%2F%2Fa%20b%2Bc%26d")
    }
}
