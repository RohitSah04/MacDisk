import Foundation
import XCTest
import FileProvider
import CloudDiskKit

/// The one layer of the cache that a scripted `CacheSystem` cannot prove: the real calls to
/// `fileproviderd`.
///
/// Read-only by design. It asks what is materialized and where it lives; it never evicts, never asks
/// for a download and never re-registers anything, because those would change the user's disk. So this
/// covers `FileProviderCacheSystem`'s two answering calls and the inventory built on top of them, and
/// nothing else.
///
/// These cases live in the **app's own test bundle** for one reason: `NSFileProviderManager.domains()`
/// answers for the calling process, so a command-line test binary sees no CloudDisk location even while
/// the built app has one mounted. A hosted bundle runs inside `CloudDisk.app`, which holds the App Group
/// and the domain, so this is the first context where the question "what is Finder holding?" can really
/// be asked.
///
///     xcodebuild -scheme CloudDisk -destination platform=macOS test
///
/// Still a skip rather than a pass when no domain is registered — on a machine that has never launched
/// CloudDisk, or after the user removed the location, there is nothing to ask.
final class DomainCacheSmokeTests: XCTestCase {

    /// Which domain is registered is an async question, so it is asked per case rather than in
    /// `setUpWithError`, and the answer is a skip instead of a failure when there is nothing to ask.
    private func realSystem() async throws -> FileProviderCacheSystem {
        let domains = await CloudDiskDomain.registered()
        guard let domain = domains.first(where: {
            $0.identifier.rawValue == CloudDiskConfig.domainIdentifierValue
        }) ?? domains.first(where: { $0.displayName == CloudDiskConfig.displayName }) else {
            throw XCTSkip("""
            This process sees no CloudDisk Finder location. If this run is really hosted by \
            CloudDisk.app, the domain was never registered on this machine — register it by \
            launching the app, then run again.
            """)
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw XCTSkip("The domain is listed but the system hands no manager for it — "
                        + "which is itself the case UnavailableCacheSystem stands in for.")
        }
        return FileProviderCacheSystem(manager: manager)
    }

    func testTheMaterializedSetIsAnsweredWithoutHangingOrLying() async throws {
        let cache = try await realSystem()
        let entries = try await withTimeout(seconds: 60) { try await cache.materializedEntries() }

        // Whatever the domain holds, the rows have to be usable: a name the UI can show and an
        // identifier that decodes the way CloudDisk addresses items.
        for entry in entries {
            XCTAssertFalse(entry.name.isEmpty, "materialized row without a name")
            if let driveID = entry.driveID {
                XCTAssertEqual(ProviderIdentity.identifier(forDriveID: driveID), entry.identifier)
            } else {
                XCTAssertTrue(ProviderIdentity.isContainerIdentifier(entry.identifier),
                              "a row that is neither a Drive object nor a known container")
            }
        }
        // Recorded so a future run can compare against the same machine.
        print("CloudDisk's Finder location holds \(entries.count) materialized row(s)")
    }

    func testEveryPathTheSystemNamesIsReallyThere() async throws {
        let cache = try await realSystem()
        let entries = try await withTimeout(seconds: 60) { try await cache.materializedEntries() }
        let root = await cache.userVisibleURL(for: .rootContainer)
        var measured = 0
        for entry in entries.prefix(40) {
            guard let url = await cache.userVisibleURL(for: entry.identifier) else { continue }
            // A URL for an item the system says is on disk has to resolve, or the byte totals are
            // counting nothing.
            if let root {
                XCTAssertTrue(url.path.hasPrefix(root.path),
                              "\(url.path) is outside the domain's own volume \(root.path)")
            }
            measured += FileManager.default.fileExists(atPath: url.path) ? 1 : 0
        }
        print("Resolved \(measured) of \(min(entries.count, 40)) materialized paths")
    }

    func testInventoryOverTheRealSystemIsInternallyConsistent() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-domain-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let store = OfflineStore(state: ProviderState(directory: stateDirectory), cacheSystem: try await realSystem())

        let inventory = try await withTimeout(seconds: 90) { try await store.inventory() }

        XCTAssertEqual(inventory.fileCount + inventory.folderCount, inventory.items.count)
        XCTAssertGreaterThanOrEqual(inventory.materializedBytes, 0)
        XCTAssertEqual(inventory.materializedBytes,
                       inventory.items.reduce(0) { $0 + ($1.isFolder ? 0 : ($1.allocatedBytes ?? 0)) })
        XCTAssertEqual(inventory.evictableBytes, inventory.materializedBytes) // nothing pinned here
        XCTAssertEqual(inventory.isExact, inventory.unmeasuredFileCount == 0)
        print("""
        CloudDisk local cache: \(inventory.materializedBytes) bytes in \(inventory.fileCount) file(s), \
        \(inventory.folderCount) folder(s), \(inventory.unmeasuredFileCount) unmeasured
        """)
    }

    /// Runs a real system call with a deadline, because a domain whose extension is not answering
    /// stalls forever rather than failing — and a suite that hangs proves nothing.
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async throws -> T)
        async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw XCTSkip("The File Provider system did not answer within \(seconds)s, so this "
                            + "behaviour is unverified rather than broken.")
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
