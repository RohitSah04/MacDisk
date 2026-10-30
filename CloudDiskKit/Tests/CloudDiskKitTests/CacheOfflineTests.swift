import XCTest
import FileProvider
@testable import CloudDiskKit

/// Cache and offline tests.
///
/// Every case here drives a scripted `CacheSystem`, because the questions CloudDisk asks about its own
/// cache — what is materialized, where it lives, will the system give it back — are answered by
/// `fileproviderd`, which a unit test cannot run. What *is* under test is everything CloudDisk does
/// with those answers: the arithmetic over real files on real disk, which items are offered for
/// eviction, how each refusal is named, and what a pin promises.
///
/// `FileProviderCacheSystem` itself is deliberately not covered here. Its two read calls were
/// exercised once by the running app against its own mounted domain — which is how the mount point
/// being counted as cached content was caught — but its eviction, download and signal calls are only
/// ever scripted, and `docs/KNOWN_LIMITATIONS.md` says so per call.
final class CacheOfflineTests: XCTestCase {

    private var stateDirectory: URL!
    private var scratch: URL!
    private var state: ProviderState!
    private var cache: ScriptedCacheSystem!
    private var store: OfflineStore!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-cache-state-\(UUID().uuidString)", isDirectory: true)
        scratch = DriveTestEnvironment.scratchDirectory()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        state = ProviderState(directory: stateDirectory)
        cache = ScriptedCacheSystem()
        store = OfflineStore(state: state, cacheSystem: cache)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    /// A materialized row for a Drive object, addressed the way the provider addresses it.
    private func row(_ driveID: String, named name: String, folder: Bool = false,
                     declared: Int64? = nil) -> MaterializedEntry {
        MaterializedEntry(identifier: ProviderIdentity.identifier(forDriveID: driveID),
                          name: name, driveID: driveID, isFolder: folder, declaredBytes: declared)
    }

    /// A file of exactly `bytes` logical bytes on disk, so allocated size can be compared with truth.
    @discardableResult
    private func file(_ driveID: String, named name: String, bytes: Int) throws -> URL {
        let url = DriveTestEnvironment.writeFile(
            DriveTestEnvironment.deterministicBytes(bytes), named: name, in: scratch)
        cache.point(ProviderIdentity.identifier(forDriveID: driveID), at: url)
        return url
    }

