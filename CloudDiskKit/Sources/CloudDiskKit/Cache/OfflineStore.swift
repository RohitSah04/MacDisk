import Foundation
@preconcurrency import FileProvider

/// One object the system holds on disk for this domain, measured on that disk.
public struct CachedItem: Sendable, Equatable {
    public let identifier: NSFileProviderItemIdentifier
    public let driveID: String?
    public let name: String
    public let isFolder: Bool
    public let isPinned: Bool
    /// Disk blocks this path occupies, which for a partially materialized file is the part that has
    /// actually arrived. Nil when the path could not be measured or does not exist.
    public let allocatedBytes: Int64?
    /// The length the item declares, which is the whole object even when only a window is on disk.
    public let declaredBytes: Int64?
    /// The user-immutable flag on the replica's path. Something outside CloudDisk — Finder's own lock, a
    /// terminal `chflags uchg` — put it there, and it is the one signal on disk that the copy must not
    /// move, so auto-eviction reads it before offering the item.
    public let isLocked: Bool

    public init(identifier: NSFileProviderItemIdentifier, driveID: String?, name: String,
                isFolder: Bool, isPinned: Bool, allocatedBytes: Int64?, declaredBytes: Int64?,
                isLocked: Bool = false) {
        self.identifier = identifier
        self.driveID = driveID
        self.name = name
        self.isFolder = isFolder
        self.isPinned = isPinned
        self.allocatedBytes = allocatedBytes
        self.declaredBytes = declaredBytes
        self.isLocked = isLocked
    }
}

/// What CloudDisk's local cache costs, as measured from the file system.
public struct CacheInventory: Sendable, Equatable {
    public var items: [CachedItem]
    public var measuredAt: Date

    /// Bytes of file content on disk. A folder's own directory block is not counted: it is file
    /// system overhead, not a copy of anything the user downloaded.
    public var materializedBytes: Int64 {
        items.reduce(0) { $0 + ($1.isFolder ? 0 : ($1.allocatedBytes ?? 0)) }
    }
    public var pinnedBytes: Int64 {
        items.reduce(0) { $0 + ($1.isFolder || !$1.isPinned ? 0 : ($1.allocatedBytes ?? 0)) }
    }
    /// Bytes a "clear cache" run can ask for back: everything the user has not marked as kept offline.
    /// The system still gets the last word — an item open in another app is not freed.
    public var evictableBytes: Int64 {
        items.reduce(0) { $0 + ($1.isFolder || $1.isPinned ? 0 : ($1.allocatedBytes ?? 0)) }
    }
    /// How many files that is, which is not the same question: an item whose path Finder could not
    /// name contributes no bytes but is still worth offering.
    public var evictableCount: Int { items.filter { !$0.isFolder && !$0.isPinned }.count }
    /// Bytes whose holder is not known: the item is in the materialized set but the system could not
    /// name a path for it, or the path is gone. Reported so a total is never mistaken for exact.
    public var unmeasuredFileCount: Int {
        items.filter { !$0.isFolder && $0.allocatedBytes == nil }.count
    }
    public var fileCount: Int { items.filter { !$0.isFolder }.count }
    public var folderCount: Int { items.filter { $0.isFolder }.count }
    public var pinnedCount: Int { items.filter { $0.isPinned }.count }
    public var isExact: Bool { unmeasuredFileCount == 0 }
}

/// Why the system would not release an item.
public enum EvictionRefusal: String, Sendable, Equatable {
    case pinned
    case nonEvictable
    case unsyncedEdits
    case inUse
    case absent

    public var sentence: String {
        switch self {
        case .pinned:
            return "kept offline, as you asked"
        case .nonEvictable:
            return "marked by Finder as not removable. A copy you once kept offline keeps that mark "
                 + "until Finder reads the file again — it clears when the file changes on Drive, or "
                 + "when you rebuild the Finder location on the Status tab"
        case .unsyncedEdits:
            return "still holds changes that have not reached Google Drive"
        case .inUse:
            return "open in another app right now"
        case .absent:
            return "was not on disk, so there was nothing to free"
        }
    }
}

public struct EvictionReport: Sendable, Equatable {
    public struct Released: Sendable, Equatable {
        public let name: String
        /// Nil when the file could not be measured before it went, so the total is a floor, not an
        /// exact figure.
        public let bytes: Int64?
    }
    public struct Kept: Sendable, Equatable {
        public let name: String
        public let refusal: EvictionRefusal
    }
    public struct Failure: Sendable, Equatable {
        public let name: String
        public let reason: String
    }

