import Foundation
import FileProvider

/// One object the system reports as present on disk in this domain.
///
/// Deliberately small: this is what File Provider can answer without asking Google anything. The
/// bytes actually held are measured from the user-visible URL by `OfflineStore`, because only the
/// file system knows how much of a sparse file is really there.
public struct MaterializedEntry: Sendable, Equatable {
    public let identifier: NSFileProviderItemIdentifier
    public let name: String
    public let driveID: String?
    public let isFolder: Bool
    /// What the item declares its size to be. For a partially materialized file this is the length of
    /// the whole object, not the part on disk, so it is never used for cache accounting.
    public let declaredBytes: Int64?

    public init(identifier: NSFileProviderItemIdentifier, name: String, driveID: String?,
                isFolder: Bool = false, declaredBytes: Int64?) {
        self.identifier = identifier
        self.name = name
        self.driveID = driveID
        self.isFolder = isFolder
        self.declaredBytes = declaredBytes
    }
}

public enum CacheSystemError: LocalizedError, Equatable {
    case unavailable(String)
    case enumerationIncomplete(pages: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "CloudDisk cannot ask Finder about the files it is holding: \(reason)"
        case .enumerationIncomplete(let pages):
            return "The list of cached files did not finish after \(pages) pages, so the reported "
                 + "cache size covers only the part that was read."
        }
    }
}

/// The part of the file provider system CloudDisk needs to measure and free its own cache.
///
/// Everything here is a question to `fileproviderd`/FPFS rather than to Google: what is on disk, where
/// it is, and whether the system will release it. Keeping it behind one protocol is what makes the
/// accounting testable — the alternative is a test suite that can only run against a mounted domain.
public protocol CacheSystem: Sendable {

    /// Every item the system currently keeps on disk for this domain.
    ///
    /// - Throws: `CacheSystemError` when the domain is not reachable or the enumeration cannot finish.
    func materializedEntries() async throws -> [MaterializedEntry]

    /// Where the system says this item lives, or nil when it has no on-disk representation.
    func userVisibleURL(for identifier: NSFileProviderItemIdentifier) async -> URL?

    /// Asks the system to drop an item's bytes. The raw error, if any, comes back for the caller to
    /// classify: "kept because it is pinned" and "failed" are different sentences, and deciding which
    /// one applies is the store's job, not this layer's.
    func evict(_ identifier: NSFileProviderItemIdentifier) async -> Error?

    /// Asks the system to download the whole object as soon as it can.
    func requestFullDownload(_ identifier: NSFileProviderItemIdentifier) async -> Error?

    /// Tells the system that a container's contents may have changed, which is how an item's new
    /// content policy reaches the disk replica.
    func signalContainer(_ identifier: NSFileProviderItemIdentifier) async
}

/// The real implementation: the domain's `NSFileProviderManager`.
public final class FileProviderCacheSystem: CacheSystem, @unchecked Sendable {

    /// A stop for an enumeration that never returns a terminal page.
    ///
    /// 500 pages at the system's own page size is far beyond any materialized set a Mac holds; the
    /// number exists so a broken pagination loop reports a partial inventory instead of hanging or
    /// spinning through `fileproviderd` forever.
    static let maximumPages = 500

    private let manager: NSFileProviderManager

    public init(manager: NSFileProviderManager) {
        self.manager = manager
    }

    public func materializedEntries() async throws -> [MaterializedEntry] {
        let enumerator = manager.enumeratorForMaterializedItems()
        var collected: [NSFileProviderItem] = []
        // The documented starting page for this enumerator is an empty NSData: the materialized set is
        // not sorted by name or date, so no sort hint applies.
        var page = NSFileProviderPage(Data())
        var pageCount = 0

        while true {
            pageCount += 1
            if pageCount > Self.maximumPages {
                enumerator.invalidate()
                throw CacheSystemError.enumerationIncomplete(pages: Self.maximumPages)
            }
            let collector = MaterializedPageCollector()
            enumerator.enumerateItems(for: collector, startingAt: page)
            do {
                let arrived = try await collector.waitForPage()
                collected.append(contentsOf: arrived.items)
                guard let next = arrived.next else {
                    enumerator.invalidate()
                    return collected.map(Self.entry)
                }
                page = next
            } catch {
                enumerator.invalidate()
                throw error
            }
        }
    }

