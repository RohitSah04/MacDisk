import XCTest
import FileProvider
import UniformTypeIdentifiers
@testable import CloudDiskKit

/// Exercises the File Provider logic without `fileproviderd`.
///
/// The extension's real caller is a system daemon that cannot be driven from a test, so these cases
/// substitute the two observers the daemon would hand the enumerator and a scripted transport for
/// Google. What is proven is CloudDisk's half of the contract: which items are published, which page
/// and anchor tokens come back, which Drive calls a Finder action turns into, and what happens when
/// Drive refuses. Nothing here claims that Finder itself behaves correctly — that needs a signed-in
/// Mac and is recorded as unverified in docs/KNOWN_LIMITATIONS.md.
final class ProviderCoreTests: XCTestCase {

    private static let folderID = "fold00000000000000000000000000001"
    private static let fileID = "file000000000000000000000000000001"
    private static let fileIdentifier = NSFileProviderItemIdentifier("g:" + fileID)
    private static let folderIdentifier = NSFileProviderItemIdentifier("g:" + folderID)

    // MARK: Harness

    private struct Harness {
        let transport: StubTransport
        let services: ProviderServices
        let state: ProviderState
        let core: CloudDiskProviderCore
        let scratch: URL
    }

    /// A script of the same reply repeated, for the cases where Drive keeps paging.
    private func script(_ replies: [StubTransport.Reply], repeated times: Int) -> [StubTransport.Reply] {
        (0..<max(1, times)).flatMap { _ in replies }
    }

    private func harness(_ script: [StubTransport.Reply] = []) -> Harness {
        let transport = StubTransport(script: script)
        let env = DriveTestEnvironment.make(transport: transport)
        let scratch = DriveTestEnvironment.scratchDirectory()
        let state = ProviderState(directory: scratch)
        let services = ProviderServices(config: env.config, drive: env.service, state: state,
                                        manager: nil, cacheTTL: 60)
        return Harness(transport: transport, services: services, state: state,
                       core: CloudDiskProviderCore(services: services), scratch: scratch)
    }

    private func remoteFile(name: String = "notes.txt", size: Int = 1_024,
                            version: String = "rev-1", trashed: Bool? = nil) -> [String: Any] {
        DriveJSON.file(id: Self.fileID, name: name, mimeType: "text/plain",
                       size: Int64(size), version: version, parents: [Self.folderID],
                       trashed: trashed, modifiedTime: "2026-10-29T10:00:00Z")
    }

    // MARK: Metadata

    func testTheVirtualContainersAreAnsweredWithoutReachingGoogle() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let root = try await harness.core.item(for: ProviderIdentity.rootIdentifier)
        XCTAssertEqual(root.itemIdentifier, NSFileProviderItemIdentifier.rootContainer)
        let trash = try await harness.core.item(for: ProviderIdentity.trashIdentifier)
        XCTAssertEqual(trash.itemIdentifier, NSFileProviderItemIdentifier.trashContainer)
        let working = try await harness.core.item(for: ProviderIdentity.workingSetIdentifier)
        XCTAssertEqual(working.itemIdentifier, NSFileProviderItemIdentifier.workingSet)