    public var scanned: Int = 0
    public var released: [Released] = []
    public var kept: [Kept] = []
    public var failures: [Failure] = []

    public var freedBytes: Int64 { released.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public var unmeasuredReleasedCount: Int { released.filter { $0.bytes == nil }.count }
    public var keptCount: Int { kept.count }

    public func keptCount(_ refusal: EvictionRefusal) -> Int {
        kept.filter { $0.refusal == refusal }.count
    }
}

/// What happened to an item's "keep offline" mark.
public struct PinOutcome: Sendable, Equatable {
    public enum Effect: Sendable, Equatable {
        /// The system took the download request, so the bytes start arriving now.
        case downloadScheduled
        /// Nothing on disk yet: the policy is published and applies when the item is enumerated.
        case downloadDeferred
        /// The system said no, with its own sentence.
        case refused(String)
        /// Unpinning: the item is evictable again; its bytes are left alone until they are needed.
        case policyPublished
        /// No domain to talk to.
        case systemUnavailable(String)
    }

    public var pinned: Bool
    public var effect: Effect

    public init(pinned: Bool, effect: Effect) {
        self.pinned = pinned
        self.effect = effect
    }

    /// Whether the user's intent is actually in effect, which is what the activity log records.
    public var succeeded: Bool {
        switch effect {
        case .downloadScheduled, .downloadDeferred, .policyPublished: return true
        case .refused, .systemUnavailable: return false
        }
    }
}

/// The offline half of CloudDisk: what is on disk, what it costs, and how it gets there or away.
///
/// Nothing here stores file content. The bytes belong to File Provider's own store; this type only
/// asks the system for its list of materialized items, measures those paths, and requests that items
/// be downloaded or released. That is why the numbers are real on any machine — they are read off the
/// disk and from `fileproviderd`, not from a CloudDisk ledger that could disagree with both.
public actor OfflineStore {

    private let state: ProviderState
    private let cacheSystem: any CacheSystem
    private let fileManager: FileManager

    public init(state: ProviderState,
                cacheSystem: any CacheSystem = UnavailableCacheSystem(),
                fileManager: FileManager = .default) {
        self.state = state
        self.cacheSystem = cacheSystem
        self.fileManager = fileManager
    }

    // MARK: Measurement

    public func inventory(now: Date = Date()) async throws -> CacheInventory {
        let entries = try await cacheSystem.materializedEntries()
        let pins = await state.pinnedDriveIDs()
        var items: [CachedItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            // The mount point and the virtual namespaces are always in the materialized set — the
            // folder Finder opens is itself a materialized item — and none of them is a copy of
            // something the user downloaded. Counting them made an empty cache read as "1 folder".
            if ProviderIdentity.isContainerIdentifier(entry.identifier) { continue }
            let url = await cacheSystem.userVisibleURL(for: entry.identifier)
            let reading = url.flatMap { measure($0) }
            // The disk answer wins over the declaration: an item the system calls a file but that is
            // a directory on the replica would otherwise be counted with a folder's blocks as content.
            let isFolder = reading?.isDirectory ?? entry.isFolder
            items.append(CachedItem(identifier: entry.identifier,
                                    driveID: entry.driveID,
                                    name: entry.name,
                                    isFolder: isFolder,
                                    isPinned: entry.driveID.map { pins.contains($0) } ?? false,
                                    allocatedBytes: isFolder ? nil : reading?.allocatedBytes ?? nil,
                                    declaredBytes: entry.declaredBytes,
                                    isLocked: reading?.isLocked ?? false))
        }
        return CacheInventory(items: items, measuredAt: now)
    }

    /// Disk blocks, type and lock flag of one path, or nil when it cannot be read.
    private func measure(_ url: URL) -> (allocatedBytes: Int64?, isDirectory: Bool, isLocked: Bool)? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
        guard let values else { return nil }
        return (values.totalFileAllocatedSize.map { Int64($0) },
                values.isDirectory ?? false,
                Self.isLocked(url))
    }

    /// Whether something outside CloudDisk has marked this copy not to be moved.
    ///
    /// Read off the file's own flags rather than from any CloudDisk record, because the lock was not set
    /// by us: Finder's lock, a terminal `chflags uchg` and a backup restore all leave the same mark, and
    /// a sweep acting without being asked has no business overriding a decision it did not make. This is
    /// `stat`'s immutable bit and nothing else, so an unreadable path reads as not locked.
    static func isLocked(_ url: URL) -> Bool {
        var attributes = stat()
        guard stat(url.path, &attributes) == 0 else { return false }
        return Int(attributes.st_flags) & Int(UF_IMMUTABLE) != 0
    }