    private func directory(named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func allocated(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    private func identifier(_ driveID: String) -> NSFileProviderItemIdentifier {
        ProviderIdentity.identifier(forDriveID: driveID)
    }

    /// The pin set, read through the same shared state the File Provider extension uses.
    private func pins() async -> Set<String> { await state.pinnedDriveIDs() }

    /// The newest activity line of one kind, or a failure naming what the log actually holds.
    private func activity(_ kind: ProviderState.ActivityEvent.Kind
                         ) async throws -> ProviderState.ActivityEvent {
        let events = await state.recentActivity()
        return try XCTUnwrap(events.first { $0.kind == kind },
                             "Expected a \(kind.rawValue) line; the log holds \(events.map(\.kind))")
    }

    // MARK: Measurement

    func testInventoryMeasuresTheDiskAndNeverTheDeclaredSize() async throws {
        let url = try file("F1", named: "notes.txt", bytes: 4_096)
        cache.load([row("F1", named: "notes.txt", declared: 5_000_000)])

        let inventory = try await store.inventory()
        let item = try XCTUnwrap(inventory.items.first)

        XCTAssertEqual(inventory.fileCount, 1)
        XCTAssertEqual(item.declaredBytes ?? 0, 5_000_000)
        XCTAssertEqual(item.allocatedBytes ?? 0, try allocated(url))
        XCTAssertEqual(inventory.materializedBytes, try allocated(url))
        // The whole point: a declared size of 5 MB must not become a 5 MB cache figure.
        XCTAssertLessThan(inventory.materializedBytes, 1_000_000)
        XCTAssertTrue(inventory.isExact)
    }

    /// Found by running the app against a real mounted domain: an empty CloudDisk folder still reports
    /// its own mount point as a materialized item, so a cache of nothing read as "Zero KB in 0 files
    /// across 1 folder".
    func testInventoryIgnoresTheMountPointAndTheVirtualNamespaces() async throws {
        let url = try file("F1", named: "notes.txt", bytes: 4_096)
        cache.load([
            MaterializedEntry(identifier: .rootContainer, name: "CloudDisk",
                              driveID: ProviderIdentity.driveRootID, isFolder: true, declaredBytes: nil),
            MaterializedEntry(identifier: .trashContainer, name: "Trash",
                              driveID: nil, isFolder: true, declaredBytes: nil),
            MaterializedEntry(identifier: .workingSet, name: "Recent",
                              driveID: nil, isFolder: true, declaredBytes: nil),
            row("F1", named: "notes.txt"),
        ])

        let inventory = try await store.inventory()

        XCTAssertEqual(inventory.items.count, 1)
        XCTAssertEqual(inventory.fileCount, 1)
        XCTAssertEqual(inventory.folderCount, 0, "the mount point is not a folder the user downloaded")
        XCTAssertEqual(inventory.materializedBytes, try allocated(url))
    }

    func testInventorySplitsPinnedBytesFromEvictableBytes() async throws {
        let kept = try file("F1", named: "movie.mp4", bytes: 32_768)
        let loose = try file("F2", named: "scratch.txt", bytes: 1_024)
        cache.load([row("F1", named: "movie.mp4"), row("F2", named: "scratch.txt")])
        try await state.setPinned("F1", true)

        let inventory = try await store.inventory()

        XCTAssertEqual(inventory.pinnedCount, 1)
        XCTAssertEqual(inventory.materializedBytes, try allocated(kept) + allocated(loose))
        XCTAssertEqual(inventory.pinnedBytes, try allocated(kept))
        XCTAssertEqual(inventory.evictableBytes, try allocated(loose))
        XCTAssertEqual(inventory.evictableCount, 1)
    }

    func testAFoldersOwnBlocksAreNotCountedAsCachedContent() async throws {
        let folder = try directory(named: "Photos")
        cache.point(identifier("D1"), at: folder)
        let inside = try file("F1", named: "one.txt", bytes: 2_048)
        cache.load([row("D1", named: "Photos", folder: true), row("F1", named: "one.txt")])

        let inventory = try await store.inventory()

        XCTAssertEqual(inventory.folderCount, 1)
        XCTAssertEqual(inventory.fileCount, 1)
        XCTAssertNil(inventory.items.first { $0.driveID == "D1" }?.allocatedBytes)
        XCTAssertEqual(inventory.materializedBytes, try allocated(inside))
    }

    func testTheDiskWinsWhenTheSystemCallsADirectoryAFile() async throws {
        let folder = try directory(named: "ReallyAFolder")
        cache.point(identifier("D1"), at: folder)
        // The row claims a file; the path is a directory. Counting its blocks as downloaded content
        // would invent bytes the user never fetched.
        cache.load([row("D1", named: "ReallyAFolder", declared: 16_384)])

        let inventory = try await store.inventory()

        XCTAssertEqual(inventory.folderCount, 1)
        XCTAssertEqual(inventory.fileCount, 0)
        XCTAssertEqual(inventory.materializedBytes, 0)
        XCTAssertEqual(inventory.unmeasuredFileCount, 0)
    }

    func testItemsWithNoPathAreReportedAsUnmeasuredNotAsZeroBytes() async throws {
        let gone = try file("F1", named: "vanished.txt", bytes: 4_096)
        try FileManager.default.removeItem(at: gone)
        cache.load([row("F1", named: "vanished.txt"), row("F2", named: "no-path.txt")])

        let inventory = try await store.inventory()

        XCTAssertEqual(inventory.items.count, 2)
        XCTAssertEqual(inventory.unmeasuredFileCount, 2)
        XCTAssertFalse(inventory.isExact)
        XCTAssertEqual(inventory.materializedBytes, 0)
        // Worth clearing anyway: no bytes could be named, but the files are on disk and unpinless.
        XCTAssertEqual(inventory.evictableCount, 2)
    }

    func testPinsAreReadFromSharedStateOnEveryInventory() async throws {
        try file("F1", named: "a.txt", bytes: 1_024)
        cache.load([row("F1", named: "a.txt")])

        let before = try await store.inventory()
        // A second instance over the same directory stands in for the File Provider extension.
        try await ProviderState(directory: stateDirectory).setPinned("F1", true)
        let after = try await store.inventory()

        XCTAssertEqual(before.items.first?.isPinned, false)
        XCTAssertEqual(after.items.first?.isPinned, true)
        XCTAssertEqual(after.evictableBytes, 0)
    }

    func testAnUnreachableDomainThrowsInsteadOfReportingAnEmptyCache() async throws {
        let offline = OfflineStore(state: state, cacheSystem: UnavailableCacheSystem())

        do {
            _ = try await offline.inventory()
            XCTFail("An unmounted domain must not answer with a zero-byte cache.")
        } catch let error as CacheSystemError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("Expected .unavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("not registered"))
        }
    }

    func testAPartialEnumerationIsRefusedRatherThanReportedAsTheTotal() async throws {
        cache.failInventory(CacheSystemError.enumerationIncomplete(pages: 500))

        do {
            _ = try await store.inventory()
            XCTFail("A truncated inventory must not become a size figure.")
        } catch let error as CacheSystemError {
            XCTAssertEqual(error, .enumerationIncomplete(pages: 500))
            XCTAssertTrue(try XCTUnwrap(error.errorDescription).contains("only the part that was read"))
        }
    }

    // MARK: Release

    func testClearingFreesUnpinnedFilesAndNeverOffersThePinnedOne() async throws {
        let kept = try file("F1", named: "keep.txt", bytes: 8_192)
        let loose = try file("F2", named: "free.txt", bytes: 4_096)
        cache.load([row("F1", named: "keep.txt"), row("F2", named: "free.txt")])
        try await state.setPinned("F1", true)

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.scanned, 2)
        XCTAssertEqual(report.released.map(\.name), ["free.txt"])
        XCTAssertEqual(report.freedBytes, try allocated(loose))
        XCTAssertLessThan(report.freedBytes, try allocated(kept) + allocated(loose))
        XCTAssertEqual(report.keptCount(.pinned), 1)
        XCTAssertEqual(report.kept.first?.name, "keep.txt")
        // Offering a pinned item would abort eviction for every sibling in its folder.
        XCTAssertEqual(cache.evictedIdentifiers, [identifier("F2").rawValue])
    }

    func testFoldersAreNeverOfferedForEviction() async throws {
        let folder = try directory(named: "Tree")
        cache.point(identifier("D1"), at: folder)
        cache.load([row("D1", named: "Tree", folder: true)])

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.scanned, 0)
        XCTAssertTrue(cache.evictedIdentifiers.isEmpty)
    }