    public func userVisibleURL(for identifier: NSFileProviderItemIdentifier) async -> URL? {
        try? await manager.getUserVisibleURL(for: identifier)
    }

    public func evict(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        do {
            try await manager.evictItem(identifier: identifier)
            return nil
        } catch {
            return error
        }
    }

    public func requestFullDownload(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        do {
            // `NSNotFound` with length 0 is how the API spells "the whole object"; a bounded range
            // would ask for one extent instead. The name carries its double underscore because the
            // method is marked NS_REFINED_FOR_SWIFT, which only exposes the refined spelling.
            try await manager.__requestDownloadForItem(withIdentifier: identifier,
                                                       requestedRange: NSRange(location: NSNotFound,
                                                                               length: 0))
            return nil
        } catch {
            return error
        }
    }

    public func signalContainer(_ identifier: NSFileProviderItemIdentifier) async {
        do {
            try await manager.signalEnumerator(for: identifier)
        } catch {
            // Nothing to report: a signal the system refuses only delays a refresh the next
            // enumeration would have carried anyway, and the caller has no way to act on it.
        }
    }

    static func entry(for item: NSFileProviderItem) -> MaterializedEntry {
        let type = item.contentType
        // `documentSize` is both a nullable and an optional protocol requirement, which Swift imports
        // as a double optional: the outer level is "the provider did not answer", the inner one is
        // "the item has no size".
        let size = item.documentSize
        let isDirectory = type == .folder || type?.conforms(to: .folder) == true
        return MaterializedEntry(identifier: item.itemIdentifier,
                          name: item.filename,
                          driveID: ProviderIdentity.driveID(for: item.itemIdentifier),
                          isFolder: isDirectory,
                          declaredBytes: size.map { $0?.int64Value } ?? nil)
    }
}

/// One page of the materialized set, delivered through the observer API the system insists on.
///
/// The system may reply to a single `enumerateItems` call several times before finishing the page, so
/// items accumulate until `finishEnumerating(upTo:)` names the next page or ends the enumeration.
private final class MaterializedPageCollector: NSObject, NSFileProviderEnumerationObserver,
                                               @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NSFileProviderItem] = []
    private var continuation: CheckedContinuation<MaterializedPage, Error>?

    func waitForPage() async throws -> MaterializedPage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func didEnumerate(_ newItems: [NSFileProviderItem]) {
        lock.lock()
        items.append(contentsOf: newItems)
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        resume(with: MaterializedPage(items: drain(), next: nextPage))
    }

    func finishEnumeratingWithError(_ error: Error) {
        // Whatever has already arrived is discarded: a partial answer reported as an inventory would
        // understate the cache without saying so.
        _ = drain()
        takeContinuation()?.resume(throwing: error)
    }

    private func drain() -> [NSFileProviderItem] {
        lock.lock()
        defer { lock.unlock() }
        let collected = items
        items = []
        return collected
    }

    private func resume(with page: MaterializedPage) {
        takeContinuation()?.resume(returning: page)
    }

    /// The waiter, taken in one step, so an observer that finished twice cannot resume twice.
    private func takeContinuation() -> CheckedContinuation<MaterializedPage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let waiting = continuation
        continuation = nil
        return waiting
    }
}

/// One page of the materialized set, plus the page the system wants next if there is one.
struct MaterializedPage {
    var items: [NSFileProviderItem]
    var next: NSFileProviderPage?
}

/// The cache system used when no domain is reachable: a unit test, a signed-out app, or a build whose
/// App Group is missing. It answers the way an unmounted domain does — with an explanation, never with
/// a number that looks like an empty cache.
public struct UnavailableCacheSystem: CacheSystem {

    public let reason: String

    public init(reason: String = "CloudDisk's Finder location is not registered.") {
        self.reason = reason
    }

    public func materializedEntries() async throws -> [MaterializedEntry] {
        throw CacheSystemError.unavailable(reason)
    }

    public func userVisibleURL(for identifier: NSFileProviderItemIdentifier) async -> URL? { nil }

    public func evict(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        CacheSystemError.unavailable(reason)
    }

    public func requestFullDownload(_ identifier: NSFileProviderItemIdentifier) async -> Error? {
        CacheSystemError.unavailable(reason)
    }

    public func signalContainer(_ identifier: NSFileProviderItemIdentifier) async {}
}
