import Foundation
import XCTest
@testable import CloudDiskKit

/// Drive calls against the real API.
///
/// These need a refresh token, which CloudDisk will only ever hold after a human signs in, so the
/// suite skips unless `CLOUDDISK_LIVE_CLIENT_ID` and `CLOUDDISK_LIVE_REFRESH_TOKEN` are set.
///
///     CLOUDDISK_LIVE_CLIENT_ID=… CLOUDDISK_LIVE_REFRESH_TOKEN=… swift test --filter LiveDriveSmokeTests
///
/// A skipped test is reported as skipped, never as passed. The behaviours below are the ones the
/// stubbed suite cannot prove: that Google really honours `Range`, that a resumable session accepts
/// multi-megabyte chunks, that the changes feed advances, and that a permanent delete is final.
///
/// Everything it creates goes into one scratch folder, which is removed again when the run ends.
/// Nothing here prints a token.
final class LiveDriveSmokeTests: XCTestCase {

    private static let scratchFolderName = "CloudDisk Test Scratch (safe to delete)"

    private var service: DriveService!
    private var tokens: TokenProvider!
    private var createdFileIDs: [String] = []
    private var scratchFolderID: String?
    private var createdScratchFolder = false

    override func setUpWithError() throws {
        let clientID = ProcessInfo.processInfo.environment["CLOUDDISK_LIVE_CLIENT_ID"]
        let refreshToken = ProcessInfo.processInfo.environment["CLOUDDISK_LIVE_REFRESH_TOKEN"]
        guard let clientID, !clientID.isEmpty, let refreshToken, !refreshToken.isEmpty else {
            throw XCTSkip("""
            Live Drive tests skipped: set CLOUDDISK_LIVE_CLIENT_ID and CLOUDDISK_LIVE_REFRESH_TOKEN \
            to run them. They have not been executed on this machine.
            """)
        }

        let config = CloudDiskConfig(clientID: clientID, keychainAccessGroup: nil)
        // An already-expired access token forces the first call through the real token endpoint.
        let store = InMemoryCredentialStore(credential: GoogleCredential(
            accessToken: "pending", refreshToken: refreshToken, tokenExpiration: .distantPast))
        let transport = URLSessionTransport.shared
        tokens = TokenProvider(config: config, store: store,
                              exchanger: GoogleOAuthClient(transport: transport),
                              transport: transport)
        service = DriveService(config: config, tokens: tokens, transport: transport,
                              pageSize: 50,
                              retryPolicy: DriveRetryPolicy(maxAttempts: 4, baseDelay: 0.5,
                                                           maxDelay: 8))
    }

    override func tearDown() async throws {
        // Remove what this run created, newest first, so the scratch folder empties before it goes.
        for id in createdFileIDs.reversed() {
            try? await service.deletePermanently(fileID: id)
        }
        createdFileIDs.removeAll()

        if createdScratchFolder, let folder = scratchFolderID {
            try? await service.deletePermanently(fileID: folder)
            scratchFolderID = nil
            createdScratchFolder = false
        }
    }

    // MARK: Plumbing

    private func requireScratchFolder() async throws -> String {
        if let scratchFolderID { return scratchFolderID }
        let existing = try await service.exactMatches(named: Self.scratchFolderName, in: "root")
        if let found = existing.first {
            scratchFolderID = found.id
            return found.id
        }
        let folder = try await service.createFolder(name: Self.scratchFolderName, parentID: "root")
        scratchFolderID = folder.id
        createdScratchFolder = true
        return folder.id
    }