    // MARK: Release

    /// Frees everything the user has not asked to keep offline.
    ///
    /// A pinned item is not even offered to the system, because eviction stops at the first
    /// non-evictable child of a folder — so pushing a pinned file into that queue could cost the user
    /// the rest of the folder's release. Everything else goes, and whatever the system refuses is
    /// reported as refused rather than quietly counted as freed.
    public func releaseEligibleItems() async throws -> EvictionReport {
        let inventory = try await self.inventory()
        var report = EvictionReport()

        for item in inventory.items where !item.isFolder {
            report.scanned += 1
            if item.isPinned {
                report.kept.append(.init(name: item.name, refusal: .pinned))
                continue
            }
            try await release(item, into: &report)
        }
        await recordEviction(report)
        return report
    }

    /// Releases one named object's bytes, leaving its metadata row in place.
    public func release(driveID: String, name: String) async throws -> EvictionReport {
        var report = EvictionReport()
        report.scanned = 1
        let identifier = ProviderIdentity.identifier(forDriveID: driveID)
        let bytes = await cacheSystem.userVisibleURL(for: identifier)
            .flatMap { measure($0)?.allocatedBytes }
        classify(identifier: identifier, name: name, bytes: bytes,
                 error: await cacheSystem.evict(identifier), into: &report)
        await recordEviction(report)
        return report
    }

    private func release(_ item: CachedItem, into report: inout EvictionReport) async throws {
        let error = await cacheSystem.evict(item.identifier)
        classify(identifier: item.identifier, name: item.name, bytes: item.allocatedBytes,
                 error: error, into: &report)
    }

    /// Turns the system's answer into "released", "refused for a reason" or "failed".
    ///
    /// Only the first branch adds bytes to the total. `EBUSY` and `.unsyncedEdits` in particular are
    /// ordinary states of a live Mac — a document open in another app, an edit still uploading — and
    /// reporting them as failures would make a successful cleanup look like a broken one.
    private func classify(identifier: NSFileProviderItemIdentifier,
                          name: String,
                          bytes: Int64?,
                          error: Error?,
                          into report: inout EvictionReport) {
        guard let error else {
            report.released.append(.init(name: name, bytes: bytes))
            return
        }
        if let refusal = Self.refusal(for: error) {
            report.kept.append(.init(name: name, refusal: refusal))
            return
        }
        report.failures.append(.init(name: name, reason: Self.describe(error)))
    }

