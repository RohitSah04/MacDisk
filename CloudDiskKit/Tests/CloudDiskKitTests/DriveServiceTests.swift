import XCTest
@testable import CloudDiskKit

/// The Drive REST surface: what request each call produces, and what the service does with the
/// answer. Everything here runs against `StubTransport`, so these assertions hold whether or not
/// Google credentials are available on the machine — the live check is a separate, later step.
final class DriveServiceTests: XCTestCase {

    private let parentID = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
    private let fileID = "fileAAA1234567890abcdefghij"

    // MARK: Listing and pagination

    func testAllChildrenFollowsNextPageTokenUntilTheFeedIsExhausted() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.page(files: [DriveJSON.file(id: "a1aaaaa", name: "one.txt"),
                                        DriveJSON.file(id: "b2bbbbb", name: "two.txt")],
                                nextPageToken: "page-2", newPageToken: "same-query-token")),
            .json(DriveJSON.page(files: [DriveJSON.file(id: "c3ccccc", name: "three.txt")],
                                nextPageToken: "page-3")),
            .json(DriveJSON.page(files: [DriveJSON.file(id: "d4ddddd", name: "four.txt"),
                                        DriveJSON.file(id: "e5eeeee", name: "five.txt"),
                                        DriveJSON.file(id: "f6fffff", name: "six.txt")]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let files = try await env.service.allChildren(parentID: parentID)
        XCTAssertEqual(files.map(\.name), ["one.txt", "two.txt", "three.txt",
                                          "four.txt", "five.txt", "six.txt"])
        XCTAssertEqual(transport.requestCount, 3, "every page must be fetched, not just the first")
        XCTAssertNil(transport.queryItems(at: 0)["pageToken"])
        XCTAssertEqual(transport.queryItems(at: 1)["pageToken"], "page-2")
        XCTAssertEqual(transport.queryItems(at: 2)["pageToken"], "page-3")
        // The same query on every page: a Drive page token is only valid for its own query.
        let queries = (0..<3).map { transport.queryItems(at: $0)["q"] }
        XCTAssertEqual(Set(queries.compactMap { $0 }),
                       ["'\(parentID)' in parents and trashed = false"])
    }

    func testAllChildrenStopsAtTheItemLimit() async throws {
        let page = DriveJSON.page(files: [DriveJSON.file(id: "a1aaaaa", name: "one"),
                                        DriveJSON.file(id: "b2bbbbb", name: "two")],
                                 nextPageToken: "more")
        let transport = StubTransport(script: [.json(page), .json(page), .json(page)])
        let env = DriveTestEnvironment.make(transport: transport)

        let files = try await env.service.allChildren(parentID: parentID, limit: 4)
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(transport.requestCount, 2, "a bounded walk must not keep enumerating")
    }

    func testChildrenPageRequestsTheSharedDriveAwareListingParameters() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport, pageSize: 500)

        let page = try await env.service.childrenPage(parentID: parentID)
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(transport.method(at: 0), "GET")
        XCTAssertEqual(transport.host(at: 0), "www.googleapis.com")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/files")
        XCTAssertEqual(query["pageSize"], "500")
        XCTAssertEqual(query["orderBy"], "folder,name")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(query["includeItemsFromAllDrives"], "true",
                       "without this, shared-drive folders enumerate as empty")
        XCTAssertTrue(query["fields"]?.contains("nextPageToken") == true)
        XCTAssertTrue(query["fields"]?.contains("newPageToken") == true)
        XCTAssertEqual(page.fileList.count, 0)
    }

    func testChildrenPageOnlyAsksForTrashedItemsWhenTheCallerWantsThem() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: [])),
                                               .json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.childrenPage(parentID: parentID)
        XCTAssertEqual(transport.queryItems(at: 0)["q"],
                       "'\(parentID)' in parents and trashed = false")

        _ = try await env.service.childrenPage(parentID: parentID, includeTrashed: true)
        XCTAssertEqual(transport.queryItems(at: 1)["q"], "'\(parentID)' in parents")
    }

    func testTrashedPageIsItsOwnQueryOrderedByTheLatestDeletion() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.page(files: [DriveJSON.file(id: "a1aaaaa", name: "old.txt",
                                                        trashed: true,
                                                        modifiedTime: "2026-10-29T10:00:00Z")]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let page = try await env.service.trashedPage(pageToken: "trash-2")
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(query["q"], "trashed = true")
        XCTAssertEqual(query["orderBy"], "modifiedTime desc")
        XCTAssertEqual(query["pageToken"], "trash-2")
        XCTAssertEqual(page.fileList.first?.isTrashed, true)
    }

    func testSearchOrdersByModifiedTimeAndClampsToTheConfiguredPageSize() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport, pageSize: 1_000)

        _ = try await env.service.search(query: "report", parentID: parentID)
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(query["q"],
                       "'\(parentID)' in parents and name contains 'report' and trashed = false")
        XCTAssertEqual(query["orderBy"], "modifiedTime desc")
        XCTAssertEqual(query["supportsAllDrives"], "true")
    }

    func testRecentlyModifiedClampsItsPageSizeToWhatDriveAllows() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: [])),
                                               .json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.recentlyModified(limit: 5_000)
        XCTAssertEqual(transport.queryItems(at: 0)["pageSize"], "100")
        _ = try await env.service.recentlyModified(limit: 0)
        XCTAssertEqual(transport.queryItems(at: 1)["pageSize"], "1")
        XCTAssertEqual(transport.queryItems(at: 1)["q"], "trashed = false")
    }

    func testExactNameLookupIsOneCaseInsensitiveQueryScopedToOneFolder() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.page(files: [DriveJSON.file(id: "a1aaaaa", name: "Budget 2026",
                                                        parents: [parentID])]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let matches = try await env.service.exactMatches(named: "Budget 2026", in: parentID)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.parentID, parentID)
        XCTAssertEqual(transport.queryItems(at: 0)["q"],
                       "name = 'Budget 2026' and '\(parentID)' in parents and trashed = false")
    }

    func testFileGetSendsOnlyTheFieldsTheModelCanDecode() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: fileID, name: "clip.mp4", mimeType: "video/mp4",
                                 size: 4_000_000_000, version: "rev-9", md5Checksum: "d41d8cd98f",
                                 parents: [parentID], modifiedTime: "2026-10-29T23:12:04.500Z",
                                 capabilities: ["canEdit": true, "canDownload": true,
                                               "canTrash": true, "canCopy": true]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let file = try await env.service.file(id: fileID)
        XCTAssertTrue(transport.queryItems(at: 0)["fields"]?.contains("md5Checksum") == true)
        XCTAssertEqual(transport.queryItems(at: 0)["supportsAllDrives"], "true")
        XCTAssertEqual(file.byteCount, 4_000_000_000,
                       "size arrives as a string; a 4 GB file must not overflow")
        XCTAssertEqual(file.contentVersionToken, "v:rev-9")
        XCTAssertEqual(file.parsedModifiedTime, DriveDate.parse("2026-10-29T23:12:04.500Z"))
        XCTAssertTrue(file.capabilities?.isWritable == true)
        XCTAssertTrue(file.hasMediaContent)
    }

    func testFileGetRejectsAnIdentifierThatIsNotADriveID() async throws {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport)

        for bad in ["", "has space", "a'b", "x'", "a/b", "id?x"] {
            do {
                _ = try await env.service.file(id: bad)
                XCTFail("\(bad) is not a Drive id and must not be sent to Google")
            } catch let error as DriveError {
                XCTAssertEqual(error, .itemNotFound(id: bad))
            }
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testAMalformedIDCannotEscapeItsPathSegment() async throws {
        // `patch`/`delete` take the id straight from a caller, so a slash must not be able to
        // retarget the request at a different endpoint.
        let transport = StubTransport(script: [.json(DriveJSON.file(id: "x", name: "y")),
                                              .json(DriveJSON.file(id: "x", name: "z"))])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.patch(fileID: "a/../../changes", metadata: ["name": "y"])
        XCTAssertTrue(transport.path(at: 0).hasSuffix("/drive/v3/files/a%2F..%2F..%2Fchanges"),
                      transport.path(at: 0))

        _ = try await env.service.deletePermanently(fileID: "a?b#c")
        XCTAssertTrue(transport.path(at: 1).hasSuffix("/drive/v3/files/a%3Fb%23c"),
                      transport.path(at: 1))
    }

    func testRootIsAcceptedAsAParentIdentifier() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.page(files: []))])
        let env = DriveTestEnvironment.make(transport: transport)
        _ = try await env.service.childrenPage(parentID: "root")
        XCTAssertEqual(transport.queryItems(at: 0)["q"], "'root' in parents and trashed = false")
    }

    func testDecodingIgnoresUnknownFieldsAndStillReadsShortcuts() async throws {
        var object = DriveJSON.file(id: "s1sssss", name: "Link to sheet",
                                   mimeType: "application/vnd.google-apps.shortcut",
                                   shortcutTarget: fileID)
        object["futureField"] = ["nested": 1]
        let transport = StubTransport(script: [.json(object)])
        let env = DriveTestEnvironment.make(transport: transport)

        let file = try await env.service.file(id: "s1sssss")
        XCTAssertTrue(file.isShortcut)
        XCTAssertEqual(file.shortcutDetails?.targetId, fileID)
        XCTAssertFalse(file.hasMediaContent, "a shortcut has no bytes of its own")
    }

    // MARK: Changes feed

    func testCollectChangesDrainsEveryPageAndKeepsTheLatestStartToken() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.changesPage(changes: [DriveJSON.change(fileId: "a1aaaaa",
                                                                  file: DriveJSON.file(id: "a1aaaaa",
                                                                                      name: "one.txt"))],
                                       nextPageToken: "change-2", newStartPageToken: "7")),
            .json(DriveJSON.changesPage(changes: [DriveJSON.change(fileId: "b2bbbbb", removed: true),
                                                 DriveJSON.change(fileId: "c3ccccc",
                                                                  file: DriveJSON.file(id: "c3ccccc",
                                                                                      name: "two.txt"))],
                                       nextPageToken: "change-3", newStartPageToken: "8")),
            .json(DriveJSON.changesPage(changes: [], newStartPageToken: "9"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let batch = try await env.service.collectChanges(from: "7")
        XCTAssertEqual(batch.changes.count, 3)
        XCTAssertEqual(batch.startPageToken, "9", "the anchor is the terminal token, not the first")
        XCTAssertNil(batch.resumeToken)
        XCTAssertFalse(batch.truncated)
        XCTAssertFalse(batch.removedEverything)
        XCTAssertEqual(transport.requestCount, 3)
        XCTAssertEqual(transport.queryItems(at: 1)["pageToken"], "change-2")
    }

    func testChangePageAsksForTrashesAndSharedDrives() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.changesPage(changes: [],
                                                                          newStartPageToken: "12"))])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.changePage(from: "11")
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(query["pageToken"], "11")
        XCTAssertEqual(query["includeCorpusTrashes"], "true")
        XCTAssertEqual(query["includeRemovedEntries"], "true")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertTrue(query["fields"]?.contains("newStartPageToken") == true)
    }

    func testCollectChangesTruncatesAndHandBackAResumableToken() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.changesPage(changes: [DriveJSON.change(fileId: "a1aaaaa",
                                                                  file: DriveJSON.file(id: "a1aaaaa",
                                                                                      name: "x"))],
                                       nextPageToken: "change-2", newStartPageToken: "7"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let batch = try await env.service.collectChanges(from: "7", maxPages: 1)
        XCTAssertTrue(batch.truncated)
        XCTAssertEqual(batch.resumeToken, "change-2")
        XCTAssertNil(batch.startPageToken, "a truncated walk has not reached the current state")
        XCTAssertEqual(batch.changes.count, 1)
    }

    func testCollectChangesReportsAGlobalPurge() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.changesPage(changes: [], nextPageToken: "change-2",
                                       newStartPageToken: "20", removes: true)),
            .json(DriveJSON.changesPage(changes: [], newStartPageToken: "21"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let batch = try await env.service.collectChanges(from: "19")
        XCTAssertTrue(batch.removedEverything,
                      "Google marks the purge on the page where history was dropped; a feed that "
                      + "later pages cleanly still has to expire the caller's anchor")

        let purged = StubTransport(script: [
            .json(DriveJSON.changesPage(changes: [], nextPageToken: "only", newStartPageToken: "20",
                                       removes: true)),
            .json(DriveJSON.changesPage(changes: [], newStartPageToken: "21", removes: true))
        ])
        let second = DriveTestEnvironment.make(transport: purged)
        let batch2 = try await second.service.collectChanges(from: "19", maxPages: 1)
        XCTAssertTrue(batch2.removedEverything)

        // The other direction: a feed that never mentions `removes` must leave the anchor alone.
        let clean = DriveTestEnvironment.make(transport: StubTransport(script: [
            .json(DriveJSON.changesPage(changes: [DriveJSON.change(fileId: "a1aaaaa",
                                                                  file: DriveJSON.file(id: "a1aaaaa",
                                                                                      name: "x"))],
                                       newStartPageToken: "22"))
        ]))
        let batch3 = try await clean.service.collectChanges(from: "21")
        XCTAssertFalse(batch3.removedEverything)
        XCTAssertEqual(batch3.startPageToken, "22")
    }

    func testCollectChangesFailsLoudlyWithoutAStartToken() async throws {
        let transport = StubTransport(script: [.json(DriveJSON.changesPage(changes: []))])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.collectChanges(from: "7")
            XCTFail("a feed with no newStartPageToken cannot become a sync anchor")
        } catch let error as DriveError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testAnExpiredChangeTokenIsNotRetried() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 410, reason: "expiredStartPageToken",
                         message: "Start time window too large")
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.changePage(from: "1")
            XCTFail("expected syncCursorExpired")
        } catch let error as DriveError {
            XCTAssertEqual(error, .syncCursorExpired)
            XCTAssertFalse(error.isRetryable, "a rescan, not a retry, is the fix")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testStartChangeTokenRoundTrip() async throws {
        let transport = StubTransport(script: [.json(["startPageToken": "256"])])
        let env = DriveTestEnvironment.make(transport: transport)
        let token = try await env.service.startChangeToken()
        XCTAssertEqual(token, "256")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/changes/startPageToken")
        XCTAssertEqual(transport.queryItems(at: 0)["supportsAllDrives"], "true")
    }

    // MARK: Retry through the service

    func testARateLimitedListIsRetriedUntilItAnswers() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 429, reason: "rateLimitExceeded", message: "Too Many Requests",
                         retryAfter: "0"),
            .json(DriveJSON.page(files: [DriveJSON.file(id: "a1aaaaa", name: "one.txt")]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let page = try await env.service.childrenPage(parentID: parentID)
        XCTAssertEqual(page.fileList.map(\.name), ["one.txt"])
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testA403RateLimitIsRetriedJustLikeA429() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 403, reason: "userRateLimitExceeded", message: "Limit exceeded"),
            .json(DriveJSON.page(files: []))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.childrenPage(parentID: parentID)
        XCTAssertEqual(transport.requestCount, 2,
                       "a 403 rate limit must not be shown to the user as a permission failure")
    }

    func testTransientFailuresAreRetriedUpToTheAttemptLimitThenReported() async throws {
        let transport = StubTransport(script: [
            .googleError(status: 503, reason: "backendError", message: "Backend Error"),
            .googleError(status: 503, reason: "backendError", message: "Backend Error"),
            .googleError(status: 503, reason: "backendError", message: "Backend Error")
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.childrenPage(parentID: parentID)
            XCTFail("expected the retry budget to run out")
        } catch let error as DriveError {
            XCTAssertEqual(error, .serverTransient(statusCode: 503, detail: "Backend Error"))
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(transport.requestCount, 3, "exactly the configured number of attempts")
    }

    func testPermanentFailuresAreNotRetried() async throws {
        let cases: [(StubTransport.Reply, DriveError)] = [
            (.googleError(status: 403, reason: "accessNotConfigured",
                          message: "no write access"),
             .permissionDenied(detail: "no write access")),
            (.googleError(status: 404, reason: "notFound", message: "File not found"),
             .itemNotFound(id: "File not found")),
            (.googleError(status: 403, reason: "storageQuotaExceeded", message: "Quota exhausted"),
             .storageFull(detail: "Quota exhausted")),
            (.googleError(status: 409, reason: "cuRequest", message: "Concurrent access"),
             .conflict(detail: "Concurrent access"))
        ]

        for (reply, expected) in cases {
            let transport = StubTransport(script: [reply, reply, reply])
            let env = DriveTestEnvironment.make(transport: transport)
            do {
                _ = try await env.service.childrenPage(parentID: parentID)
                XCTFail("expected \(expected)")
            } catch let error as DriveError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(transport.requestCount, 1, "\(expected) must not be retried")
        }
    }

    func testAnUndecodableSuccessBodyBecomesADiagnosedFailure() async throws {
        let transport = StubTransport(script: [.text("not json at all")])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.childrenPage(parentID: parentID)
            XCTFail("expected invalidResponse")
        } catch let error as DriveError {
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("files.list"))
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testRetryRunnerStopsAsSoonAsTheCallerIsCancelled() async throws {
        let attempts = MutableBox(0)
        do {
            _ = try await RetryRunner.run(
                policy: DriveRetryPolicy(maxAttempts: 6, baseDelay: 0.001, maxDelay: 0.001),
                isCancelled: { true }
            ) {
                attempts.value += 1
                throw DriveError.rateLimited(retryAfter: nil)
            }
            XCTFail("expected cancellation")
        } catch let error as DriveError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(attempts.value, 1)
    }

    func testRetryRunnerReturnsTheFirstSuccessAndCountsItsAttempts() async throws {
        let attempts = MutableBox(0)
        let value = try await RetryRunner.run(
            policy: DriveRetryPolicy(maxAttempts: 5, baseDelay: 0.001, maxDelay: 0.001)
        ) {
            attempts.value += 1
            if attempts.value < 3 { throw DriveError.network(detail: "flapping") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts.value, 3)
    }

    // MARK: Full download

    func testDownloadReadsMetadataFirstAndStreamsTheBytesToTheDestination() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("notes.txt")
        let blob = Data((0..<4096).map { UInt8($0 % 251) })

        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: fileID, name: "notes.txt", size: 4096, version: "rev-7")),
            StubTransport.Reply(statusCode: 200,
                               headers: ["Content-Type": "text/plain"], body: blob)
        ])
        let env = DriveTestEnvironment.make(transport: transport)
        let progress = Progress(totalUnitCount: 0)

        let metadata = try await env.service.download(fileID: fileID, to: destination,
                                                     progress: progress)

        XCTAssertEqual(metadata.contentVersionToken, "v:rev-7",
                       "File Provider compares this against the bytes it just received")
        XCTAssertEqual(try Data(contentsOf: destination), blob)
        XCTAssertEqual(progress.completedUnitCount, 4096)
        XCTAssertEqual(transport.requestCount, 2)

        let media = transport.queryItems(at: 1)
        XCTAssertEqual(media["alt"], "media")
        XCTAssertEqual(media["acknowledgeAbuse"], "true",
                       "without it Drive refuses media for scanned-abuse files")
        XCTAssertEqual(media["supportsAllDrives"], "true")
        XCTAssertNil(transport.header("Range", at: 1))
        XCTAssertEqual(transport.calls[1].writingResponseTo, destination,
                       "the body must go to disk, not into RAM")
    }

    func testDownloadRefusesAFolderWithoutFetchingAnything() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(script: [.json(DriveJSON.folder(id: parentID, name: "Docs"))])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.download(fileID: parentID,
                                              to: directory.appendingPathComponent("Docs"))
            XCTFail("a folder has no content")
        } catch let error as DriveError {
            guard case .unsupportedItem = error else {
                return XCTFail("expected unsupportedItem, got \(error)")
            }
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testAGoogleDocumentIsExportedRatherThanDownloaded() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Plan.pdf")
        let pdf = Data("%PDF-1.4 fake exported document".utf8)

        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: "docAAA111", name: "Plan",
                                 mimeType: "application/vnd.google-apps.document",
                                 exportLinks: ["application/pdf": "https://docs.google.com/epdf",
                                               "text/plain": "https://docs.google.com/txt"])),
            StubTransport.Reply(statusCode: 200, body: pdf)
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let metadata = try await env.service.download(fileID: "docAAA111", to: destination)
        XCTAssertEqual(metadata.isGoogleNative, true)
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(transport.path(at: 1), "/drive/v3/files/docAAA111/export")
        XCTAssertEqual(transport.queryItems(at: 1)["mimeType"], "application/pdf")
        XCTAssertNil(transport.queryItems(at: 1)["alt"], "the export endpoint has no alt=media")
        XCTAssertEqual(try Data(contentsOf: destination), pdf)
    }

    func testADocTypeWithNoExportFormatIsRejectedRatherThanEmptyFileWritten() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("map.bin")
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: "mapAAA111", name: "Map",
                                 mimeType: "application/vnd.google-apps.map"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.download(fileID: "mapAAA111", to: destination)
            XCTFail("expected unsupportedItem")
        } catch let error as DriveError {
            guard case .unsupportedItem = error else {
                return XCTFail("expected unsupportedItem, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a failed download must not leave a zero-byte file behind")
    }

    // MARK: Byte ranges

    func testARangeRequestSendsTheWindowAndReportsWhatTheServerSaid() async throws {
        let window = Data((100..<200).map { UInt8($0 % 251) })
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 206, headers: ["Content-Range": "bytes 100-199/1234"],
                                body: window)
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let range = try await env.service.downloadRange(fileID: fileID, offset: 100, length: 100)
        XCTAssertEqual(transport.header("Range", at: 0), "bytes 100-199")
        XCTAssertEqual(transport.queryItems(at: 0)["alt"], "media")
        XCTAssertEqual(range.data, window)
        XCTAssertEqual(range.offset, 100)
        XCTAssertEqual(range.length, 100)
        XCTAssertEqual(range.endOffset, 200)
        XCTAssertEqual(range.totalSize, 1234)
        XCTAssertFalse(range.servedWholeObject)
    }

    func testAWholeObjectAnsweredToARangeRequestIsFlaggedNotSilentlyOffset() async throws {
        // Drive really does this for small or oddly-encoded objects: 200 with the entire body.
        let whole = Data((0..<500).map { UInt8($0 % 251) })
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 200, body: whole)
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let range = try await env.service.downloadRange(fileID: fileID, offset: 400, length: 100)
        XCTAssertTrue(range.servedWholeObject)
        XCTAssertEqual(range.offset, 0, "the bytes start at 0 no matter what was asked for")
        XCTAssertNil(range.totalSize)
    }

    func testAZeroOffsetWholeObjectIsNotFlaggedBecauseTheOffsetAlreadyMatches() async throws {
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 200, body: Data(repeating: 0x41, count: 12))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let range = try await env.service.downloadRange(fileID: fileID, offset: 0, length: 12)
        XCTAssertFalse(range.servedWholeObject)
        XCTAssertEqual(range.offset, 0)
    }

    func testImpossibleWindowsAreRejectedBeforeTheNetwork() async throws {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport)

        for (offset, length) in [(-8 as Int64, 100), (0, 0), (-1, -1)] {
            do {
                _ = try await env.service.downloadRange(fileID: fileID, offset: offset,
                                                       length: length)
                XCTFail("expected invalidResponse for \(offset)+\(length)")
            } catch let error as DriveError {
                guard case .invalidResponse = error else {
                    return XCTFail("expected invalidResponse, got \(error)")
                }
            }
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testContentRangeAndAcceptedRangeHeadersAreParsedDefensively() {
        XCTAssertEqual(DriveService.totalSize(fromContentRange: "bytes 0-499/1234"), 1234)
        XCTAssertEqual(DriveService.totalSize(fromContentRange: "bytes 100-199/ 999999"), 999_999)
        XCTAssertNil(DriveService.totalSize(fromContentRange: "bytes 0-499/*"))
        XCTAssertNil(DriveService.totalSize(fromContentRange: nil))
        XCTAssertNil(DriveService.totalSize(fromContentRange: "garbage"))

        XCTAssertEqual(DriveService.acceptedByteCount(fromRangeHeader: "bytes=0-1048575",
                                                     fallback: 1), 1_048_576)
        XCTAssertEqual(DriveService.acceptedByteCount(fromRangeHeader: nil, fallback: 42), 42)
        XCTAssertEqual(DriveService.acceptedByteCount(fromRangeHeader: "no dash here",
                                                     fallback: 7), 7)
    }

    func testThumbnailsAreRequestedAtTheSizeTheUIActuallyNeeds() async throws {
        let file = DriveFile(id: fileID, name: "photo.jpg", mimeType: "image/jpeg",
                            thumbnailLink: "https://lh3.googleusercontent.com/d/\(fileID)=s220")
        let png = Data(repeating: 0x89, count: 64)
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 200, headers: ["Content-Type": "image/png"], body: png)
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let data = try await env.service.thumbnailData(for: file, maxPixelSize: 512)
        XCTAssertEqual(data, png)
        XCTAssertEqual(transport.host(at: 0), "lh3.googleusercontent.com")
        XCTAssertEqual(transport.queryItems(at: 0)["sz"], "512")
        XCTAssertTrue(transport.path(at: 0).contains("=s220"),
                      "Drive's own size suffix is part of the link path")
        XCTAssertEqual(transport.header("Authorization", at: 0), "Bearer cached-access-token")
    }

    func testAFileWithoutAThumbnailLinkNeedsNoRequest() async throws {
        let transport = StubTransport(script: [])
        let env = DriveTestEnvironment.make(transport: transport)
        let file = DriveFile(id: fileID, name: "notes.txt", mimeType: "text/plain")
        let data = try await env.service.thumbnailData(for: file)
        XCTAssertNil(data)
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: Uploads

    func testTheUploadStrategySwitchesAtTheMultipartLimit() {
        XCTAssertEqual(DriveService.UploadStrategy.suited(toByteCount: 1), .multipart)
        XCTAssertEqual(DriveService.UploadStrategy.suited(toByteCount: DriveService.UploadStrategy.multipartLimit),
                       .multipart)
        XCTAssertEqual(DriveService.UploadStrategy.suited(
            toByteCount: DriveService.UploadStrategy.multipartLimit + 1), .resumable)
    }

    func testASmallUploadTravelsInOneMultipartRequest() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = DriveTestEnvironment.deterministicBytes(64_000)
        let source = DriveTestEnvironment.writeFile(payload, named: "notes.txt", in: directory)

        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: "newAAA111", name: "notes.txt", parents: [parentID]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)
        let progress = Progress(totalUnitCount: 0)

        let created = try await env.service.upload(fileURL: source, name: "notes.txt",
                                                  parentID: parentID, mimeType: nil,
                                                  progress: progress)
        XCTAssertEqual(created.id, "newAAA111")
        XCTAssertEqual(transport.requestCount, 1, "a small file costs one round trip")
        XCTAssertEqual(transport.path(at: 0), "/upload/drive/v3/files")
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(query["uploadType"], "multipart")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(query["enforceSingleParent"], "true")

        let contentType = transport.header("Content-Type", at: 0) ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary=clouddisk-boundary-"),
                      contentType)
        let metadata = transport.multipartMetadata(at: 0)
        XCTAssertEqual(metadata["name"] as? String, "notes.txt")
        XCTAssertEqual(metadata["parents"] as? [String], [parentID])
        // No mime type was passed, so it came from the .txt extension.
        XCTAssertEqual(metadata["mimeType"] as? String, "text/plain")
        let envelopeSize = transport.body(at: 0)?.count ?? 0
        XCTAssertGreaterThan(envelopeSize, payload.count, "the body is the envelope plus the bytes")
        XCTAssertLessThan(envelopeSize - payload.count, 512,
                          "the envelope framing must not be a meaningful fraction of the upload")
        XCTAssertEqual(progress.totalUnitCount, 64_000)
        XCTAssertEqual(progress.completedUnitCount, 64_000)
    }

    func testAnExplicitMimeTypeOverridesTheExtensionGuess() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DriveTestEnvironment.writeFile(Data("raw".utf8), named: "thing.bin",
                                                   in: directory)
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: "newAAA222", name: "thing.bin"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.upload(fileURL: source, name: "thing.bin", parentID: parentID,
                                        mimeType: "video/mp4")
        XCTAssertEqual(transport.multipartMetadata(at: 0)["mimeType"] as? String, "video/mp4")
    }

    func testALargeUploadOpensASessionAndStreamsEveryChunk() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = DriveService.resumableChunkSize
        let total = chunk * 2 + 5
        let payload = DriveTestEnvironment.deterministicBytes(total)
        let source = DriveTestEnvironment.writeFile(payload, named: "clip.mov", in: directory)

        let sessionURL = "https://www.googleapis.com/upload/drive/v3/files/resumable/AAMf-x7"
        let transport = StubTransport(script: [
            ReplyWith.location(sessionURL),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(chunk - 1)"]),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(2 * chunk - 1)"]),
            .json(DriveJSON.file(id: "bigAAA111", name: "clip.mov", mimeType: "video/quicktime",
                                 size: Int64(total)))
        ])
        let env = DriveTestEnvironment.make(transport: transport)
        let progress = Progress(totalUnitCount: 0)

        let uploaded = try await env.service.upload(fileURL: source, name: "clip.mov",
                                                   parentID: parentID,
                                                   mimeType: "video/quicktime",
                                                   strategy: .resumable, progress: progress)
        XCTAssertEqual(uploaded.size, String(total))

        // One POST, then one PUT per 1 MiB chunk, and the last chunk finalises the session.
        XCTAssertEqual(transport.requestCount, 4)
        XCTAssertEqual(transport.path(at: 0), "/upload/drive/v3/files")
        XCTAssertEqual(transport.queryItems(at: 0)["uploadType"], "resumable")
        XCTAssertEqual(transport.header("X-Upload-Content-Length", at: 0), String(total))
        XCTAssertEqual(transport.header("X-Upload-Content-Type", at: 0), "video/quicktime")
        XCTAssertEqual(transport.header("Content-Type", at: 0), "application/json; charset=UTF-8")
        let metadata = transport.jsonObject(at: 0)
        XCTAssertEqual(metadata["parents"] as? [String], [parentID])
        XCTAssertEqual(metadata["mimeType"] as? String, "video/quicktime")

        XCTAssertEqual(transport.method(at: 1), "PUT")
        XCTAssertEqual(transport.calls[1].request.url?.absoluteString, sessionURL)
        XCTAssertEqual(transport.header("Content-Range", at: 1), "bytes 0-\(chunk - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 2),
                       "bytes \(chunk)-\(2 * chunk - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 3),
                       "bytes \(2 * chunk)-\(total - 1)/\(total)")

        XCTAssertEqual(transport.body(at: 1)?.count, chunk)
        XCTAssertEqual(transport.body(at: 2)?.count, chunk)
        XCTAssertEqual(transport.body(at: 3)?.count, 5)
        XCTAssertEqual(transport.body(at: 2)?.first, UInt8(chunk % 251),
                       "each PUT must carry exactly its own window of the file")
        XCTAssertEqual(progress.completedUnitCount, Int64(total))
    }

    func testAResumableSessionTrustsTheServersAcceptedOffset() async throws {
        // Google answers 308 with what it has *durably* stored, which can be less than what was sent.
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = DriveService.resumableChunkSize
        let total = chunk * 2
        let source = DriveTestEnvironment.writeFile(
            DriveTestEnvironment.deterministicBytes(total), named: "streaming.mp4", in: directory)

        let transport = StubTransport(script: [
            ReplyWith.location("https://example.com/session/1"),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(total / 4 - 1)"]),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(chunk - 1)"]),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(3 * chunk / 2 - 1)"]),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(total - 1)"]),
            .json(DriveJSON.file(id: "bigAAA222", name: "streaming.mp4", size: Int64(total)))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.upload(fileURL: source, name: "streaming.mp4",
                                        parentID: parentID, mimeType: "video/mp4",
                                        strategy: .resumable)

        XCTAssertEqual(transport.header("Content-Range", at: 1), "bytes 0-\(chunk - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 2),
                       "bytes \(total / 4)-\(total / 4 + chunk - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 3),
                       "bytes \(chunk)-\(2 * chunk - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 4),
                       "bytes \(3 * chunk / 2)-\(total - 1)/\(total)")
        XCTAssertEqual(transport.header("Content-Range", at: 5), "bytes */\(total)")
        XCTAssertEqual(transport.requestCount, 6)
    }

    func testAResumableSessionThatStopsMakingProgressIsAbandoned() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = DriveService.resumableChunkSize
        let total = chunk + 5
        let source = DriveTestEnvironment.writeFile(
            DriveTestEnvironment.deterministicBytes(total), named: "stall.bin", in: directory)

        let transport = StubTransport(script: [
            ReplyWith.location("https://example.com/session/2"),
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(chunk - 1)"]),
            // The same acknowledgement again: nothing new was taken.
            .init(statusCode: 308, headers: ["Range": "bytes=0-\(chunk - 1)"])
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.upload(fileURL: source, name: "stall.bin",
                                            parentID: parentID, mimeType: "application/octet-stream",
                                            strategy: .resumable)
            XCTFail("a stalled session must not spin")
        } catch let error as DriveError {
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("no progress"), detail)
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testAZeroByteUploadStillFinalisesItsSession() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DriveTestEnvironment.writeFile(Data(), named: "empty.txt", in: directory)

        let transport = StubTransport(script: [
            ReplyWith.location("https://example.com/session/3"),
            .json(DriveJSON.file(id: "emptyAAA1", name: "empty.txt", size: 0))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let uploaded = try await env.service.upload(fileURL: source, name: "empty.txt",
                                                   parentID: parentID, mimeType: "text/plain",
                                                   strategy: .resumable)
        XCTAssertEqual(uploaded.id, "emptyAAA1")
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(transport.header("X-Upload-Content-Length", at: 0), "0")
        XCTAssertEqual(transport.header("Content-Range", at: 1), "bytes */0")
        XCTAssertEqual(transport.body(at: 1)?.count ?? 0, 0)
    }

    func testAResumableSessionWithoutALocationHeaderFailsImmediately() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DriveTestEnvironment.writeFile(
            DriveTestEnvironment.deterministicBytes(DriveService.resumableChunkSize + 1),
            named: "nolocation.bin", in: directory)

        let transport = StubTransport(script: [.init(statusCode: 200, headers: [:], body: nil)])
        let env = DriveTestEnvironment.make(transport: transport)

        do {
            _ = try await env.service.upload(fileURL: source, name: "nolocation.bin",
                                            parentID: parentID,
                                            mimeType: "application/octet-stream",
                                            strategy: .resumable)
            XCTFail("expected invalidResponse")
        } catch let error as DriveError {
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("Location"), detail)
        }
        XCTAssertEqual(transport.requestCount, 1, "no chunk may be sent without a session")
    }

    func testReplacingContentsPatchesThroughASessionAndKeepsTheID() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("the new contents of the file".utf8)
        let source = DriveTestEnvironment.writeFile(payload, named: "notes.txt", in: directory)

        let transport = StubTransport(script: [
            ReplyWith.location("https://example.com/session/4"),
            .json(DriveJSON.file(id: fileID, name: "notes.txt", size: Int64(payload.count),
                                 version: "rev-8"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let updated = try await env.service.replaceContents(of: fileID, with: source,
                                                           name: "notes.txt")
        XCTAssertEqual(updated.id, fileID, "an in-place edit must not mint a new Drive object")
        XCTAssertEqual(updated.contentVersionToken, "v:rev-8")

        XCTAssertEqual(transport.path(at: 0), "/upload/drive/v3/files/\(fileID)")
        XCTAssertEqual(transport.queryItems(at: 0)["uploadType"], "resumable")
        XCTAssertEqual(transport.header("X-HTTP-Method-Override", at: 0), "PATCH")
        XCTAssertEqual(transport.header("X-Upload-Content-Length", at: 0), String(payload.count))
        // Replacing content sends no parents and no mime type: only the name may change.
        let metadata = transport.jsonObject(at: 0)
        XCTAssertEqual(Set(metadata.keys), ["name"])
        XCTAssertNil(metadata["parents"])
        XCTAssertNil(metadata["mimeType"])

        XCTAssertEqual(transport.header("Content-Range", at: 1),
                       "bytes 0-\(payload.count - 1)/\(payload.count)")
    }

    func testChunkLengthsStayOnTheMultipleOf256KBGridDriveRequires() {
        XCTAssertEqual(DriveService.resumableChunkSize % (256 * 1024), 0)
        XCTAssertGreaterThan(DriveService.resumableChunkSize, 0)
    }

    func testMultipartBodyFramingIsWellFormed() throws {
        let body = try DriveService.multipartBody(
            metadata: ["name": "a.txt"],
            content: Data("hello".utf8),
            mimeType: "text/plain")
        let text = String(data: body, encoding: .utf8) ?? ""
        let boundary = DriveService.multipartBoundary
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=UTF-8\r\n\r\n"))
        XCTAssertTrue(text.contains("\r\nContent-Type: text/plain\r\n\r\nhello\r\n"))
    }

    // MARK: Mutations

    func testCreatingAFolderPinsItToOneParentAndAsksForSingleParentSemantics() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.folder(id: "newAAA999", name: "Field notes", parents: [parentID]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let folder = try await env.service.createFolder(name: "Field notes", parentID: parentID)
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(transport.method(at: 0), "POST")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/files")
        XCTAssertEqual(transport.queryItems(at: 0)["enforceSingleParent"], "true",
                       "File Provider cannot represent an item with two homes")
        let body = transport.jsonObject(at: 0)
        XCTAssertEqual(body["mimeType"] as? String, DriveFile.folderMimeType)
        XCTAssertEqual(body["name"] as? String, "Field notes")
        XCTAssertEqual(body["parents"] as? [String], [parentID])
        XCTAssertEqual(transport.header("Content-Type", at: 0), "application/json; charset=UTF-8")
    }

    func testRenamingSendsOnlyTheName() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: fileID, name: "renamed.txt"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        _ = try await env.service.rename(fileID: fileID, to: "renamed.txt")
        XCTAssertEqual(transport.method(at: 0), "PATCH")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/files/\(fileID)")
        XCTAssertEqual(Set(transport.jsonObject(at: 0).keys), ["name"])
        XCTAssertEqual(transport.queryItems(at: 0)["keepRevisionForever"], "false")
    }

    func testMovingAddsTheNewParentAndRemovesTheOldOneInOneCall() async throws {
        let newParent = "2CsiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upnq"
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: fileID, name: "notes.txt", parents: [newParent]))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let moved = try await env.service.move(fileID: fileID, from: parentID, to: newParent)
        XCTAssertEqual(moved.parentID, newParent)
        XCTAssertEqual(transport.method(at: 0), "PATCH")
        let query = transport.queryItems(at: 0)
        XCTAssertEqual(query["addParents"], newParent)
        XCTAssertEqual(query["removeParents"], parentID)
        XCTAssertEqual(query["enforceSingleParent"], "true")
    }

    func testCopySendsTheTargetParentAndAnOptionalNewName() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: "copyAAA111", name: "notes copy.txt")),
            .json(DriveJSON.file(id: "copyAAA222", name: "notes.txt"))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let named = try await env.service.copy(fileID: fileID, toParentID: parentID,
                                               name: "notes copy.txt")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/files/\(fileID)/copy")
        let body = transport.jsonObject(at: 0)
        XCTAssertEqual(body["name"] as? String, "notes copy.txt")
        XCTAssertEqual(body["parents"] as? [String], [parentID])

        let plain = try await env.service.copy(fileID: fileID, toParentID: parentID, name: nil)
        XCTAssertEqual(plain.id, "copyAAA222")
        XCTAssertNil(transport.jsonObject(at: 1)["name"],
                     "without a name Drive keeps the original")
    }

    func testFinderStyleDeleteTrashesAndNeverDeletesPermanently() async throws {
        let transport = StubTransport(script: [
            .json(["id": fileID, "trashed": false]),
            .json(DriveJSON.file(id: fileID, name: "notes.txt", trashed: true))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        try await env.service.delete(fileID: fileID)
        XCTAssertEqual(transport.method(at: 0), "GET")
        XCTAssertEqual(transport.queryItems(at: 0)["fields"], "id,trashed")
        XCTAssertEqual(transport.method(at: 1), "PATCH")
        XCTAssertEqual(transport.jsonObject(at: 1)["trashed"] as? Bool, true)
        XCTAssertFalse(transport.requests().contains { $0.httpMethod == "DELETE" },
                       "a first delete must be recoverable")
    }

    func testADeleteFromTheTrashRemovesTheObjectForGood() async throws {
        let transport = StubTransport(script: [
            .json(["id": fileID, "trashed": true]), .noContent
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        try await env.service.delete(fileID: fileID)
        XCTAssertEqual(transport.method(at: 1), "DELETE")
        XCTAssertEqual(transport.path(at: 1), "/drive/v3/files/\(fileID)")
        XCTAssertEqual(transport.queryItems(at: 1)["supportsAllDrives"], "true")
    }

    func testRestoringFromTheTrashClearsTheFlag() async throws {
        let transport = StubTransport(script: [
            .json(DriveJSON.file(id: fileID, name: "notes.txt", trashed: false))
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let restored = try await env.service.setTrashed(false, fileID: fileID)
        XCTAssertFalse(restored.isTrashed)
        XCTAssertEqual(transport.jsonObject(at: 0)["trashed"] as? Bool, false)
    }

    func testConflictDetectionComparesTheVersionTheSystemBelievesIn() async throws {
        let current = DriveJSON.file(id: fileID, name: "notes.txt", version: "rev-9",
                                    parents: [parentID])

        let matching = StubTransport(script: [.json(current)])
        let matchEnv = DriveTestEnvironment.make(transport: matching)
        let unchanged = try await matchEnv.service.assertContentUnchanged(
            fileID: fileID, baseContentVersion: Data("v:rev-9".utf8))
        XCTAssertEqual(unchanged.contentVersionToken, "v:rev-9")
        XCTAssertEqual(matching.requestCount, 1)

        let drifted = StubTransport(script: [.json(current)])
        let driftEnv = DriveTestEnvironment.make(transport: drifted)
        do {
            _ = try await driftEnv.service.assertContentUnchanged(
                fileID: fileID, baseContentVersion: Data("v:rev-7".utf8))
            XCTFail("the file changed remotely")
        } catch let error as DriveError {
            guard case .conflict(let detail) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(detail.contains("v:rev-7"), detail)
            XCTAssertTrue(detail.contains("v:rev-9"), detail)
        }

        // A brand-new item has no base version at all, which is not a conflict.
        let fresh = StubTransport(script: [.json(current)])
        let freshEnv = DriveTestEnvironment.make(transport: fresh)
        _ = try await freshEnv.service.assertContentUnchanged(fileID: fileID,
                                                             baseContentVersion: nil)
        XCTAssertEqual(fresh.requestCount, 1)
    }

    func testConflictDetectionFallsBackToChecksumThenTimestamp() {
        let withChecksum = DriveFile(id: "a1aaaaa", name: "x", mimeType: "text/plain",
                                    md5Checksum: "abc123")
        XCTAssertEqual(withChecksum.contentVersionToken, "m:abc123")
        let withTime = DriveFile(id: "a1aaaaa", name: "x", mimeType: "text/plain",
                                 modifiedTime: "2026-10-29T10:00:00Z")
        XCTAssertEqual(withTime.contentVersionToken, "t:2026-10-29T10:00:00Z")
        let bare = DriveFile(id: "a1aaaaa", name: "x", mimeType: "text/plain")
        XCTAssertEqual(bare.contentVersionToken, "t:0")
    }

    func testMetadataVersionChangesWhenTheNameParentStarOrTrashFlagChanges() {
        let base = DriveFile(id: "a1aaaaa", name: "one.txt", mimeType: "text/plain",
                            parents: ["p1"], trashed: false, starred: false)
        let renamed = DriveFile(id: "a1aaaaa", name: "two.txt", mimeType: "text/plain",
                               parents: ["p1"], trashed: false, starred: false)
        let moved = DriveFile(id: "a1aaaaa", name: "one.txt", mimeType: "text/plain",
                             parents: ["p2"], trashed: false, starred: false)
        let starred = DriveFile(id: "a1aaaaa", name: "one.txt", mimeType: "text/plain",
                               parents: ["p1"], trashed: false, starred: true)
        let trashed = DriveFile(id: "a1aaaaa", name: "one.txt", mimeType: "text/plain",
                               parents: ["p1"], trashed: true, starred: false)
        let tokens = [base, renamed, moved, starred, trashed].map(\.metadataVersionToken)
        XCTAssertEqual(Set(tokens).count, 5)
    }

    func testAboutReportsQuotaAndIdentity() async throws {
        let transport = StubTransport(script: [
            .json(["kind": "drive#about",
                   "storageQuota": ["limit": "10737418240", "usage": "5368709120",
                                   "usageInDrive": "5000000000"],
                   "user": ["kind": "drive#user", "displayName": "Test User",
                            "emailAddress": "user@example.com", "me": true]])
        ])
        let env = DriveTestEnvironment.make(transport: transport)

        let about = try await env.service.about()
        XCTAssertEqual(about.storageQuota?.limitBytes, 10_737_418_240)
        XCTAssertEqual(about.storageQuota?.usageInDriveBytes, 5_000_000_000)
        XCTAssertEqual(about.user?.emailAddress, "user@example.com")
        XCTAssertEqual(transport.path(at: 0), "/drive/v3/about")
    }

    func testWorkspaceExportPreferencesCoverTheGoogleNativeTypes() {
        func file(_ mimeType: String, links: [String: String]? = nil) -> DriveFile {
            DriveFile(id: "a1aaaaa", name: "doc", mimeType: mimeType, exportLinks: links)
        }
        XCTAssertEqual(GoogleWorkspaceExport.exportMimeType(
            for: file("application/vnd.google-apps.document")), "application/pdf")
        XCTAssertEqual(GoogleWorkspaceExport.exportMimeType(
            for: file("application/vnd.google-apps.spreadsheet")),
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(GoogleWorkspaceExport.exportMimeType(
            for: file("application/vnd.google-apps.presentation")),
                       "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        // When Drive lists what it can produce, only those formats may be requested.
        XCTAssertEqual(GoogleWorkspaceExport.exportMimeType(
            for: file("application/vnd.google-apps.document",
                      links: ["text/html": "https://example.com/html"])), "text/html")
        XCTAssertEqual(GoogleWorkspaceExport.fileExtension(
            for: file("application/vnd.google-apps.spreadsheet")), "xlsx")
        XCTAssertNil(GoogleWorkspaceExport.exportMimeType(for: file("text/plain")))
    }

    func testExportWritesTheConvertedFile() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("sheet.xlsx")
        let xlsx = Data("PK\u{03}\u{04} fake zip".utf8)
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 200, body: xlsx)
        ])
        let env = DriveTestEnvironment.make(transport: transport)
        let progress = Progress(totalUnitCount: 10)

        try await env.service.export(fileID: "sheetAAA11",
                                    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                    to: destination, progress: progress)
        XCTAssertEqual(try Data(contentsOf: destination), xlsx)
        XCTAssertEqual(progress.completedUnitCount, 10, "a finished export reports itself complete")
        XCTAssertEqual(transport.queryItems(at: 0)["mimeType"],
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    }
}

/// A 200 that only carries a `Location` header, which is how a resumable session starts.
private enum ReplyWith {
    static func location(_ url: String) -> StubTransport.Reply {
        StubTransport.Reply(statusCode: 200, headers: ["Location": url], body: nil)
    }
}

final class MutableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