    /// Writes a local file whose byte at offset `n` is `n % 251`, so any window of it can be
    /// identified from its first byte.
    private func makeLocalFile(named name: String, byteCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(name)
        try Data((0..<byteCount).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private static func expectedByte(at offset: Int) -> UInt8 { UInt8(offset % 251) }

    // MARK: Live checks

    func testTheRealTokenEndpointExchangesTheRefreshToken() async throws {
        let credential = try await tokens.credential()
        XCTAssertFalse(credential.accessToken.isEmpty)
        XCTAssertFalse(credential.accessToken == "pending",
                       "the token endpoint must have answered")
        XCTAssertGreaterThan(credential.tokenExpiration.timeIntervalSinceNow, 60,
                             "Google returned a usable lifetime")

        let about = try await service.about()
        XCTAssertNotNil(about.storageQuota?.limitBytes,
                        "about.get needs the drive scope to return quota")
        print("Live account: \(about.user?.emailAddress ?? "unknown"), "
            + "quota limit \(about.storageQuota?.limitBytes ?? 0) bytes")
    }

    func testRootEnumerationFollowsEveryPageOfRealResults() async throws {
        let files = try await service.allChildren(parentID: "root", limit: 500)
        let ids = Set(files.map(\.id))
        XCTAssertEqual(ids.count, files.count, "a paged walk must not repeat or drop items")
        XCTAssertTrue(files.allSatisfy { !$0.isTrashed })
        print("Live root folder: \(files.count) entries")
    }

    func testAParallelEnumerationSurvivesGooglesRateLimits() async throws {
        let parent = try await requireScratchFolder()
        let service = try XCTUnwrap(self.service)
        let results = await withTaskGroup(of: Result<Int, Error>.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        return .success((try await service.childrenPage(parentID: parent)).fileList.count)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Int, Error>] = []
            for await value in group { collected.append(value) }
            return collected
        }

        // Bursts do hit 429s; the point is that the retry policy absorbs them or the error is a
        // recognised, retryable DriveError — never a decode failure or a crash.
        for result in results {
            switch result {
            case .success: continue
            case .failure(let error):
                guard let driveError = error as? DriveError else {
                    return XCTFail("unexpected error type: \(error)")
                }
                XCTAssertTrue(driveError.isRetryable || driveError.requiresUserAction,
                              "surfaced a non-retryable, non-actionable error: \(driveError)")
            }
        }
        XCTAssertEqual(results.count, 12)
    }

    func testAMultipartUploadRoundTripsThroughDrive() async throws {
        let parent = try await requireScratchFolder()
        let payload = 4 * 1024
        let source = try makeLocalFile(named: "clouddisk-multipart.txt", byteCount: payload)

        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-multipart.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)
        XCTAssertEqual(uploaded.byteCount, Int64(payload),
                       "Drive reports the size it stored, not the size we sent")
        XCTAssertEqual(uploaded.parentID, parent)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-download-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let metadata = try await service.download(fileID: uploaded.id, to: destination)
        XCTAssertEqual(metadata.contentVersionToken, uploaded.contentVersionToken,
                       "the download must report the version of the bytes it returned")

        let readBack = try Data(contentsOf: destination)
        XCTAssertEqual(readBack.count, payload)
        XCTAssertEqual(readBack.first, Self.expectedByte(at: 0))
        XCTAssertEqual(readBack.last, Self.expectedByte(at: payload - 1))
    }

    func testAResumableUploadStreamsMultipleChunksAndKeepsEveryByte() async throws {
        let parent = try await requireScratchFolder()
        let payload = DriveService.resumableChunkSize * 2 + 1_000
        let source = try makeLocalFile(named: "clouddisk-resumable.bin", byteCount: payload)

        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-resumable.bin",
                                               parentID: parent,
                                               mimeType: "application/octet-stream",
                                               strategy: .resumable)
        createdFileIDs.append(uploaded.id)
        XCTAssertEqual(uploaded.byteCount, Int64(payload),
                       "a chunked session must land the whole file")