    static func refusal(for error: Error) -> EvictionRefusal? {
        if let fileProviderError = error as? NSFileProviderError {
            switch fileProviderError.code {
            case .nonEvictable, .nonEvictableChildren:
                return .nonEvictable
            case .unsyncedEdits:
                return .unsyncedEdits
            case .noSuchItem:
                return .absent
            default:
                break
            }
        }
        let bridged = error as NSError
        if bridged.domain == NSPOSIXErrorDomain,
           bridged.code == Int(EBUSY) || bridged.code == Int(EMLINK) {
            return .inUse
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func recordEviction(_ report: EvictionReport) async {
        guard report.scanned > 0 else { return }
        let detail = "Freed \(report.released.count) of \(report.scanned) cached files"
            + (report.kept.isEmpty ? "" : "; kept \(report.kept.count)")
            + (report.failures.isEmpty ? "" : "; \(report.failures.count) failed")
        try? await state.record(.init(kind: .synchronize,
                                      outcome: report.failures.isEmpty ? .success : .failure,
                                      subject: "Local cache",
                                      detail: detail))
    }

    // MARK: Auto-eviction

    /// Frees copies that have been idle at least `config.inactivityTimeout` for as long as the ledger
    /// can prove it.
    ///
    /// Same mechanism as a manual "Clear cached files", and deliberately narrower. The manual press is
    /// an explicit request for disk back, so it may offer every unpinned copy; this one acts without
    /// being asked, so it offers only what it can show nobody wants, and every item it cannot show is
    /// counted under the rule that kept it rather than being quietly skipped. Nothing here reaches
    /// Google: this type holds no `DriveService`, and `evict` is the only mutating call it can make —
    /// the original file is never in range.
    public func sweepForInactivity(now: Date = Date(),
                                   config: AutoEviction.Config = .standard,
                                   activeReads: Set<String> = []) async throws
        -> AutoEviction.Sweep {
        let inventory = try await self.inventory()
        let ledger = await state.accessTimes()
        var report = EvictionReport()
        var kept: [AutoEviction.Decision: Int] = [:]
        var earliest: Date?

        for item in inventory.items {
            let facts = item.accessFacts(ledger: ledger, activeReads: activeReads)
            let decision = AutoEviction.decide(facts, now: now, config: config)
            report.scanned += 1

            if decision == .evict, let driveID = item.driveID {
                let releasedBefore = report.released.count
                try await release(item, into: &report)
                ProviderLog.note("evict release \(driveID) bytes=\(item.allocatedBytes ?? 0)"
                                 + " released=\(report.released.count > releasedBefore)")
                // Only a copy that actually went loses its history. A refused one is still there and
                // still idle, and forgetting its timestamp would make it unmeasurable forever.
                if report.released.count > releasedBefore { await state.forgetAccess(driveID) }
                continue
            }

            kept[decision, default: 0] += 1
            if let remaining = decision.retryIn {
                let candidate = now.addingTimeInterval(remaining)
                if earliest == nil || candidate < earliest! { earliest = candidate }
            }
        }

        // Ids whose copy is gone and which have not been seen for the retention window are dropped, so
        // the ledger tracks this Mac's cache rather than everywhere the account has ever been.
        let present = Set(inventory.items.compactMap { $0.isFolder ? nil : $0.driveID })
        await state.pruneAccess(knownDriveIDs: present,
                                olderThan: now.addingTimeInterval(-config.ledgerRetention))

        let sweep = AutoEviction.Sweep(report: report, kept: kept, nextEligibleAt: earliest)
        await recordAutoEviction(sweep)
        return sweep
    }

    /// A user-facing line only when bytes actually moved.
    ///
    /// A pass that freed nothing is the normal state of a Mac whose files are all fresh, and recording
    /// one every few minutes would bury the operations the Activity screen exists to show.
    private func recordAutoEviction(_ sweep: AutoEviction.Sweep) async {
        guard !sweep.report.released.isEmpty else { return }
        let keptTotal = sweep.kept.values.reduce(0, +)
        let detail = "Freed \(sweep.report.released.count) idle "
                   + (sweep.report.released.count == 1 ? "copy" : "copies")
                   + (keptTotal == 0 ? "" : "; kept \(keptTotal) still in use or too new")
        try? await state.record(.init(kind: .synchronize,
                                      outcome: sweep.report.failures.isEmpty ? .success : .failure,
                                      subject: "Local cache",
                                      detail: detail))
    }
    // MARK: Preview support

    /// Whether an object still has bytes to fetch before Quick Look can be pointed at it.
    ///
    /// Allocated blocks rather than the logical length, because a dataless replica reports Drive's full
    /// size while holding none of the content — comparing lengths would answer "already there" for
    /// every file in the drive. An object Drive gives no size for is a Google-native document, which
    /// has no downloadable content at all, so waiting for one would wait forever.
    static func needsDownload(declaredBytes: Int64?, allocatedBytes: Int64?) -> Bool {
        guard let declaredBytes, declaredBytes > 0 else { return false }
        guard let allocatedBytes else { return true }
        return allocatedBytes < declaredBytes
    }

    /// Brings one object's content to disk so a preview has something to open.
    ///
    /// Quick Look's helper asks the thumbnailing daemon for a copy of the file instead of reading the
    /// replica, and that daemon gives up on a dataless item rather than waiting for File Provider to
    /// fetch it — Finder's space-bar does wait, which is why the same file previews there and shows a
    /// bare document icon here. Fetching first is what turns the placeholder into the file.
    ///
    /// - Returns: nil once the whole object is on disk, or the sentence explaining why it is not.
    public func downloadForPreview(driveID: String,
                                   declaredBytes: Int64?,
                                   timeout: TimeInterval = 120) async -> String? {
        guard await isMissingBytes(driveID: driveID, declaredBytes: declaredBytes) else { return nil }

        let identifier = ProviderIdentity.identifier(forDriveID: driveID)
        if let error = await cacheSystem.requestFullDownload(identifier) {
            return Self.describe(error)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: Self.previewPollIntervalNanoseconds)
            } catch {
                // The sheet went away; nobody is waiting for this answer any more.
                return nil
            }
            guard await isMissingBytes(driveID: driveID, declaredBytes: declaredBytes) else { return nil }
        }
        return "The copy did not finish arriving within \(Int(timeout)) seconds, so there is nothing to "
             + "open yet. Finder keeps fetching the file in the background — try again in a moment, or "
             + "use \"Keep offline\" to hold it on this Mac."
    }

