import Foundation
import FileProvider

/// Shared dependencies for the File Provider side of CloudDisk.
///
/// One object is created per extension instance and handed to the core and to every enumerator, so
/// the metadata cache and the sync cursor are consistent across concurrent calls.
public final class ProviderServices: @unchecked Sendable {

    public let config: CloudDiskConfig
    public let drive: DriveService
    public let state: ProviderState
    public let cache: DriveMetadataCache
    let manager: NSFileProviderManager?

    public init(config: CloudDiskConfig,
                drive: DriveService,
                state: ProviderState,
                manager: NSFileProviderManager? = nil,
                cacheTTL: TimeInterval = 10) {
        self.config = config
        self.drive = drive
        self.state = state
        self.manager = manager
        self.cache = DriveMetadataCache(ttl: cacheTTL)
    }

    /// Builds the whole dependency graph from an Info.plist-derived configuration.
    ///
    /// `domain` is only used to resolve the manager for eviction and download requests; everything
    /// else works without it, which keeps this constructible in unit tests.
    public static func make(config: CloudDiskConfig,
                            domain: NSFileProviderDomain?,
                            transport: HTTPTransport = URLSessionTransport.shared,
                            store: CredentialStore? = nil,
                            exchanger: TokenExchanging? = nil) throws -> ProviderServices {
        let credentialStore = store ?? KeychainCredentialStore.current(config: config)
        let tokens = TokenProvider(config: config,
                                   store: credentialStore,
                                   exchanger: exchanger ?? GoogleOAuthClient(transport: transport))
        let drive = DriveService(config: config, tokens: tokens, transport: transport)
        let state = try ProviderState.shared(config: config)
        let manager = domain.flatMap { NSFileProviderManager(for: $0) }
        return ProviderServices(config: config, drive: drive, state: state, manager: manager)
    }

    /// Tells the system that new working-set changes are waiting.
    public func signalWorkingSet() async {
        guard let manager else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.signalEnumerator(for: .workingSet) { _ in continuation.resume() }
        }
    }

    /// A fresh, unique URL for one downloaded object.
    ///
    /// File Provider requires the URL passed to a fetch completion handler to be a regular file on
    /// the same volume as the user-visible files; `temporaryDirectoryURL` is the only location the
    /// system guarantees that for, and it is where the system clones and unlinks the result. Falling
    /// back to `NSTemporaryDirectory()` keeps the library usable in tests, where no manager exists.
    public func temporaryFileURL(named fileExtension: String? = nil) throws -> URL {
        let directory: URL
        if let manager, let url = try? manager.temporaryDirectoryURL() {
            directory = url
        } else {
            directory = FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let name = "clouddisk-\(UUID().uuidString)" + (fileExtension.map { "." + $0 } ?? "")
        return directory.appendingPathComponent(name)
    }

    /// Removes leftover downloads from an earlier crash of this process.
    ///
    /// The system takes ownership of a file once the completion handler runs, but if the extension
    /// died between that call and the system's unlink the copy stays in the container, and the
    /// provider — not the system — is responsible for deleting it.
    public func sweepStaleTemporaryFiles(olderThan interval: TimeInterval = 3600) {
        guard let directory = try? manager?.temporaryDirectoryURL() else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.lastPathComponent.hasPrefix("clouddisk-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// MARK: Item construction

extension ProviderServices {

    /// Items are built with the offline pin the user set in CloudDisk translated into the system's
    /// own content policy, so "keep downloading" and eviction are decided by FPFS rather than by a
    /// provider-side download loop.
    func item(for file: DriveFile, pinned: Bool) -> NSFileProviderItem {
        DriveFileProviderItem.make(from: file,
                                   contentPolicy: pinned ? .downloadEagerlyAndKeepDownloaded
                                                         : .downloadLazily)
    }

    func item(for file: DriveFile) async -> NSFileProviderItem {
        item(for: file, pinned: await state.isPinned(file.id))
    }

    /// One pin-set read for a whole page of results, and the metadata is put in the cache so the
    /// `item(for:)` calls the system makes right after an enumeration stay local.
    func items(from files: [DriveFile]) async -> [NSFileProviderItem] {
        let pins = await state.pinnedDriveIDs()
        for file in files { await cache.store(file) }
        return files.map { file in
            DriveFileProviderItem.make(from: file,
                                       contentPolicy: pins.contains(file.id)
                                        ? .downloadEagerlyAndKeepDownloaded : .downloadLazily)
        }
    }

    var rootItem: NSFileProviderItem {
        DriveFileProviderItem.driveRoot(displayName: CloudDiskConfig.displayName)
    }
}

/// Short-lived Drive metadata cache.
///
/// File Provider calls `item(for:)` and enumerations repeatedly for the same object during a single
/// user interaction. Drive answers in tens of milliseconds, so an uncoalesced implementation turns
/// one Finder click into a dozen requests and one slow click into a timeout.
///
/// This caches *metadata only*. File content is never cached here — FPFS owns materialization, and a
/// second content cache would fight it for disk space.
public actor DriveMetadataCache {

    private struct Entry {
        let file: DriveFile
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inflight: [String: Task<DriveFile, Error>] = [:]
    private let ttl: TimeInterval
    private let capacity = 4_000

    public init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// Returns a cached value when fresh, otherwise runs `load` once — concurrent callers for the
    /// same id share that single request.
    public func value(forDriveID id: String,
                      now: Date = Date(),
                      load: @escaping @Sendable () async throws -> DriveFile) async throws -> DriveFile {
        if let entry = entries[id], now.timeIntervalSince(entry.storedAt) < ttl {
            return entry.file
        }
        if let task = inflight[id] {
            return try await task.value
        }

        let task = Task { try await load() }
        inflight[id] = task
        defer { inflight[id] = nil }

        do {
            let file = try await task.value
            store(file, at: now)
            return file
        } catch {
            throw error
        }
    }

    public func store(_ file: DriveFile, at date: Date = Date()) {
        if entries.count >= capacity { entries.removeAll() }
        entries[file.id] = Entry(file: file, storedAt: date)
    }

    public func cachedValue(forDriveID id: String, now: Date = Date()) -> DriveFile? {
        guard let entry = entries[id], now.timeIntervalSince(entry.storedAt) < ttl else { return nil }
        return entry.file
    }

    /// Any local mutation invalidates the object it touched; a stale version here would make the
    /// system believe it already holds the newest bytes.
    public func invalidate(_ id: String) {
        entries[id] = nil
    }

    public func removeAll() {
        entries.removeAll()
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
    }
}