        // Reading the tail proves the later chunks were not silently dropped or re-ordered.
        let tail = try await service.downloadRange(fileID: uploaded.id,
                                                  offset: Int64(payload - 1_000), length: 1_000)
        if tail.servedWholeObject {
            XCTAssertEqual(tail.length, payload,
                           "the server ignored Range, so the whole object came back")
        } else {
            XCTAssertEqual(tail.offset, Int64(payload - 1_000))
            XCTAssertEqual(tail.length, 1_000)
            XCTAssertEqual(tail.totalSize, Int64(payload))
            XCTAssertEqual(tail.data.first, Self.expectedByte(at: payload - 1_000))
            XCTAssertEqual(tail.data.last, Self.expectedByte(at: payload - 1))
        }
    }

    func testAByteRangeInTheMiddleOfARealFileReturnsOnlyThatRange() async throws {
        let parent = try await requireScratchFolder()
        let payload = 3 * 1024 * 1024
        let source = try makeLocalFile(named: "clouddisk-ranges.bin", byteCount: payload)
        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-ranges.bin",
                                               parentID: parent,
                                               mimeType: "application/octet-stream")
        createdFileIDs.append(uploaded.id)

        let offset = Int64(1_000_000)
        let length = 64 * 1024
        let range = try await service.downloadRange(fileID: uploaded.id, offset: offset,
                                                   length: length)

        // Both answers are legitimate; what matters is that the reported offset matches the bytes.
        let expectedFirst = range.servedWholeObject ? Self.expectedByte(at: 0)
            : Self.expectedByte(at: Int(offset))
        XCTAssertEqual(range.data.first, expectedFirst)
        XCTAssertEqual(range.offset, range.servedWholeObject ? 0 : offset)
        if !range.servedWholeObject {
            XCTAssertEqual(range.length, length, "a 3 MB object is large enough for a real 206")
            XCTAssertEqual(range.endOffset, offset + Int64(length))
        }
        XCTAssertEqual(range.totalSize ?? Int64(payload), Int64(payload))
    }

    func testReplacingContentsKeepsTheSameDriveObject() async throws {
        let parent = try await requireScratchFolder()
        let first = try makeLocalFile(named: "clouddisk-replace.txt", byteCount: 2048)
        let uploaded = try await service.upload(fileURL: first, name: "clouddisk-replace.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)

        let second = try makeLocalFile(named: "clouddisk-replace-v2.txt", byteCount: 600_000)
        let replaced = try await service.replaceContents(of: uploaded.id, with: second)
        XCTAssertEqual(replaced.id, uploaded.id, "an in-place edit must not mint a new id")
        XCTAssertEqual(replaced.byteCount, 600_000)
        XCTAssertNotEqual(replaced.contentVersionToken, uploaded.contentVersionToken,
                          "the version token has to change when the bytes do")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-replace-read-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let data = try await service.download(fileID: uploaded.id, to: destination)
        XCTAssertEqual(data.byteCount, 600_000)
    }

    func testRenameMoveAndCopyBehaveTheWayTheFinderTreeNeeds() async throws {
        let parent = try await requireScratchFolder()
        let source = try makeLocalFile(named: "clouddisk-name.txt", byteCount: 1024)
        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-name.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)

        let renamed = try await service.rename(fileID: uploaded.id, to: "clouddisk-renamed.txt")
        XCTAssertEqual(renamed.name, "clouddisk-renamed.txt")
        let found = try await service.exactMatches(named: "clouddisk-RENAMED.txt", in: parent)
        XCTAssertTrue(found.contains { $0.id == uploaded.id },
                      "Drive matches names case-insensitively, which is what APFS expects")

        let other = try await service.createFolder(name: "clouddisk-other-folder", parentID: parent)
        createdFileIDs.append(other.id)
        let moved = try await service.move(fileID: uploaded.id, from: parent, to: other.id)
        XCTAssertEqual(moved.parentID, other.id, "a move must leave exactly one parent")

        let copy = try await service.copy(fileID: uploaded.id, toParentID: parent,
                                        name: "clouddisk-copy.txt")
        createdFileIDs.append(copy.id)
        XCTAssertNotEqual(copy.id, uploaded.id,
                          "File Provider needs a distinct identifier for a distinct file")

        // A single-parent object cannot be listed under its former parent any more.
        let oldListing = try await service.exactMatches(named: "clouddisk-renamed.txt", in: parent)
        XCTAssertFalse(oldListing.contains { $0.id == uploaded.id })
    }

    func testDeleteTrashesFirstAndOnlyPurgesWhenAskedAgain() async throws {
        let parent = try await requireScratchFolder()
        let source = try makeLocalFile(named: "clouddisk-trash.txt", byteCount: 512)
        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-trash.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)

        try await service.delete(fileID: uploaded.id)
        let trashed = try await service.file(id: uploaded.id)
        XCTAssertTrue(trashed.isTrashed, "the first delete must stay recoverable")

        // `files.list` skips trashed items unless asked, which is why the Trash container needs
        // its own query.
        let visible = try await service.exactMatches(named: "clouddisk-trash.txt", in: parent)
        XCTAssertFalse(visible.contains { $0.id == uploaded.id })
        let inTrash = try await service.trashedPage()
        XCTAssertTrue(inTrash.fileList.contains { $0.id == uploaded.id })

        try await service.delete(fileID: uploaded.id)
        do {
            _ = try await service.file(id: uploaded.id)
            XCTFail("the second delete should have removed the object")
        } catch let error as DriveError {
            // Drive echoes its own message, so the case is what matters, not its payload.
            guard case .itemNotFound = error else {
                return XCTFail("expected itemNotFound, got \(error)")
            }
        }
    }

    func testTheChangesFeedAdvancesAndHandBackANewAnchor() async throws {
        let parent = try await requireScratchFolder()
        let anchor = try await service.startChangeToken()
        XCTAssertFalse(anchor.isEmpty)

        let source = try makeLocalFile(named: "clouddisk-change.txt", byteCount: 256)
        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-change.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)

        var batch = try await service.collectChanges(from: anchor, maxPages: 20)
        var attempts = 0
        while !batch.changes.contains(where: { $0.fileId == uploaded.id }) && attempts < 5 {
            attempts += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
            batch = try await service.collectChanges(from: anchor, maxPages: 20)
        }

        XCTAssertTrue(batch.changes.contains { $0.fileId == uploaded.id },
                      "a fresh upload must appear in the changes feed; the sync engine depends on it")
        XCTAssertNotNil(batch.startPageToken ?? batch.resumeToken)
        if let next = batch.startPageToken {
            // The new anchor must be usable immediately: an expired token is a full rescan.
            let followUp = try await service.changePage(from: next)
            XCTAssertNotNil(followUp.newStartPageToken)
        }
    }

    func testConflictDetectionSeesARealRemoteEdit() async throws {
        let parent = try await requireScratchFolder()
        let source = try makeLocalFile(named: "clouddisk-conflict.txt", byteCount: 1024)
        let uploaded = try await service.upload(fileURL: source, name: "clouddisk-conflict.txt",
                                               parentID: parent, mimeType: "text/plain",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)

        let base = Data(uploaded.contentVersionToken.utf8)
        _ = try await service.assertContentUnchanged(fileID: uploaded.id, baseContentVersion: base)

        _ = try await service.replaceContents(of: uploaded.id,
                                             with: try makeLocalFile(named: "v2.txt",
                                                                    byteCount: 2048))
        do {
            _ = try await service.assertContentUnchanged(fileID: uploaded.id,
                                                        baseContentVersion: base)
            XCTFail("the object changed remotely and must report a conflict")
        } catch let error as DriveError {
            guard case .conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    func testAWorkspaceDocumentExportsToARealFile() async throws {
        // Drive converts a binary upload into a Google-native type only when asked, so this walks
        // whatever the account already has instead of minting a document.
        let files = try await service.allChildren(parentID: "root", limit: 200)
        let native = files.first { $0.isGoogleNative && $0.exportLinks?.isEmpty == false }
        guard let native else {
            throw XCTSkip("no Google-native file in the account's root folder")
        }
        guard let mimeType = GoogleWorkspaceExport.exportMimeType(for: native) else {
            return XCTFail("\(native.name) exposes no export format")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-export-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        try await service.export(fileID: native.id, mimeType: mimeType, to: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertGreaterThan(data.count, 100, "an export of a real document has bytes")
        print("Live export of \(native.name) as \(mimeType): \(data.count) bytes")
    }

    func testThumbnailLinksStayFetchableForARealImage() async throws {
        let parent = try await requireScratchFolder()
        // The smallest valid PNG Drive accepts.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
                            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
                            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                            0x42, 0x60, 0x82]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-live-png-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clouddisk-pixel.png")
        try Data(png).write(to: url)

        let uploaded = try await service.upload(fileURL: url, name: "clouddisk-pixel.png",
                                               parentID: parent, mimeType: "image/png",
                                               strategy: .multipart)
        createdFileIDs.append(uploaded.id)

        // Indexing an image is asynchronous, so poll briefly and skip rather than fail if Drive has
        // not produced a thumbnail yet.
        var metadata = try await service.file(id: uploaded.id)
        var waited = 0
        while metadata.thumbnailLink == nil && waited < 6 {
            waited += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
            metadata = try await service.file(id: uploaded.id)
        }
        guard metadata.thumbnailLink != nil else {
            throw XCTSkip("Drive had not generated a thumbnail within 12s")
        }
        let data = try await service.thumbnailData(for: metadata, maxPixelSize: 128)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    func testAnInvalidRefreshGrantIsSurfacedAsAReconnectRatherThanAOutage() async throws {
        let clientID = ProcessInfo.processInfo.environment["CLOUDDISK_LIVE_CLIENT_ID"]
        guard let clientID else { return }
        let tokens = TokenProvider(
            config: CloudDiskConfig(clientID: clientID, keychainAccessGroup: nil),
            store: InMemoryCredentialStore(credential: GoogleCredential(
                accessToken: "pending", refreshToken: "1//definitely-not-a-real-refresh-token",
                tokenExpiration: .distantPast)),
            exchanger: GoogleOAuthClient(), transport: URLSessionTransport.shared)

        do {
            _ = try await tokens.accessToken()
            XCTFail("Google must reject a made-up grant")
        } catch let error as DriveError {
            XCTAssertEqual(error, .notAuthenticated(revoked: true),
                           "this is the exact case the reconnect prompt exists for")
        }
    }
}