        XCTAssertEqual(harness.transport.requestCount, 0,
                       "a container the provider synthesizes must not cost a request")
    }

    func testAFileIsFetchedOnceAndReusedWhileThePageIsBeingBuilt() async throws {
        let harness = harness([.json(remoteFile())])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let first = try await harness.core.item(for: Self.fileIdentifier)
        let second = try await harness.core.item(for: Self.fileIdentifier)

        XCTAssertEqual(harness.transport.requestCount, 1,
                       "one Finder click must not fan out into a dozen Drive requests")
        XCTAssertEqual(first.filename, "notes.txt")
        XCTAssertEqual(second.filename, "notes.txt")
        XCTAssertEqual(harness.transport.path(at: 0), "/drive/v3/files/\(Self.fileID)")
    }

    func testAForeignIdentifierIsReportedAsMissingRatherThanRequested() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        do {
            _ = try await harness.core.item(for: NSFileProviderItemIdentifier("com.apple.NSFileProviderFacadeDictionaryIdentifier"))
            XCTFail("an identifier CloudDisk did not mint must not become a Drive request")
        } catch let error as CloudDiskProviderCore.CoreError {
            guard case .unknownIdentifier = error else {
                return XCTFail("expected unknownIdentifier, got \(error)")
            }
            XCTAssertEqual(ProviderErrorMapper.bridge(error).code,
                           NSFileProviderError.Code.noSuchItem.rawValue)
        }
        XCTAssertEqual(harness.transport.requestCount, 0)
    }

    // MARK: Download

    func testFetchingContentsReadsTheMetadataThenTheBytesAndLeavesThemOnDisk() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(4_096)
        let harness = harness([
            .json(remoteFile(size: payload.count)),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Content-Type": "application/octet-stream"],
                                body: payload)
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let progress = Progress(totalUnitCount: 100)
        let content = try await harness.core.fetchContents(for: Self.fileIdentifier,
                                                           requestedVersion: nil, progress: progress)
        defer { try? FileManager.default.removeItem(at: content.url) }

        XCTAssertEqual(try Data(contentsOf: content.url), payload,
                       "the system receives this URL as the file's content")
        XCTAssertEqual(harness.transport.requestCount, 2)
        XCTAssertEqual(harness.transport.queryItems(at: 1)["alt"], "media")
        XCTAssertNotNil(harness.transport.calls.last?.writingResponseTo)
        XCTAssertEqual(content.item.itemIdentifier, Self.fileIdentifier)
        XCTAssertEqual(content.item.documentSize, NSNumber(value: payload.count))

        let activity = await harness.state.recentActivity()
        XCTAssertEqual(activity.first?.kind, .download)
        XCTAssertEqual(activity.first?.outcome, .success)
    }

    func testAFailedDownloadDoesNotLeaveATruncatedFileOrAFakeSuccess() async throws {
        let harness = harness([
            .json(remoteFile(size: 8_192)),
            .googleError(status: 404, reason: "notFound", message: "File not found")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        do {
            _ = try await harness.core.fetchContents(for: Self.fileIdentifier,
                                                     requestedVersion: nil,
                                                     progress: Progress(totalUnitCount: 100))
            XCTFail("a 404 must fail the fetch")
        } catch let error as DriveError {
            guard case .itemNotFound = error else {
                return XCTFail("expected itemNotFound, got \(error)")
            }
        }

        let destination = harness.transport.calls.last?.writingResponseTo
        if let destination {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                           "a partial download must be removed, not handed to the system")
        }
        let activity = await harness.state.recentActivity()
        XCTAssertEqual(activity.first?.outcome, .failure)
        XCTAssertFalse(activity.first?.detail?.contains("cached-access-token") ?? true)
    }

    func testARequestForAVersionDriveHasMovedPastIsRefusedInsteadOfAnsweredWithNewerBytes() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(4_096)
        // Drive holds rev-9; the system asked for the bytes behind rev-1.
        let harness = harness([
            .json(remoteFile(size: payload.count, version: "rev-9")),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Content-Type": "application/octet-stream"],
                                body: payload)
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let requested = ProviderIdentity.itemVersion(for: remoteDriveFile(version: "rev-1"))

        do {
            _ = try await harness.core.fetchContents(for: Self.fileIdentifier,
                                                     requestedVersion: requested,
                                                     progress: Progress(totalUnitCount: 100))
            XCTFail("rev-9 under a rev-1 label replaces what the user was editing with content "
                    + "they never asked for")
        } catch let error as DriveError {
            guard case .versionUnavailable = error else {
                return XCTFail("expected versionUnavailable, got \(error)")
            }
            XCTAssertEqual(ProviderErrorMapper.bridge(error).code,
                           NSFileProviderError.Code.versionNoLongerAvailable.rawValue)
        }

        let destination = harness.transport.calls.last?.writingResponseTo
        if let destination {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                           "the refused bytes must not survive the fetch")
        }
        let activity = await harness.state.recentActivity()
        XCTAssertEqual(activity.first?.outcome, .failure)
    }

    func testARequestedVersionThatStillMatchesTheServerIsServed() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(4_096)
        let harness = harness([
            .json(remoteFile(size: payload.count, version: "rev-1")),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Content-Type": "application/octet-stream"],
                                body: payload)
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let requested = ProviderIdentity.itemVersion(for: remoteDriveFile(version: "rev-1"))

        let content = try await harness.core.fetchContents(for: Self.fileIdentifier,
                                                            requestedVersion: requested,
                                                            progress: Progress(totalUnitCount: 100))
        defer { try? FileManager.default.removeItem(at: content.url) }

        XCTAssertEqual(try Data(contentsOf: content.url), payload)
        XCTAssertEqual(content.item.itemVersion?.contentVersion, requested.contentVersion,
                       "the item published for these bytes must carry the version they were asked for")
    }

    func testAFolderCannotBeDownloadedAndSaysSoBeforeTransferringAnything() async throws {
        let harness = harness([
            .json(DriveJSON.folder(id: Self.folderID, name: "Reports"))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        do {
            _ = try await harness.core.fetchContents(for: Self.folderIdentifier,
                                                     requestedVersion: nil,
                                                     progress: Progress(totalUnitCount: 100))
            XCTFail("a folder has no bytes")
        } catch let error as DriveError {
            guard case .unsupportedItem = error else {
                return XCTFail("expected unsupportedItem, got \(error)")
            }
        }
        XCTAssertEqual(harness.transport.requestCount, 1, "no media request for a folder")
    }

    // MARK: Create

    func testANewFolderBecomesOneDriveRequestAndAnItemInTheRightPlace() async throws {
        let harness = harness([
            .json(DriveJSON.folder(id: "newfolder00000000000000000000001", name: "Reports",
                                   parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000001", name: "Reports",
            mimeType: DriveFile.folderMimeType, parents: [Self.folderID]))

        let outcome = try await harness.core.create(basedOn: template, fields: [.filename],
                                                    contents: nil, options: [],
                                                    progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(outcome.item.itemIdentifier,
                       NSFileProviderItemIdentifier("g:newfolder00000000000000000000001"))
        XCTAssertEqual(harness.transport.method(at: 0), "POST")
        XCTAssertEqual(harness.transport.queryItems(at: 0)["supportsAllDrives"], "true",
                       "writes carry supportsAllDrives; includeItemsFromAllDrives is a read parameter")
        XCTAssertEqual(harness.transport.queryItems(at: 0)["enforceSingleParent"], "true")
        XCTAssertEqual(harness.transport.jsonObject(at: 0)["mimeType"] as? String,
                       DriveFile.folderMimeType)
        XCTAssertEqual(Set((harness.transport.jsonObject(at: 0)["parents"] as? [String]) ?? []),
                       Set([Self.folderID]))
    }

    func testANewFileIsUploadedInTheSameRequestThatNamesIt() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("created on this Mac".utf8)
        let source = DriveTestEnvironment.writeFile(payload, named: "fresh.txt", in: directory)

        let harness = harness([
            .json(DriveJSON.file(id: "newfile0000000000000000000000000001", name: "fresh.txt",
                                 size: Int64(payload.count), version: "rev-1",
                                 parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000002", name: "fresh.txt",
            mimeType: "text/plain", parents: [Self.folderID]))

        let outcome = try await harness.core.create(basedOn: template, fields: [.contents],
                                                   contents: source, options: [],
                                                   progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(harness.transport.requestCount, 1, "a small file is one multipart request")
        XCTAssertEqual(harness.transport.queryItems(at: 0)["uploadType"], "multipart")
        // Multipart carries its metadata inside the request body, not in the query string, so this is
        // the only place the name and the destination folder can be checked.
        let metadata = harness.transport.multipartMetadata(at: 0)
        XCTAssertEqual(metadata["name"] as? String, "fresh.txt")
        XCTAssertEqual(Set((metadata["parents"] as? [String]) ?? []), Set([Self.folderID]))
        XCTAssertEqual(metadata["mimeType"] as? String, "text/plain")
        XCTAssertNotNil(harness.transport.body(at: 0)?.range(of: payload),
                        "the bytes travel in the same request that names the file")
        XCTAssertEqual(outcome.item.filename, "fresh.txt")
        XCTAssertFalse(outcome.shouldFetchContent, "the bytes the system already has are the bytes stored")

        let activity = await harness.state.recentActivity()
        XCTAssertEqual(activity.first?.kind, .upload)
    }

    func testNothingCanBeFiledStraightIntoTheTrash() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000003", name: "x.txt", mimeType: "text/plain"))
        // Force the parent to the trash container the way the system would when dragging into Trash.
        let trashedTemplate = TrashParentTemplate(underlying: template)

        do {
            _ = try await harness.core.create(basedOn: trashedTemplate, fields: [.filename],
                                              contents: nil, options: [],
                                              progress: Progress(totalUnitCount: 100))
            XCTFail("Drive has no way to create an object directly in the trash")
        } catch let error as CloudDiskProviderCore.CoreError {
            guard case .cannotCreateInTrash = error else {
                return XCTFail("expected cannotCreateInTrash, got \(error)")
            }
        }
        XCTAssertEqual(harness.transport.requestCount, 0)
    }

    func testALinkIsRefusedRatherThanStoredAsSomethingFinderCannotUse() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000004", name: "alias",
            mimeType: "application/octet-stream"))
        let linkTemplate = ContentTypeTemplate(underlying: template, type: .symbolicLink)

        do {
            _ = try await harness.core.create(basedOn: linkTemplate, fields: [.contents],
                                              contents: nil, options: [],
                                              progress: Progress(totalUnitCount: 100))
            XCTFail("Drive has no symlink type")
        } catch let error as CloudDiskProviderCore.CoreError {
            guard case .unsupportedKind = error else {
                return XCTFail("expected unsupportedKind, got \(error)")
            }
        }
        XCTAssertEqual(harness.transport.requestCount, 0)
    }

    func testAnEmptyItemReplayedWithoutContentStillBecomesARealObject() async throws {
        let harness = harness([
            .json(DriveJSON.file(id: "newfile0000000000000000000000000001", name: "empty.txt",
                                 size: 0, version: "rev-1"))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000005", name: "empty.txt",
            mimeType: "text/plain", parents: [Self.folderID]))
        _ = try await harness.core.create(basedOn: template, fields: [.contents], contents: nil,
                                         options: [], progress: Progress(totalUnitCount: 100))

        XCTAssertEqual(harness.transport.requestCount, 1)
        XCTAssertEqual(harness.transport.queryItems(at: 0)["uploadType"], "multipart")
    }

    // MARK: Restart and reimport

    func testAFileThatAlreadyExistsRemotelyIsMatchedInsteadOfDuplicated() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = DriveTestEnvironment.deterministicBytes(1_024)
        let source = DriveTestEnvironment.writeFile(payload, named: "notes.txt", in: directory)

        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(size: payload.count)]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000006", name: "notes.txt",
            mimeType: "text/plain", parents: [Self.folderID]))

        let outcome = try await harness.core.create(basedOn: template, fields: [.contents],
                                                   contents: source,
                                                   options: [.mayAlreadyExist],
                                                   progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(outcome.item.itemIdentifier, Self.fileIdentifier,
                       "a replayed disk file must land on the existing Drive object")
        XCTAssertEqual(harness.transport.requestCount, 1,
                       "matching is enough: uploading it again would create a duplicate")
        XCTAssertFalse(outcome.shouldFetchContent,
                       "identical bytes need no re-download after a restart")
    }

    func testALocalEditThatSurvivedARestartIsPushedOntoTheMatchedObject() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let edited = Data("edited offline".utf8)
        let source = DriveTestEnvironment.writeFile(edited, named: "notes.txt", in: directory)

        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(size: 1_024)])),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Location": "https://example.com/resumable/7"], body: nil),
            .json(DriveJSON.file(id: Self.fileID, name: "notes.txt", size: Int64(edited.count),
                                 version: "rev-2", parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let template = DriveFileProviderItem.make(from: DriveFile(
            id: "pending00000000000000000000000007", name: "notes.txt",
            mimeType: "text/plain", parents: [Self.folderID]))

        let outcome = try await harness.core.create(basedOn: template, fields: [.contents],
                                                   contents: source,
                                                   options: [.mayAlreadyExist],
                                                   progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(outcome.item.itemIdentifier, Self.fileIdentifier)
        let returnedVersion = try XCTUnwrap(outcome.item.itemVersion)
        XCTAssertEqual(returnedVersion.contentVersion,
                       ProviderIdentity.itemVersion(for: DriveFile(
                            id: Self.fileID, name: "notes.txt", mimeType: "text/plain",
                            version: "rev-2", parents: [Self.folderID])).contentVersion)
        XCTAssertGreaterThanOrEqual(harness.transport.requestCount, 3,
                       "the local bytes must reach Drive, not be discarded")
    }

    func testImportFinishingEstablishesTheChangesCursorExactlyOnce() async throws {
        let harness = harness([
            .json(["kind": "drive#startPageToken", "startPageToken": "AAAAAAAAMWQ"])
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        await harness.core.importDidFinish()
        let stored = await harness.state.syncCursor()
        XCTAssertEqual(stored, "AAAAAAAAMWQ")
        XCTAssertEqual(harness.transport.requestCount, 1)

        // A second import (a restart) must not re-anchor and lose changes since the first.
        await harness.core.importDidFinish()
        XCTAssertEqual(harness.transport.requestCount, 1)
    }

    // MARK: Modify

    func testARenameIsOneMetadataWriteAndNothingElse() async throws {
        let harness = harness([
            .json(remoteFile(name: "old.txt", version: "rev-1")),
            .json(remoteFile(name: "renamed.txt", version: "rev-1"))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let edited = DriveFileProviderItem.make(from: DriveFile(
            id: Self.fileID, name: "renamed.txt", mimeType: "text/plain",
            parents: [Self.folderID]))
        let base = ProviderIdentity.itemVersion(for: DriveFile(
            id: Self.fileID, name: "old.txt", mimeType: "text/plain", parents: [Self.folderID]))

        let outcome = try await harness.core.modify(edited, baseVersion: base,
                                                    changedFields: [.filename], contents: nil,
                                                    options: [], progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(harness.transport.method(at: 1), "PATCH")
        let patchBody = harness.transport.jsonObject(at: 1)
        XCTAssertEqual(patchBody["name"] as? String, "renamed.txt")
        XCTAssertEqual(Set(patchBody.keys), ["name"], "a rename must not rewrite anything else")
        XCTAssertEqual(outcome.item.filename, "renamed.txt")
        XCTAssertTrue(outcome.pendingFields.isEmpty)
    }

    func testAMoveCarriesBothTheOldAndTheNewParent() async throws {
        let otherFolder = "other0000000000000000000000000001"
        let harness = harness([
            .json(remoteFile()),
            .json(DriveJSON.file(id: Self.fileID, name: "notes.txt", size: 1_024,
                                 version: "rev-1", parents: [otherFolder]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let moved = DriveFileProviderItem.make(from: DriveFile(
            id: Self.fileID, name: "notes.txt", mimeType: "text/plain", parents: [otherFolder]))
        let base = ProviderIdentity.itemVersion(for: remoteDriveFile())

        _ = try await harness.core.modify(moved, baseVersion: base,
                                          changedFields: [.parentItemIdentifier], contents: nil,
                                          options: [], progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(harness.transport.method(at: 1), "PATCH")
        XCTAssertEqual(harness.transport.queryItems(at: 1)["removeParents"], Self.folderID)
        XCTAssertEqual(harness.transport.queryItems(at: 1)["addParents"], otherFolder)
        XCTAssertEqual(harness.transport.queryItems(at: 1)["enforceSingleParent"], "true")
    }

    func testAGoogleDocumentReportsEveryRequestedFieldAsUnappliedInsteadOfFailing() async throws {
        let harness = harness([
            .json(DriveJSON.file(id: Self.fileID, name: "Roadmap",
                                 mimeType: "application/vnd.google-apps.document",
                                 version: "rev-1", parents: [Self.folderID],
                                 exportLinks: ["application/pdf": "https://export/1"]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let edited = DriveFileProviderItem.make(from: DriveFile(
            id: Self.fileID, name: "Roadmap edited",
            mimeType: "application/vnd.google-apps.document", parents: [Self.folderID]))
        let fields: NSFileProviderItemFields = [.filename, .contents]
        let outcome = try await harness.core.modify(edited,
                                                   baseVersion: ProviderIdentity.itemVersion(for: remoteDriveFile()),
                                                   changedFields: fields, contents: nil,
                                                   options: [], progress: Progress(totalUnitCount: 100))

        XCTAssertEqual(outcome.pendingFields, fields,
                       "an unsupported write must be reported, not silently dropped")
        XCTAssertEqual(harness.transport.requestCount, 1, "no upload attempt for a document")
    }

    func testContentThatMatchesTheKnownVersionIsUploadedInPlace() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("edited locally".utf8)
        let source = DriveTestEnvironment.writeFile(payload, named: "notes.txt", in: directory)

        let current = remoteDriveFile()
        let harness = harness([
            .json(remoteFile()),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Location": "https://example.com/resumable/9"], body: nil),
            .json(DriveJSON.file(id: Self.fileID, name: "notes.txt", size: Int64(payload.count),
                                 version: "rev-2", parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let edited = DriveFileProviderItem.make(from: current)
        let outcome = try await harness.core.modify(edited,
                                                   baseVersion: ProviderIdentity.itemVersion(for: current),
                                                   changedFields: [.contents], contents: source,
                                                   options: [], progress: Progress(totalUnitCount: 100))

        XCTAssertEqual(harness.transport.header("X-HTTP-Method-Override", at: 1), "PATCH")
        XCTAssertFalse(outcome.shouldFetchContent, "the server now holds exactly these bytes")
        XCTAssertEqual(outcome.pendingFields, [])
    }

    func testAConflictKeepsBothCopiesInsteadOfChoosingOneAndLosingTheOther() async throws {
        let directory = DriveTestEnvironment.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = Data("written on this Mac".utf8)
        let source = DriveTestEnvironment.writeFile(local, named: "notes.txt", in: directory)

        let current = remoteDriveFile(version: "rev-9")
        // The system's base version describes rev-1 while Drive already holds rev-9.
        let stale = remoteDriveFile(version: "rev-1")
        let harness = harness([
            .json(remoteFile(version: "rev-9")),
            .json(DriveJSON.file(id: "conflict000000000000000000000000001",
                                 name: "notes (conflicted copy).txt", size: Int64(local.count),
                                 version: "rev-1", parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let edited = DriveFileProviderItem.make(from: current)
        let outcome = try await harness.core.modify(
            edited, baseVersion: ProviderIdentity.itemVersion(for: stale),
            changedFields: [.contents], contents: source, options: [],
            progress: Progress(totalUnitCount: 100))

        XCTAssertTrue(outcome.shouldFetchContent,
                      "the remote version won, so the disk copy has to be replaced")
        let uploaded = harness.transport.multipartMetadata(at: 1)
        XCTAssertEqual(uploaded["name"] as? String, "notes (conflicted copy).txt",
                       "the local bytes become a separate file instead of overwriting the server")
        XCTAssertEqual(Set((uploaded["parents"] as? [String]) ?? []), Set([Self.folderID]))
        XCTAssertEqual(harness.transport.path(at: 1), "/upload/drive/v3/files",
                       "the conflict copy is created as a new object, never written over the server's")
        let activity = await harness.state.recentActivity()
        XCTAssertTrue(activity.contains { ($0.detail ?? "").contains("two files") },
                      "the user must be told a second file appeared")
    }

    func testATagDataWriteIsDeclaredPendingBecauseDriveHasNoLabelAPI() async throws {
        let current = remoteDriveFile()
        let harness = harness([.json(remoteFile())])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let edited = DriveFileProviderItem.make(from: current)
        let outcome = try await harness.core.modify(
            edited, baseVersion: ProviderIdentity.itemVersion(for: current),
            changedFields: [.tagData, .creationDate], contents: nil, options: [],
            progress: Progress(totalUnitCount: 100))

        XCTAssertTrue(outcome.pendingFields.contains(.tagData))
        XCTAssertTrue(outcome.pendingFields.contains(.creationDate))
        XCTAssertEqual(harness.transport.requestCount, 1, "nothing writable was requested")
    }

    func testAContentRequestWithNoBytesIsAcknowledgedNotForgotten() async throws {
        let current = remoteDriveFile()
        let harness = harness([.json(remoteFile())])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let outcome = try await harness.core.modify(
            DriveFileProviderItem.make(from: current),
            baseVersion: ProviderIdentity.itemVersion(for: current),
            changedFields: [.contents], contents: nil, options: [],
            progress: Progress(totalUnitCount: 100))
        XCTAssertTrue(outcome.pendingFields.contains(.contents),
                      "the field stays pending so the system can retry rather than believe it synced")
    }

    // MARK: Delete

    func testANonEmptyFolderIsNotDeletedAndSaysWhyWithTheRightCode() async throws {
        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(name: "inside.txt")]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        do {
            try await harness.core.delete(identifier: Self.folderIdentifier,
                                          baseVersion: ProviderIdentity.itemVersion(
                                            for: DriveFile(id: Self.folderID, name: "Reports",
                                                           mimeType: DriveFile.folderMimeType)),
                                          options: [])
            XCTFail("deleting a folder that still holds files must not succeed")
        } catch let error as CloudDiskProviderCore.CoreError {
            guard case .directoryNotEmpty(let name) = error else {
                return XCTFail("expected directoryNotEmpty, got \(error)")
            }
            XCTAssertEqual(name, "inside.txt")
            let bridged = ProviderErrorMapper.bridge(error)
            XCTAssertEqual(bridged.code, NSFileProviderError.Code.directoryNotEmpty.rawValue)
        }
        XCTAssertEqual(harness.transport.requestCount, 1, "no delete call after the check")
    }

    func testAFirstDeleteTrashesRatherThanRemovingForGood() async throws {
        let harness = harness([
            .json(DriveJSON.emptyPage),
            .json(["id": Self.fileID, "trashed": false]),
            .json(remoteFile(trashed: true))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        try await harness.core.delete(identifier: Self.fileIdentifier,
                                      baseVersion: ProviderIdentity.itemVersion(for: remoteDriveFile()),
                                      options: [])
        XCTAssertEqual(harness.transport.method(at: 2), "PATCH",
                       "Finder's Move to Trash must never reach files.delete first")
        XCTAssertEqual(harness.transport.jsonObject(at: 2) as NSDictionary,
                       ["trashed": true] as NSDictionary)
        XCTAssertFalse(harness.transport.requests().contains { $0.httpMethod == "DELETE" })
    }

    func testADeleteFromTheTrashRemovesTheObjectForGood() async throws {
        let harness = harness([
            .json(DriveJSON.emptyPage),
            .json(["id": Self.fileID, "trashed": true]),
            StubTransport.Reply(statusCode: 204, body: nil)
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        try await harness.core.delete(identifier: Self.fileIdentifier,
                                      baseVersion: ProviderIdentity.itemVersion(for: remoteDriveFile()),
                                      options: [])
        XCTAssertEqual(harness.transport.method(at: 2), "DELETE",
                       "a second delete is exactly the case where permanent removal was asked for")
    }

    func testADeleteOfSomethingAlreadyGoneRemotelyIsASuccessNotAnError() async throws {
        let harness = harness([
            .json(DriveJSON.emptyPage),
            .googleError(status: 404, reason: "notFound", message: "File not found")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        // The requested end state holds, so Apple requires the extension to report success.
        try await harness.core.delete(identifier: Self.fileIdentifier,
                                      baseVersion: ProviderIdentity.itemVersion(for: remoteDriveFile()),
                                      options: [])
    }

    // MARK: Enumeration

    func testAFolderWalksEveryPageAndCarriesTheDriveTokenThrough() async throws {
        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(name: "a.txt"), remoteFile(name: "b.txt")],
                                 nextPageToken: "PAGE2")),
            .json(DriveJSON.page(files: [remoteFile(name: "c.txt")]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await warmFolder(harness)

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data(ProviderCursor.initialSortedByName)))
        XCTAssertTrue(observer.waitForFinish())

        XCTAssertEqual(observer.batches.flatMap { $0 }.count, 2)
        XCTAssertEqual(observer.nextPage, ProviderCursor.page(drivePageToken: "PAGE2"),
                       "an unpaged implementation would silently truncate big folders")
    }

    func testTheSecondPageIsRequestedWithTheTokenItWasGiven() async throws {
        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(name: "c.txt")]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await warmFolder(harness)

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer,
                                  startingAt: ProviderCursor.page(drivePageToken: "PAGE2"))
        XCTAssertTrue(observer.waitForFinish())

        XCTAssertNil(observer.nextPage)
        let query = harness.transport.queryItems(at: harness.transport.requestCount - 1)
        XCTAssertEqual(query["pageToken"], "PAGE2")
        XCTAssertEqual(query["orderBy"], "folder,name")
    }

    func testItemsFromTheTrashArePublishedInsideTheTrashContainer() async throws {
        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(name: "gone.txt", trashed: true)]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let enumerator = DriveEnumerator(kind: .trash, services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(observer.waitForFinish())

        let published = try XCTUnwrap(observer.batches.first)
        XCTAssertEqual(published.count, 1)
        let trashedItem = try XCTUnwrap(published.first as? DriveFileProviderItem)
        XCTAssertEqual(trashedItem.parentItemIdentifier,
                       NSFileProviderItemIdentifier.trashContainer)
        XCTAssertTrue(trashedItem.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(trashedItem.capabilities.contains(.allowsTrashing))
    }

    func testATrashedFolderListsTheChildrenDriveTrashedWithIt() async throws {
        let harness = harness([
            .json(DriveJSON.page(files: [remoteFile(name: "inside.txt", trashed: true)]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        // Warm the cache with the folder marked trashed, which is how Finder's item(for:) call leaves it.
        let trashedFolder = DriveFile(id: Self.folderID, name: "2024",
                                      mimeType: DriveFile.folderMimeType, trashed: true)
        await harness.services.cache.store(trashedFolder)

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(observer.waitForFinish())

        let query = harness.transport.queryItems(at: harness.transport.requestCount - 1)
        XCTAssertFalse((query["q"] ?? "").contains("trashed = false"),
                       "Drive trashes descendants with the folder, so the filter that hides them "
                       + "must be lifted or the trash holds an empty folder")
        XCTAssertTrue((query["q"] ?? "").contains(Self.folderID))
    }

    func testAShortcutIsPublishedAsTheObjectItPointsAt() async throws {
        let targetID = "targ000000000000000000000000000001"
        let harness = harness([
            .json(DriveJSON.page(files: [DriveJSON.file(id: "shrt000000000000000000000000000001",
                                                         name: "Q3.docx",
                                                         mimeType: "application/vnd.google-apps.shortcut",
                                                         shortcutTarget: targetID)])),
            .json(DriveJSON.file(id: targetID, name: "Q3 report.docx",
                                 mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                 size: 2_048, parents: [Self.folderID]))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(observer.waitForFinish())

        let published = observer.batches.first ?? []
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.itemIdentifier,
                       NSFileProviderItemIdentifier("g:" + targetID),
                       "a shortcut has no bytes, so the only publishable identity is its target's")
        XCTAssertEqual(published.first?.filename, "Q3 report.docx")
        XCTAssertEqual(harness.transport.requestCount, 2, "the listing plus the target lookup")
    }

    func testAShortcutWhoseTargetCannotBeReadIsStillListed() async throws {
        let targetID = "targ000000000000000000000000000001"
        let harness = harness([
            .json(DriveJSON.page(files: [DriveJSON.file(id: "shrt000000000000000000000000000001",
                                                         name: "Q3.docx",
                                                         mimeType: "application/vnd.google-apps.shortcut",
                                                         shortcutTarget: targetID)])),
            .googleError(status: 404, reason: "notFound", message: "No such target")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(observer.waitForFinish())
        XCTAssertNil(observer.error)

        XCTAssertEqual(observer.batches.first?.count, 1,
                       "hiding a row the user can see on drive.google.com is worse than a row "
                       + "that cannot be opened")
        XCTAssertEqual(observer.batches.first?.first?.itemIdentifier,
                       NSFileProviderItemIdentifier("g:shrt000000000000000000000000000001"))
    }

    func testAnEnumerationFailureIsBridgedToACodeTheSystemActsOn() async throws {
        // The first 401 only proves the access token aged out, so the token layer refreshes and
        // replays; a second 401 with a fresh token is what means "not authenticated".
        let harness = harness([
            .googleError(status: 401, reason: "authExpired", message: "Token expired"),
            .googleError(status: 401, reason: "authExpired", message: "Token expired")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        XCTAssertTrue(observer.waitForFinish())

        let error = try XCTUnwrap(observer.error)
        XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.Code.notAuthenticated.rawValue)
        XCTAssertEqual(harness.transport.requestCount, 2, "one replay after the refresh")
    }

    func testAnInvalidatedEnumeratorStopsTouchingTheObserver() async throws {
        let harness = harness([
            .json(DriveJSON.emptyPage)
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.invalidate()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))

        // The task is cancelled before it can reach an observer the system has already discarded.
        XCTAssertFalse(observer.waitForFinish(timeout: 0.4),
                       "a discarded enumerator must not call back")

        // The change observer is the other half of the same contract.
        let changes = RecordingChangeObserver()
        enumerator.enumerateChanges(for: changes,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertFalse(changes.waitForFinish(timeout: 0.4),
                       "an enumerator discarded between two calls must stay silent for both")
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "nothing may be fetched for an enumeration nobody is waiting for")
    }

    func testAnEnumeratorInvalidatedWhileItsRequestIsInFlightStaysSilent() async throws {
        let harness = harness([.json(DriveJSON.emptyPage)])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))

        // Cancellation cannot interrupt a request already handed to URLSession, so the reply lands
        // after invalidate(). The observer gate is what keeps that reply from becoming a callback.
        let release = DispatchSemaphore(value: 0)
        harness.transport.holdReply = release
        defer { harness.transport.holdReply = nil }

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))

        let deadline = Date().addingTimeInterval(5)
        while harness.transport.requestCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(harness.transport.requestCount, 1,
                       "the test needs the enumerator parked inside a real Drive request")

        enumerator.invalidate()
        release.signal()

        XCTAssertFalse(observer.waitForFinish(timeout: 0.4),
                       "a reply that arrives after invalidate must not reach the discarded observer")
        XCTAssertTrue(observer.batches.isEmpty, "and nothing may have been published on the way out")
    }

    // MARK: Changes

    func testTheCurrentAnchorIsServedFromDiskWithoutAskingGoogleAgain() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setSyncCursor("AAAAAAAAMWQ")

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let anchor: NSFileProviderSyncAnchor? = await withCheckedContinuation { continuation in
            enumerator.currentSyncAnchor { anchor in continuation.resume(returning: anchor) }
        }
        XCTAssertEqual(ProviderCursor.driveStartToken(from: anchor), "AAAAAAAAMWQ")
        XCTAssertEqual(harness.transport.requestCount, 0)
    }

    func testAFirstWorkingSetEnumerationAnchorsAndPublishesNothing() async throws {
        let harness = harness([
            .json(["kind": "drive#startPageToken", "startPageToken": "AAAAAAAAMWQ"])
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(Data()))
        XCTAssertTrue(observer.waitForFinish())

        XCTAssertEqual(observer.updates.flatMap { $0 }.count, 0)
        XCTAssertEqual(observer.anchor.map { ProviderCursor.driveStartToken(from: $0) }, "AAAAAAAAMWQ")
        XCTAssertFalse(observer.moreComing)
        let stored = await harness.state.syncCursor()
        XCTAssertEqual(stored, "AAAAAAAAMWQ")
    }

    func testChangesBecomeUpdatesAndDeletionsAndAdvanceTheStoredCursor() async throws {
        let harness = harness([
            .json(DriveJSON.changesPage(changes: [
                DriveJSON.change(fileId: Self.fileID, file: remoteFile(name: "edited.txt")),
                DriveJSON.change(fileId: "vanis0000000000000000000000000001", removed: true)
            ], newStartPageToken: "AAAAAAAAMW0"))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertTrue(observer.waitForFinish())

        let updated = try XCTUnwrap(observer.updates.first)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].filename, "edited.txt")
        XCTAssertEqual(observer.deletes.flatMap { $0 },
                       [NSFileProviderItemIdentifier("g:vanis0000000000000000000000000001")])
        XCTAssertEqual(observer.anchor.map { ProviderCursor.driveStartToken(from: $0) }, "AAAAAAAAMW0")
        let advanced = await harness.state.syncCursor()
        XCTAssertEqual(advanced, "AAAAAAAAMW0")
    }

    func testAChangeWithoutAFileIsResolvedAndFallsBackToADeletion() async throws {
        let harness = harness([
            .json(DriveJSON.changesPage(changes: [
                DriveJSON.change(fileId: Self.fileID, removed: false)
            ], newStartPageToken: "AAAAAAAAMW1")),
            .json(remoteFile(name: "recovered.txt")),
            .json(DriveJSON.changesPage(changes: [
                DriveJSON.change(fileId: "vanis0000000000000000000000000001", removed: false)
            ], newStartPageToken: "AAAAAAAAMW2")),
            .googleError(status: 404, reason: "notFound", message: "File not found")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)

        let first = RecordingChangeObserver()
        enumerator.enumerateChanges(for: first, from: ProviderCursor.anchor(driveStartToken: "A1"))
        XCTAssertTrue(first.waitForFinish())
        XCTAssertEqual((try XCTUnwrap(first.updates.first).first as? DriveFileProviderItem)?.filename,
                       "recovered.txt")
        XCTAssertEqual(first.deletes.flatMap { $0 }.count, 0)

        let second = RecordingChangeObserver()
        let resume = try XCTUnwrap(first.anchorText)
        enumerator.enumerateChanges(for: second,
                                    from: ProviderCursor.anchor(driveStartToken: resume))
        XCTAssertTrue(second.waitForFinish())
        XCTAssertEqual(second.deletes.flatMap { $0 }.count, 1,
                       "a change whose object is gone must delete the replica, not vanish")
    }

    func testAFullDriveHistoryLossExpiresTheAnchorInsteadOfSilentlyRescanning() async throws {
        let harness = harness([
            .json(DriveJSON.changesPage(changes: [], newStartPageToken: "AAAAAAAAMW9",
                                       removes: true))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setSyncCursor("AAAAAAAAMWQ")

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertTrue(observer.waitForFinish())

        let error = try XCTUnwrap(observer.error)
        XCTAssertEqual(error.code, NSFileProviderError.Code.syncAnchorExpired.rawValue,
                       "only the system can rebuild the replica cheaply, so it has to be told")
        let stored = await harness.state.syncCursor()
        XCTAssertNil(stored, "the dead token is what currentSyncAnchor hands back, so it must go "
                           + "with the anchor or the two sides loop on the same expiry forever")
    }

    func testARejectedChangesTokenFromGoogleExpiresTheAnchorAndDropsTheToken() async throws {
        // The signal Google actually sends when it has dropped history: 410 on the token, not a
        // `removes` flag. Same handling, reached from the other side.
        let harness = harness([
            .googleError(status: 410, reason: "expiredStartPageToken",
                         message: "Specified start page token is invalid")
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setSyncCursor("STALETOKEN")

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "STALETOKEN"))
        XCTAssertTrue(observer.waitForFinish())

        let error = try XCTUnwrap(observer.error)
        XCTAssertEqual(error.code, NSFileProviderError.Code.syncAnchorExpired.rawValue)
        let stored = await harness.state.syncCursor()
        XCTAssertNil(stored, "a token Google refused cannot become tomorrow's anchor")

        // Recovery: the next anchor request asks Google again instead of answering from disk.
        harness.transport.enqueue([.json(["kind": "drive#startPageToken",
                                          "startPageToken": "FRESHTOKEN"])])
        let anchor: NSFileProviderSyncAnchor? = await withCheckedContinuation { continuation in
            enumerator.currentSyncAnchor { resolved in continuation.resume(returning: resolved) }
        }
        XCTAssertEqual(ProviderCursor.driveStartToken(from: anchor), "FRESHTOKEN")
    }

    func testATruncatedChangePageAsksForTheNextBatchWithAResumeToken() async throws {
        // Drive keeps handing out the same nextPageToken while a backlog exists, so a page that is
        // not the last one is what makes the drain stop at the enumerator's page budget.
        let unfinished = DriveJSON.changesPage(changes: [
            DriveJSON.change(fileId: Self.fileID, file: remoteFile(name: "part.txt"))
        ], nextPageToken: "RESUMEH", newStartPageToken: "AAAAAAAAMWZ")
        let harness = harness(script([.json(unfinished)],
                                     repeated: DriveEnumerator.changesPagesPerEnumeration))
        defer { try? FileManager.default.removeItem(at: harness.scratch) }

        let enumerator = DriveEnumerator(kind: .workingSet, services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertTrue(observer.waitForFinish())

        XCTAssertTrue(observer.moreComing, "Google said more changes exist; pretending otherwise freezes sync")
        XCTAssertEqual(observer.anchorText, "RESUMEH",
                       "the anchor must move to where the drain stopped, not stay at the token it began with")
        XCTAssertNil(observer.error)
        let stored = await harness.state.syncCursor()
        XCTAssertNotEqual(stored, "AAAAAAAAMWZ",
                          "a partial drain has not reached the terminal token and must not claim it did")
    }

    func testAFolderEnumeratorReportsOnlyChangesInsideThatFolder() async throws {
        let otherFolder = "other0000000000000000000000000001"
        let harness = harness([
            .json(DriveJSON.changesPage(changes: [
                DriveJSON.change(fileId: Self.fileID, file: remoteFile(name: "mine.txt")),
                DriveJSON.change(fileId: "elsew0000000000000000000000000001",
                                 file: DriveJSON.file(id: "elsew0000000000000000000000000001",
                                                      name: "not mine.txt", parents: [otherFolder]))
            ], newStartPageToken: "AAAAAAAAMW3"))
        ])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setSyncCursor("OLDCURSOR")

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertTrue(observer.waitForFinish())

        let published = try XCTUnwrap(observer.updates.first)
        XCTAssertEqual(published.compactMap { ($0 as? DriveFileProviderItem)?.filename }, ["mine.txt"],
                       "a folder must not be repopulated with another folder's files")
    }

    func testAContainerAlreadyAtTheNewestCursorDoesNotReFetchHistory() async throws {
        let harness = harness()
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setSyncCursor("AAAAAAAAMWQ")

        let enumerator = DriveEnumerator(kind: .container(parentDriveID: Self.folderID),
                                         services: harness.services)
        let observer = RecordingChangeObserver()
        enumerator.enumerateChanges(for: observer,
                                    from: ProviderCursor.anchor(driveStartToken: "AAAAAAAAMWQ"))
        XCTAssertTrue(observer.waitForFinish())

        XCTAssertEqual(harness.transport.requestCount, 0)
        XCTAssertEqual(observer.anchorText, "AAAAAAAAMWQ")
    }

    // MARK: Pinning

    func testAPinnedDriveItemIsTheOneTheSystemIsToldToKeepOnDisk() async throws {
        // One reply per read: unpinning invalidates the cached metadata, so the second item is a
        // fresh Drive answer rather than the pin state the extension remembers.
        let harness = harness([.json(remoteFile()), .json(remoteFile())])
        defer { try? FileManager.default.removeItem(at: harness.scratch) }
        try await harness.state.setPinned(Self.fileID, true)

        let item = try await harness.core.item(for: Self.fileIdentifier)
        XCTAssertEqual(item.contentPolicy, .downloadEagerlyAndKeepDownloaded)

        try await harness.state.setPinned(Self.fileID, false)
        await harness.services.cache.invalidate(Self.fileID)
        let lazy = try await harness.core.item(for: Self.fileIdentifier)
        XCTAssertEqual(lazy.contentPolicy, .downloadLazily)
    }

    // MARK: Helpers

    /// Finder asks for a folder's metadata before listing it, which leaves it in the ten-second
    /// cache. Container tests start from that state so the scripted replies are the list pages.
    private func warmFolder(_ harness: Harness) async {
        await harness.services.cache.store(DriveFile(id: Self.folderID, name: "Reports",
                                                     mimeType: DriveFile.folderMimeType))
    }

    private func remoteDriveFile(name: String = "notes.txt", version: String = "rev-1") -> DriveFile {
        DriveFile(id: Self.fileID, name: name, mimeType: "text/plain", size: "1024",
                  version: version, parents: [Self.folderID],
                  modifiedTime: "2026-10-29T10:00:00Z")
    }
}

/// Overrides only the parent, which is how the system addresses a drag into Trash.
private final class TrashParentTemplate: NSObject, NSFileProviderItem {
    let underlying: any NSFileProviderItem
    init(underlying: any NSFileProviderItem) { self.underlying = underlying }

    var itemIdentifier: NSFileProviderItemIdentifier { underlying.itemIdentifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var filename: String { underlying.filename ?? "" }
    var contentType: UTType { underlying.contentType ?? .data }
    var capabilities: NSFileProviderItemCapabilities { underlying.capabilities ?? [] }
    var itemVersion: NSFileProviderItemVersion {
        underlying.itemVersion ?? NSFileProviderItemVersion(contentVersion: Data(),
                                                            metadataVersion: Data())
    }
}

/// Overrides only the content type, which is how a symlink arrives from disk.
private final class ContentTypeTemplate: NSObject, NSFileProviderItem {
    let underlying: any NSFileProviderItem
    let type: UTType
    init(underlying: any NSFileProviderItem, type: UTType) {
        self.underlying = underlying
        self.type = type
    }

    var itemIdentifier: NSFileProviderItemIdentifier { underlying.itemIdentifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        underlying.parentItemIdentifier ?? .init("ignored")
    }
    var filename: String { underlying.filename ?? "alias" }
    var contentType: UTType { type }
    var capabilities: NSFileProviderItemCapabilities { underlying.capabilities ?? [] }
    var itemVersion: NSFileProviderItemVersion {
        underlying.itemVersion ?? NSFileProviderItemVersion(contentVersion: Data(),
                                                            metadataVersion: Data())
    }
}

/// Stands in for the observer `fileproviderd` would supply.
final class RecordingEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    private let gate = NSLock()
    private var _batches: [[NSFileProviderItem]] = []
    private var _nextPage: NSFileProviderPage?
    private var _error: NSError?
    private var _finished = false
    private let signal = DispatchSemaphore(value: 0)

    var batches: [[NSFileProviderItem]] { gate.withLock { _batches } }
    var nextPage: NSFileProviderPage? { gate.withLock { _nextPage } }
    var error: NSError? { gate.withLock { _error } }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        gate.withLock { _batches.append(updatedItems) }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        gate.withLock {
            _nextPage = nextPage
            _finished = true
        }
        signal.signal()
    }

    func finishEnumeratingWithError(_ error: Error) {
        gate.withLock {
            _error = error as NSError
            _finished = true
        }
        signal.signal()
    }

    @discardableResult
    func waitForFinish(timeout: TimeInterval = 10) -> Bool {
        signal.wait(timeout: .now() + timeout) == .success
    }
}

/// Stands in for the change observer the working-set enumerator publishes to.
final class RecordingChangeObserver: NSObject, NSFileProviderChangeObserver {
    private let gate = NSLock()
    private var _updates: [[NSFileProviderItem]] = []
    private var _deletes: [[NSFileProviderItemIdentifier]] = []
    private var _anchor: NSFileProviderSyncAnchor?
    private var _moreComing = false
    private var _error: NSError?
    private let signal = DispatchSemaphore(value: 0)

    var updates: [[NSFileProviderItem]] { gate.withLock { _updates } }
    var deletes: [[NSFileProviderItemIdentifier]] { gate.withLock { _deletes } }
    var anchor: NSFileProviderSyncAnchor? { gate.withLock { _anchor } }
    var moreComing: Bool { gate.withLock { _moreComing } }
    var error: NSError? { gate.withLock { _error } }

    var anchorText: String? {
        gate.withLock {
            _anchor.flatMap { String(data: $0.rawValue, encoding: .utf8) }
        }
    }

    /// The system's batch hint is an optional Objective-C property. A test double that never answers
    /// it would hide the batching path, so it answers with a size these small feeds can reach.
    var suggestedBatchSize: Int { 2 }

    func didUpdate(_ updatedItems: [NSFileProviderItem]) {
        gate.withLock { _updates.append(updatedItems) }
    }

    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        gate.withLock { _deletes.append(deletedItemIdentifiers) }
    }

    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        gate.withLock {
            _anchor = anchor
            _moreComing = moreComing
        }
        signal.signal()
    }

    func finishEnumeratingWithError(_ error: Error) {
        gate.withLock { _error = error as NSError }
        signal.signal()
    }

    @discardableResult
    func waitForFinish(timeout: TimeInterval = 10) -> Bool {
        signal.wait(timeout: .now() + timeout) == .success
    }
}