    func testEachSystemRefusalIsNamedForTheUser() async throws {
        struct Refusal { let driveID: String; let error: Error; let expected: EvictionRefusal }
        let cases: [Refusal] = [
            Refusal(driveID: "F1",
                    error: NSError(domain: NSFileProviderErrorDomain,
                                   code: NSFileProviderError.Code.nonEvictable.rawValue),
                    expected: .nonEvictable),
            Refusal(driveID: "F2",
                    error: NSError(domain: NSFileProviderErrorDomain,
                                   code: NSFileProviderError.Code.unsyncedEdits.rawValue),
                    expected: .unsyncedEdits),
            Refusal(driveID: "F3",
                    error: NSError(domain: NSFileProviderErrorDomain,
                                   code: NSFileProviderError.Code.noSuchItem.rawValue),
                    expected: .absent),
            Refusal(driveID: "F4",
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
                    expected: .inUse),
        ]
        var entries: [MaterializedEntry] = []
        for case let refusal in cases {
            try file(refusal.driveID, named: "\(refusal.driveID).txt", bytes: 4_096)
            cache.refuseEviction(identifier(refusal.driveID), with: refusal.error)
            entries.append(row(refusal.driveID, named: "\(refusal.driveID).txt"))
        }
        cache.load(entries)

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.scanned, 4)
        XCTAssertTrue(report.released.isEmpty)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.kept.map(\.refusal), cases.map(\.expected))
        XCTAssertTrue(report.failures.isEmpty)
        for kept in report.kept {
            XCTAssertFalse(kept.refusal.sentence.isEmpty)
        }
    }

    func testAnUnexpectedErrorIsAFailureAndNotARefusal() async throws {
        try file("F1", named: "stuck.txt", bytes: 4_096)
        cache.refuseEviction(identifier("F1"),
                             with: NSError(domain: NSCocoaErrorDomain, code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "disk busy"]))
        cache.load([row("F1", named: "stuck.txt")])

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.released.count, 0)
        XCTAssertEqual(report.kept.count, 0)
        XCTAssertEqual(report.failures.map(\.name), ["stuck.txt"])
        XCTAssertEqual(report.failures.first?.reason, "disk busy")
    }

    func testClearingReleasesTheRestEvenAfterOneItemRefuses() async throws {
        try file("F1", named: "open.txt", bytes: 4_096)
        try file("F2", named: "closed.txt", bytes: 4_096)
        cache.refuseEviction(identifier("F1"),
                             with: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)))
        cache.load([row("F1", named: "open.txt"), row("F2", named: "closed.txt")])

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.keptCount(.inUse), 1)
        XCTAssertEqual(report.released.map(\.name), ["closed.txt"])
        XCTAssertEqual(cache.evictedIdentifiers, [identifier("F1").rawValue,
                                                  identifier("F2").rawValue])
    }

    func testReleasedBytesWithoutAMeasurablePathAreCountedAsUnmeasured() async throws {
        // In the materialized set, but the system cannot name the file any more.
        cache.load([row("F1", named: "ghost.txt")])

        let report = try await store.releaseEligibleItems()

        XCTAssertEqual(report.released.map(\.name), ["ghost.txt"])
        XCTAssertNil(report.released.first?.bytes)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.unmeasuredReleasedCount, 1)
    }

    func testReleasingOneNamedItemTouchesOnlyThatItem() async throws {
        let target = try file("F1", named: "big.mov", bytes: 16_384)
        try file("F2", named: "other.mov", bytes: 16_384)
        cache.load([row("F1", named: "big.mov"), row("F2", named: "other.mov")])

        let report = try await store.release(driveID: "F1", name: "big.mov")

        XCTAssertEqual(cache.evictedIdentifiers, [identifier("F1").rawValue])
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.freedBytes, try allocated(target))
    }

    func testEvictionWritesOneActivityLineThatSaysWhatHappened() async throws {
        try file("F1", named: "keep.txt", bytes: 4_096)
        try file("F2", named: "free.txt", bytes: 4_096)
        try await state.setPinned("F1", true)
        cache.load([row("F1", named: "keep.txt"), row("F2", named: "free.txt")])

        _ = try await store.releaseEligibleItems()

        let events = await state.recentActivity()
        let line = try XCTUnwrap(events.first { $0.kind == .synchronize })
        XCTAssertEqual(line.subject, "Local cache")
        XCTAssertEqual(line.outcome, .success)
        XCTAssertEqual(line.detail, "Freed 1 of 2 cached files; kept 1")
    }

    func testAnEvictionThatFailedIsLoggedAsAFailure() async throws {
        try file("F1", named: "free.txt", bytes: 4_096)
        cache.refuseEviction(identifier("F1"),
                             with: NSError(domain: NSCocoaErrorDomain, code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "no such process"]))
        cache.load([row("F1", named: "free.txt")])

        _ = try await store.releaseEligibleItems()

        let line = try await activity(.synchronize)
        XCTAssertEqual(line.outcome, .failure)
        XCTAssertEqual(line.detail, "Freed 0 of 1 cached files; 1 failed")
    }

    func testNothingToFreeWritesNoActivityLine() async throws {
        _ = try await store.releaseEligibleItems()
        let events = await state.recentActivity()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Pinning

    private func driveFile(_ id: String, named name: String, parent: String? = "P1",
                           trashed: Bool? = nil) -> DriveFile {
        DriveFile(id: id, name: name, mimeType: "text/plain", parents: parent.map { [$0] },
                  trashed: trashed)
    }

    func testPinningPublishesThePolicyAndStartsTheDownload() async throws {
        let file = driveFile("F1", named: "trip.pdf", parent: "P1")

        let outcome = await store.setPinned(file, pinned: true)

        XCTAssertEqual(outcome.effect, .downloadScheduled)
        XCTAssertTrue(outcome.succeeded)
        let readback = await pins()
        XCTAssertEqual(readback, ["F1"])
        // The container is signalled so the new content policy reaches the disk replica, and the
        // item itself is asked for by identifier.
        XCTAssertEqual(cache.signalIdentifiers, [identifier("P1").rawValue])
        XCTAssertEqual(cache.downloadIdentifiers, [identifier("F1").rawValue])

        let line = try await activity(.pin)
        XCTAssertEqual(line.outcome, .success)
        XCTAssertEqual(line.subject, "trip.pdf")
        XCTAssertEqual(line.detail, "Downloading now; kept offline afterwards")
    }

    func testPinningTrashedItemsSignalsTrashRatherThanTheOldParent() async throws {
        let file = driveFile("F1", named: "gone.txt", parent: "P1", trashed: true)

        _ = await store.setPinned(file, pinned: true)

        XCTAssertEqual(cache.signalIdentifiers,
                       [NSFileProviderItemIdentifier.trashContainer.rawValue])
    }

    func testPinningBeforeFinderListsTheItemDefersTheDownload() async throws {
        cache.refuseDownload(identifier("F1"),
                             with: NSError(domain: NSFileProviderErrorDomain,
                                           code: NSFileProviderError.Code.noSuchItem.rawValue))
        let outcome = await store.setPinned(driveFile("F1", named: "new.txt"), pinned: true)

        XCTAssertEqual(outcome.effect, .downloadDeferred)
        XCTAssertTrue(outcome.succeeded)
        let readback = await pins()
        XCTAssertEqual(readback, ["F1"])
        let line = try await activity(.pin)
        XCTAssertEqual(line.outcome, .success)
    }

    func testARefusedDownloadKeepsTheMarkButSaysSo() async throws {
        cache.refuseDownload(identifier("F1"),
                             with: NSError(domain: NSFileProviderErrorDomain,
                                           code: NSFileProviderError.Code.notAuthenticated.rawValue,
                                           userInfo: [NSLocalizedDescriptionKey: "Signed out"]))

        let outcome = await store.setPinned(driveFile("F1", named: "video.mp4"), pinned: true)

        XCTAssertEqual(outcome.effect, .refused("Signed out"))
        XCTAssertFalse(outcome.succeeded)
        // The mark is still persisted: the next enumeration should publish it.
        let readback = await pins()
        XCTAssertEqual(readback, ["F1"])
        let line = try await activity(.pin)
        XCTAssertEqual(line.outcome, .failure)
        XCTAssertEqual(line.detail, "Signed out")
    }

    func testUnpinningNeverRequestsADownload() async throws {
        try await state.setPinned("F1", true)

        let outcome = await store.setPinned(driveFile("F1", named: "video.mp4"), pinned: false)

        XCTAssertEqual(outcome.effect, .policyPublished)
        XCTAssertTrue(outcome.succeeded)
        let readback = await pins()
        XCTAssertTrue(readback.isEmpty)
        XCTAssertTrue(cache.downloadIdentifiers.isEmpty)
        XCTAssertEqual(cache.signalIdentifiers, [identifier("P1").rawValue])
        let line = try await activity(.unpin)
        XCTAssertEqual(line.outcome, .success)
        XCTAssertEqual(line.detail, "No longer kept offline; the copy on disk can be freed")
    }

    func testAPinThatCannotBeWrittenIsNotReportedAsPinned() async throws {
        // Block the shared write the way a full or unwritable App Group container would.
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("pinned-items.json.writing"),
            withIntermediateDirectories: true)

        let outcome = await store.setPinned(driveFile("F1", named: "taxes.pdf"), pinned: true)

        XCTAssertFalse(outcome.succeeded)
        guard case .systemUnavailable = outcome.effect else {
            return XCTFail("Expected .systemUnavailable, got \(outcome.effect)")
        }
        let readback = await pins()
        XCTAssertTrue(readback.isEmpty)
        // Nothing downstream was claimed, because nothing was decided.
        XCTAssertTrue(cache.signalIdentifiers.isEmpty)
        XCTAssertTrue(cache.downloadIdentifiers.isEmpty)
        let line = try await activity(.pin)
        XCTAssertEqual(line.outcome, .failure)
    }

    func testPinningWithoutADomainSaysTheLocationIsMissing() async throws {
        let offline = OfflineStore(state: state, cacheSystem: UnavailableCacheSystem())

        let outcome = await offline.setPinned(driveFile("F1", named: "taxes.pdf"), pinned: true)

        XCTAssertFalse(outcome.succeeded)
        guard case .systemUnavailable(let reason) = outcome.effect else {
            return XCTFail("Expected .systemUnavailable, got \(outcome.effect)")
        }
        XCTAssertTrue(reason.contains("not registered"))
        // The mark itself is kept, so the pin applies the moment the domain comes back.
        let readback = await pins()
        XCTAssertEqual(readback, ["F1"])
    }

    func testPinnedDriveIDsComesFromSharedState() async throws {
        _ = await store.setPinned(driveFile("F1", named: "a.txt"), pinned: true)
        _ = await store.setPinned(driveFile("F2", named: "b.txt"), pinned: true)
        _ = await store.setPinned(driveFile("F1", named: "a.txt"), pinned: false)

        let readback = await store.pinnedDriveIDs()
        XCTAssertEqual(readback, ["F2"])
    }

    // MARK: Content policy

    func testPinnedItemsDeclareTheNonEvictablePolicy() {
        XCTAssertEqual(DriveFileProviderItem.contentPolicy(pinned: true),
                       .downloadEagerlyAndKeepDownloaded)
    }

    func testUnpinnedItemsInheritSoAFolderPinReachesItsChildren() {
        // `.downloadLazily` here would break a pinned folder: an explicit child policy overrides the
        // container's, so only inheritance lets the whole tree stay offline.
        XCTAssertEqual(DriveFileProviderItem.contentPolicy(pinned: false), .inherited)
    }

    func testItemBuiltWithThePinnedFlagCarriesThatPolicy() async throws {
        let pinned = DriveFileProviderItem.make(from: driveFile("F1", named: "a.txt"),
                                                contentPolicy: .downloadEagerlyAndKeepDownloaded)
        let lazy = DriveFileProviderItem.make(from: driveFile("F2", named: "b.txt"))

        XCTAssertEqual(pinned.contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(lazy.contentPolicy, .inherited)
    }

    func testPublishedItemsReadTheirPinFromSharedState() async throws {
        let env = DriveTestEnvironment.make(transport: StubTransport())
        let services = ProviderServices(config: env.config, drive: env.service, state: state,
                                        cacheSystem: cache)
        try await state.setPinned("F1", true)

        let items = await services.items(from: [
            DriveFile(id: "F1", name: "a.txt", mimeType: "text/plain"),
            DriveFile(id: "F2", name: "b.txt", mimeType: "text/plain"),
        ])

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.itemIdentifier.rawValue, $0) })
        XCTAssertEqual(byID[identifier("F1").rawValue]?.contentPolicy,
                       .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(byID[identifier("F2").rawValue]?.contentPolicy, .inherited)
    }

    func testServicesWithoutADomainReportTheCacheAsUnavailable() async throws {
        let env = DriveTestEnvironment.make(transport: StubTransport())
        let services = ProviderServices(config: env.config, drive: env.service, state: state,
                                        cacheSystem: nil)

        do {
            _ = try await services.offline.inventory()
            XCTFail("No manager means no inventory, not a zero-byte one.")
        } catch let error as CacheSystemError {
            guard case .unavailable = error else { return XCTFail("Got \(error)") }
        }
    }
}

