import XCTest
@testable import CloudDiskKit

/// Query-string construction and retry arithmetic — pure functions, so every assertion here is
/// about the exact text Google would receive, not about a network round trip.
final class DriveQueryTests: XCTestCase {

    // MARK: Identifier validation

    func testIdentifierValidationAcceptsRealDriveIDs() {
        XCTAssertTrue(DriveQuery.isValidIdentifier("root"))
        XCTAssertTrue(DriveQuery.isValidIdentifier("1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"))
        XCTAssertTrue(DriveQuery.isValidIdentifier("shared-drive-id_1"))
        // Shared-drive ids and the literal "root" are both used as parents.
        XCTAssertTrue(DriveQuery.isValidIdentifier("0APz1V9YclhqkUk9PVRT"))
    }

    func testIdentifierValidationRejectsQueryInjectionShapes() {
        for candidate in ["", " ", "a b", "id' or '1'='1", "id\\", "a/b", "a?b", "a%20b",
                          String(repeating: "a", count: 65),
                          "id\ntrashed = true"] {
            XCTAssertFalse(DriveQuery.isValidIdentifier(candidate), "\(candidate) should be rejected")
        }
    }

    func testChildrenOfAnUnsafeParentThrowsInsteadOfInterpolating() {
        XCTAssertThrowsError(try DriveQuery.children(of: "root'; name contains 'x")) { error in
            guard case DriveError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    // MARK: String literals

    func testEscapedStringLiteralQuotesAndBackslashes() {
        XCTAssertEqual(DriveQuery.escapedStringLiteral("normal"), "'normal'")
        XCTAssertEqual(DriveQuery.escapedStringLiteral("it's"), "'it\\'s'")
        XCTAssertEqual(DriveQuery.escapedStringLiteral("back\\slash"), "'back\\\\slash'")
        // A quote inside a value must not be able to close the literal and start a new clause.
        XCTAssertEqual(DriveQuery.escapedStringLiteral("a' in parents or '1"),
                       "'a\\' in parents or \\'1'")
    }

    func testChildrenQueryIsScopedToOneFolderAndSkipsTheTrash() throws {
        let query = try DriveQuery.children(of: "folderABC123")
        XCTAssertEqual(query, "'folderABC123' in parents and trashed = false")
        XCTAssertEqual(try DriveQuery.children(of: "folderABC123", includeTrashed: true),
                       "'folderABC123' in parents")
    }

    func testExactNameQueryEscapesTheNameAndKeepsOneParent() throws {
        XCTAssertEqual(try DriveQuery.nameExactly("Quarterly Report", in: "folderABC123"),
                       "name = 'Quarterly Report' and 'folderABC123' in parents and trashed = false")
        XCTAssertEqual(try DriveQuery.nameExactly("it's here", in: "folderABC123"),
                       "name = 'it\\'s here' and 'folderABC123' in parents and trashed = false")
    }

    func testExactNameQueryRejectsBlankNamesAndUnsafeParents() {
        XCTAssertThrowsError(try DriveQuery.nameExactly("   ", in: "folderABC123"))
        XCTAssertThrowsError(try DriveQuery.nameExactly("ok", in: "bad parent"))
    }

    func testSearchQueryEscapesTextAndScopesToAParent() throws {
        XCTAssertEqual(try DriveQuery.nameContains("bbq' OR '1", in: "folderABC123"),
                       "'folderABC123' in parents and name contains 'bbq\\' OR \\'1' and trashed = false")
        XCTAssertEqual(try DriveQuery.nameContains("notes", in: nil),
                       "name contains 'notes' and trashed = false")
    }

    func testSearchQueryRejectsAnUnsafeParentID() {
        XCTAssertThrowsError(try DriveQuery.nameContains("x", in: "p' in parents or 'q")) { error in
            guard case DriveError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testSearchWithAnUnsafeParentNeverReachesTheTransport() async {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport)
        do {
            _ = try await env.service.search(query: "anything", parentID: "bad parent")
            XCTFail("search should have rejected the parent id")
        } catch {
            guard case DriveError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: Retry arithmetic

    func testRetryPolicyHonoursRetryAfterAndStaysInsideItsCeiling() {
        let policy = DriveRetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 8)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: 3), 3, accuracy: 0.001)
        // A server asking for longer than the ceiling is clipped, not obeyed forever.
        XCTAssertEqual(policy.delay(forAttempt: 2, retryAfter: 600), 8, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 3, retryAfter: 0.001), 0.1, accuracy: 0.001)
    }

    func testRetryPolicyGrowsExponentiallyAndStaysWithinJitterBounds() {
        let policy = DriveRetryPolicy(maxAttempts: 8, baseDelay: 1, maxDelay: 20)
        for attempt in 1...5 {
            let expected = min(20, pow(2.0, Double(attempt - 1)))
            for _ in 0..<50 {
                let delay = policy.delay(forAttempt: attempt, retryAfter: nil)
                XCTAssertGreaterThanOrEqual(delay, expected)
                XCTAssertLessThanOrEqual(delay, expected * 1.25 + 0.0001)
            }
        }
        // Past the ceiling the delay stops growing, so a run of attempts cannot stall the extension.
        for _ in 0..<20 {
            XCTAssertLessThanOrEqual(policy.delay(forAttempt: 30, retryAfter: nil), 25)
        }
    }

    func testRetryPolicySleepsAtLeastItsFloorWhenGivenANegativeAttempt() {
        let policy = DriveRetryPolicy(maxAttempts: 3, baseDelay: 0.4, maxDelay: 20)
        let delay = policy.delay(forAttempt: 0, retryAfter: nil)
        XCTAssertGreaterThanOrEqual(delay, 0.4)
    }

    func testOnlyTransportAndRateLimitFailuresAreRetryable() {
        XCTAssertTrue(DriveError.rateLimited(retryAfter: nil).isRetryable)
        XCTAssertTrue(DriveError.serverTransient(statusCode: 503, detail: "x").isRetryable)
        XCTAssertTrue(DriveError.network(detail: "x").isRetryable)

        for fatal in [DriveError.notAuthenticated(revoked: true), .permissionDenied(detail: "x"),
                      .itemNotFound(id: "x"), .syncCursorExpired, .versionUnavailable,
                      .conflict(detail: "x"), .storageFull(detail: "x"),
                      .unsupportedItem(detail: "x"), .invalidResponse(detail: "x"),
                      .misconfigured(detail: "x"), .cancelled] {
            XCTAssertFalse(fatal.isRetryable, "\(fatal) must not be retried")
        }
    }

    func testErrorsThatNeedTheUserAreDistinguishedFromErrorsThatNeedARetry() {
        XCTAssertTrue(DriveError.notAuthenticated(revoked: false).requiresUserAction)
        XCTAssertTrue(DriveError.permissionDenied(detail: "x").requiresUserAction)
        XCTAssertTrue(DriveError.storageFull(detail: "x").requiresUserAction)
        XCTAssertFalse(DriveError.rateLimited(retryAfter: 5).requiresUserAction)
        XCTAssertFalse(DriveError.network(detail: "x").requiresUserAction)
        XCTAssertFalse(DriveError.syncCursorExpired.requiresUserAction)
    }

    // MARK: Status → error mapping

    func testDescribeCoversTheDriveStatusCodeTable() {
        XCTAssertEqual(DriveError.describe(statusCode: 401, googleReason: nil, message: "x"),
                       .notAuthenticated(revoked: false))
        XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: "userRateLimitExceeded",
                                          message: "x"),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(DriveError.describe(statusCode: 429, googleReason: "rateLimitExceeded",
                                          message: "x"),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(DriveError.describe(statusCode: 404, googleReason: "notFound", message: "gone"),
                       .itemNotFound(id: "gone"))
        XCTAssertEqual(DriveError.describe(statusCode: 409, googleReason: "conflict", message: "c"),
                       .conflict(detail: "c"))
        XCTAssertEqual(DriveError.describe(statusCode: 410,
                                          googleReason: "expiredStartPageToken", message: "x"),
                       .syncCursorExpired)
        XCTAssertEqual(DriveError.describe(statusCode: 416, googleReason: nil, message: "range"),
                       .conflict(detail: "range"))
        XCTAssertEqual(DriveError.describe(statusCode: 503, googleReason: "backendError", message: "b"),
                       .serverTransient(statusCode: 503, detail: "b"))
        XCTAssertEqual(DriveError.describe(statusCode: 218, googleReason: nil, message: "weird"),
                       .invalidResponse(detail: "HTTP 218: weird"))
    }

    func testA403WithAuthenticationWordingMeansRevokedConsent() {
        XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: "authSetupFailed",
                                          message: "The OAuth 2.0 consent screen was not completed"),
                       .notAuthenticated(revoked: true))
        XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: nil,
                                          message: "CloudDisk API permission disabled for this project"),
                       .notAuthenticated(revoked: true))
        // Plain permission problems stay permission problems: reconnecting would not help.
        XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: "accessNotConfigured",
                                          message: "no write access on this shared drive"),
                       .permissionDenied(detail: "no write access on this shared drive"))
    }

    func testBothRateLimitReasonSpellingsAreRetriedRatherThanReported() {
        for reason in ["rateLimitExceeded", "userRateLimitExceeded"] {
            XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: reason, message: "x"),
                           .rateLimited(retryAfter: nil), "\(reason) must be treated as a rate limit")
            XCTAssertEqual(DriveError.describe(statusCode: 429, googleReason: reason, message: "x"),
                           .rateLimited(retryAfter: nil))
        }
    }

    func testQuotaErrorsAreSeparatedFromPermissionErrors() {
        XCTAssertEqual(DriveError.describe(statusCode: 403, googleReason: "storageQuotaExceeded",
                                          message: "The file size cannot exceed"),
                       .storageFull(detail: "The file size cannot exceed"))
    }

    func testRetryAfterIsParsedFromBothAllowedFormats() {
        let seconds = HTTPResponse(statusCode: 429, headers: ["Retry-After": "7"], data: nil)
        let secondsValue = HTTPErrorMapper.retryAfter(from: seconds)
        XCTAssertEqual(secondsValue ?? -1, 7, accuracy: 0.001)

        // An HTTP-date in the past must not produce a negative sleep.
        let date = HTTPResponse(statusCode: 429,
                                headers: ["Retry-After": "Fri, 29 Oct 2026 00:00:00 GMT"], data: nil)
        let parsed = HTTPErrorMapper.retryAfter(from: date)
        XCTAssertNotNil(parsed)
        XCTAssertGreaterThanOrEqual(parsed ?? -1, 0)

        let missing = HTTPResponse(statusCode: 429, headers: [:], data: nil)
        XCTAssertNil(HTTPErrorMapper.retryAfter(from: missing))
    }

    func testErrorMapperTruncatesAndNeverEchoesRawHTML() {
        let markup = "<html>\n<body>" + String(repeating: "x", count: 2_000) + "</body>\n</html>"
        let html = Data(markup.utf8)
        let error = HTTPErrorMapper.error(statusCode: 500, body: html)
        guard case .serverTransient(let status, let detail) = error else {
            return XCTFail("expected serverTransient, got \(error)")
        }
        XCTAssertEqual(status, 500)
        XCTAssertLessThanOrEqual(detail.count, 320)
        XCTAssertFalse(detail.contains("\n"))
    }

    func testErrorMapperPrefersTheGoogleEnvelopeReason() {
        let body = Data("""
        {"error":{"code":403,"message":"The caller does not have permission","errors":[{"reason":"userRateLimitExceeded"}]}}
        """.utf8)
        XCTAssertEqual(HTTPErrorMapper.error(statusCode: 403, body: body),
                       .rateLimited(retryAfter: nil))
    }

    func testEmptyBodiesStillProduceADiagnosableError() {
        let error = HTTPErrorMapper.error(statusCode: 400, body: nil)
        guard case .invalidResponse(let detail) = error else {
            return XCTFail("expected invalidResponse, got \(error)")
        }
        XCTAssertTrue(detail.contains("no response body"))
    }
}