    private func isMissingBytes(driveID: String, declaredBytes: Int64?) async -> Bool {
        let identifier = ProviderIdentity.identifier(forDriveID: driveID)
        let allocated = await cacheSystem.userVisibleURL(for: identifier)
            .flatMap { measure($0)?.allocatedBytes }
        return Self.needsDownload(declaredBytes: declaredBytes, allocatedBytes: allocated)
    }

    private static let previewPollIntervalNanoseconds: UInt64 = 400_000_000

    // MARK: Pinning

    public func pinnedDriveIDs() async -> Set<String> {
        await state.pinnedDriveIDs()
    }

    /// Marks an object as "keep offline" — or releases that mark — and tells the system about it.
    ///
    /// Two things have to happen for the mark to mean anything. The pin set is shared state the
    /// extension reads when it publishes items, so the item's `contentPolicy` changes; and the system
    /// is nudged to re-enumerate the container, which is how that new policy reaches the disk replica.
    /// Pinning also asks for the bytes immediately, because a Finder-side download only starts when
    /// the user opens the file, and "keep offline" is a request for it to be there beforehand.
    @discardableResult
    public func setPinned(_ file: DriveFile, pinned: Bool) async -> PinOutcome {
        // A pin the app cannot persist is not a pin. Nothing below is attempted in that case, because
        // publishing a policy the extension will read back as "unpinned" would tell the user the file
        // is safe offline while the next enumeration marks it evictable.
        let outcome: PinOutcome
        do {
            try await state.setPinned(file.id, pinned)
            outcome = await publishPin(of: file, pinned: pinned)
        } catch {
            outcome = PinOutcome(pinned: false, effect: .systemUnavailable(Self.describe(error)))
        }

        try? await state.record(.init(kind: pinned ? .pin : .unpin,
                                      outcome: outcome.succeeded ? .success : .failure,
                                      subject: file.name,
                                      detail: Self.detail(for: outcome)))
        return outcome
    }

    private func publishPin(of file: DriveFile, pinned: Bool) async -> PinOutcome {
        await cacheSystem.signalContainer(ProviderIdentity.parentIdentifier(for: file))

        guard pinned else { return PinOutcome(pinned: false, effect: .policyPublished) }

        let identifier = ProviderIdentity.identifier(forDriveID: file.id)
        switch await cacheSystem.requestFullDownload(identifier) {
        case .none:
            return PinOutcome(pinned: true, effect: .downloadScheduled)
        case .some(let error):
            if case .unavailable(let reason)? = error as? CacheSystemError {
                // No domain to hold the promise. The mark is persisted, because a pin the user set
                // while the location was unmounted should take effect when it comes back — but the
                // answer says plainly that nothing is downloading yet.
                return PinOutcome(pinned: true, effect: .systemUnavailable(reason))
            }
            let bridged = error as NSError
            if bridged.domain == NSFileProviderErrorDomain,
               bridged.code == NSFileProviderError.Code.noSuchItem.rawValue {
                // Not on disk yet — a pin from CloudDisk's own browser before Finder has listed
                // the row. The policy is published, so the download happens at first sight.
                return PinOutcome(pinned: true, effect: .downloadDeferred)
            }
            return PinOutcome(pinned: true, effect: .refused(Self.describe(error)))
        }
    }

    private static func detail(for outcome: PinOutcome) -> String? {
        switch outcome.effect {
        case .downloadScheduled:
            return "Downloading now; kept offline afterwards"
        case .downloadDeferred:
            return "Kept offline; downloads as soon as Finder lists the file"
        case .policyPublished:
            // Not "the copy on disk can be freed": Finder keeps the mark it read when the file was kept
            // offline until it reads the file again, so promising the bytes back here would be a lie the
            // next "Clear cached files" would expose.
            return "No longer kept offline. Finder holds the copy already on disk until it re-reads "
                 + "the file; new copies can be freed normally"
        case .refused(let reason), .systemUnavailable(let reason):
            return reason
        }
    }
}

extension CachedItem {
    /// The facts the eviction rule needs about this row, with the ledger and this process's live
    /// transfers folded in.
    func accessFacts(ledger: [String: Date], activeReads: Set<String>) -> AutoEviction.Facts {
        AutoEviction.Facts(driveID: driveID,
                           isFolder: isFolder,
                           isPinned: isPinned,
                           allocatedBytes: allocatedBytes,
                           declaredBytes: declaredBytes,
                           lastAccessedAt: driveID.flatMap { ledger[$0] },
                           isActiveRead: driveID.map { activeReads.contains($0) } ?? false,
                           isLockedOnDisk: isLocked)
    }
}