/// A `CacheSystem` whose answers a test writes down, with the calls recorded in order.
///
/// The script is deliberately literal: an item not pointed at a path answers "no path", an item with
/// no refusal recorded answers "evicted", and so on. Anything a test forgets to script falls through
/// to the same answer the real system gives when it has nothing to say.
final class ScriptedCacheSystem: CacheSystem, @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [MaterializedEntry] = []
    private var paths: [String: URL] = [:]
    private var evictionRefusals: [String: Error] = [:]
    private var downloadRefusals: [String: Error] = [:]
    private var inventoryFailure: Error?
    private var evicted: [String] = []
    private var downloaded: [String] = []
    private var signalled: [String] = []

    // MARK: Scripting

    func load(_ newEntries: [MaterializedEntry]) { mutate { entries = newEntries } }

    func failInventory(_ error: Error) { mutate { inventoryFailure = error } }

    func point(_ identifier: NSFileProviderItemIdentifier, at url: URL?) {
        mutate {
            if let url { paths[identifier.rawValue] = url } else { paths.removeValue(forKey: identifier.rawValue) }
        }
    }

    func refuseEviction(_ identifier: NSFileProviderItemIdentifier, with error: Error) {
        mutate { evictionRefusals[identifier.rawValue] = error }
    }

    func refuseDownload(_ identifier: NSFileProviderItemIdentifier, with error: Error) {
        mutate { downloadRefusals[identifier.rawValue] = error }
    }

    // MARK: Recorded calls

    var evictedIdentifiers: [String] { read { evicted } }
    var downloadIdentifiers: [String] { read { downloaded } }
    var signalIdentifiers: [String] { read { signalled } }

    private func mutate(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; body() }
    private func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // MARK: CacheSystem

    func materializedEntries() async throws -> [MaterializedEntry] {
        if let failure = read({ inventoryFailure }) { throw failure }
        return read({ entries })
    }

    func userVisibleURL(for identifier: NSFileProviderItemIdentifier) async -> URL? {
        read { paths[identifier.rawValue] }
    }

    func evict(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        mutate { evicted.append(identifier.rawValue) }
        return read { evictionRefusals[identifier.rawValue] }
    }

    func requestFullDownload(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        mutate { downloaded.append(identifier.rawValue) }
        return read { downloadRefusals[identifier.rawValue] }
    }

    func signalContainer(_ identifier: NSFileProviderItemIdentifier) async {
        mutate { signalled.append(identifier.rawValue) }
    }
}
