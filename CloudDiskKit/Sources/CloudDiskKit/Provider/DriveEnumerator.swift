import Foundation
import FileProvider

/// Lists Drive objects for File Provider.
///
/// Three shapes share one implementation:
///
/// - a folder, enumerated page by page with Drive's own `pageToken` carried inside `NSFileProviderPage`;
/// - Drive's trash, which is a query rather than a folder;
/// - the working set, which is the Drive changes feed turned into `NSFileProviderSyncAnchor` values.
///
/// The prototype in the repository collapsed all three into one unpaged enumeration and returned a
/// hard-coded anchor, so folders with more than one page of children were silently truncated and no
/// remote change was ever reported.
public final class DriveEnumerator: NSObject, NSFileProviderEnumerator {

    public enum Kind: Sendable {
        case container(parentDriveID: String)
        case trash
        case workingSet
    }

    /// Changes pages drained before the enumerator reports back with `moreComing`.
    ///
    /// Drive's pages hold up to 1000 changes, so this caps one `enumerateChanges` call at roughly
    /// 10000 objects. Draining the whole feed instead (the old behaviour) holds every one of them in
    /// memory before the first reply, which an extension cannot afford on a large Drive; the resume
    /// token makes the rest arrive in the next call.
    static let changesPagesPerEnumeration = 10

    private let kind: Kind
    private let services: ProviderServices
    private let stateGate = NSLock()
    private var runningTasks: [Task<Void, Never>] = []
    private var openGates: [any ObserverGateProtocol] = []
    private var isInvalidated = false

    public init(kind: Kind, services: ProviderServices) {
        self.kind = kind
        self.services = services
        super.init()
    }

    /// Which of the three shapes this enumerator serves, in the form the system's own log uses so the
    /// two can be read side by side.
    private var kindLabel: String {
        switch kind {
        case .container(let parentDriveID): return "container(\(parentDriveID))"
        case .trash: return "trash"
        case .workingSet: return "workingSet"
        }
    }

    public func invalidate() {
        ProviderLog.note("invalidate \(kindLabel)")
        stateGate.lock()
        isInvalidated = true
        let tasks = runningTasks
        let gates = openGates
        runningTasks.removeAll()
        openGates.removeAll()
        stateGate.unlock()
        // Closing the observers before cancelling is what makes the drop reliable: a task suspended
        // inside a Drive request keeps running after cancellation and would otherwise reply to an
        // observer the system has already discarded.
        gates.forEach { $0.close() }
        tasks.forEach { $0.cancel() }
    }

    /// Starts work only if this enumerator is still wanted.
    ///
    /// A `Task` begins running the moment it is created, so a flag checked afterwards cannot stop a
    /// discarded enumeration from spending the Drive requests it was about to make. The check and the
    /// registration therefore happen under the same lock `invalidate()` takes, which makes the order
    /// between the two total: either invalidation wins and no task exists, or the task exists and
    /// invalidation cancels it.
    private func start(gate: (any ObserverGateProtocol)? = nil,
                       dropped: (@Sendable () -> Void)? = nil,
                       _ work: @escaping @Sendable () async -> Void) {
        stateGate.lock()
        defer { stateGate.unlock() }
        if isInvalidated {
            ProviderLog.note("dropped work on invalidated \(kindLabel)")
            gate?.close()
            dropped?()
            return
        }
        let task = Task { await work() }
        runningTasks.append(task)
        if let gate { openGates.append(gate) }
    }

    /// Called by a finished task so neither it nor its observer outlives the enumeration.
    private func retire(_ gate: any ObserverGateProtocol) {
        stateGate.lock()
        defer { stateGate.unlock() }
        if let index = openGates.firstIndex(where: { $0 === gate }) {
            openGates.remove(at: index)
        }
        gate.close()
    }

    // MARK: Items

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                               startingAt page: NSFileProviderPage) {
        let token = ProviderCursor.drivePageToken(from: page)
        let kind = self.kind
        let services = self.services
        let gate = ObserverGate(observer)
        let label = kindLabel
        ProviderLog.note("items begin \(label) page=\(token == nil ? "first" : "continued")")

        start(gate: gate) {
            defer { self.retire(gate) }
            do {
                try Task.checkCancellation()
                switch kind {
                case .container(let parentDriveID):
                    let includeTrashed = await services.listsTrashedChildren(
                        parentDriveID: parentDriveID)
                    let result = try await services.drive.childrenPage(
                        parentID: parentDriveID, pageToken: token, includeTrashed: includeTrashed)
                    // Before mapping, so the first root enumeration is parented with the alias it
                    // just observed instead of the raw folder id.
                    await services.observeRootListing(parentDriveID: parentDriveID,
                                                      files: result.fileList)
                    let items = await services.items(from: result.fileList)
                    let nextPage = self.next(result)
                    ProviderLog.note("items done \(label) returned=\(result.fileList.count) "
                                     + "published=\(items.count) more=\(nextPage != nil)")
                    gate.perform { $0.didEnumerate(items) }
                    gate.perform { $0.finishEnumerating(upTo: nextPage) }

                case .trash:
                    let result = try await services.drive.trashedPage(pageToken: token)
                    let items = await services.items(from: result.fileList)
                    let nextPage = self.next(result)
                    ProviderLog.note("items done trash returned=\(result.fileList.count) "
                                     + "published=\(items.count) more=\(nextPage != nil)")
                    gate.perform { $0.didEnumerate(items) }
                    gate.perform { $0.finishEnumerating(upTo: nextPage) }

                case .workingSet:
                    // The working set is delivered through changes, not through an item listing: the
                    // disk replica is built from container enumerations, so claiming a listing here
                    // would either duplicate it or pretend to have walked the whole Drive.
                    gate.perform { $0.finishEnumerating(upTo: nil) }
                }
            } catch {
                ProviderLog.failure("items failed \(label) error=\(error)")
                gate.perform { $0.finishEnumeratingWithError(ProviderErrorMapper.bridge(error)) }
            }
        }
    }

    private func next(_ page: DriveChildrenPage) -> NSFileProviderPage? {
        guard let token = page.nextPageToken, !token.isEmpty else { return nil }
        return ProviderCursor.page(drivePageToken: token)
    }

    // MARK: Changes

    public func enumerateChanges(for observer: NSFileProviderChangeObserver,
                                 from syncAnchor: NSFileProviderSyncAnchor) {
        let requested = ProviderCursor.driveStartToken(from: syncAnchor)
        let kind = self.kind
        let services = self.services
        let gate = ObserverGate(observer)
        let label = kindLabel
        ProviderLog.note("changes begin \(label) anchor=\(requested ?? "none")")

        start(gate: gate) {
            defer { self.retire(gate) }
            do {
                try Task.checkCancellation()
                switch kind {
                case .workingSet:
                    try await self.enumerateWorkingSetChanges(gate: gate, requested: requested)
                case .container(let parentDriveID):
                    try await self.enumerateScopedChanges(gate: gate, requested: requested,
                                                          include: { $0.parentID == parentDriveID })
                case .trash:
                    try await self.enumerateScopedChanges(gate: gate, requested: requested,
                                                          include: { $0.isTrashed })
                }
            } catch {
                ProviderLog.failure("changes failed \(label) error=\(error)")
                if ProviderErrorMapper.isAnchorExpired(error) {
                    try? await services.state.clearSyncCursor()
                }
                gate.perform {
                    $0.finishEnumeratingWithError(ProviderErrorMapper.bridge(error))
                }
            }
        }
    }

    /// The working set is the whole Drive, so the complete changes feed is drained and published.
    private func enumerateWorkingSetChanges(gate: ObserverGate<NSFileProviderChangeObserver>,
                                            requested: String?) async throws {
        guard let requested else {
            // First contact: take a token and publish nothing. Everything the system learns after
            // this point arrives through the next enumeration.
            let baseline = try await services.drive.startChangeToken()
            try await services.state.setSyncCursor(baseline)
            gate.perform {
                $0.finishEnumeratingChanges(
                    upTo: ProviderCursor.anchor(driveStartToken: baseline), moreComing: false)
            }
            return
        }

        let batch = try await services.drive.collectChanges(
            from: requested, maxPages: Self.changesPagesPerEnumeration)

        let counts = try await publish(changes: batch.changes, through: gate)
        let anchor = anchorAfter(batch, fallback: requested)
        ProviderLog.note("changes done \(kindLabel) returned=\(batch.changes.count) "
                         + "updated=\(counts.updated) deleted=\(counts.deleted) "
                         + "anchor=\(anchor) more=\(batch.truncated)")

        if batch.truncated, let resume = batch.resumeToken {
            gate.perform {
                $0.finishEnumeratingChanges(
                    upTo: ProviderCursor.anchor(driveStartToken: resume), moreComing: true)
            }
            return
        }

        try await services.state.setSyncCursor(anchor)
        gate.perform {
            $0.finishEnumeratingChanges(
                upTo: ProviderCursor.anchor(driveStartToken: anchor), moreComing: false)
        }
    }

    /// Container enumerators report only what changed inside the folder the user is looking at.
    private func enumerateScopedChanges(gate: ObserverGate<NSFileProviderChangeObserver>,
                                        requested: String?,
                                        include: @escaping (DriveFile) -> Bool) async throws {
        let current = await services.state.syncCursor()
        guard let requested, requested != current else {
            // Either the anchor is unknown (a fresh baseline is published by the working set) or it
            // already matches the newest token we know, so there is nothing to report here.
            let anchor = requested ?? current ?? ""
            gate.perform {
                $0.finishEnumeratingChanges(
                    upTo: ProviderCursor.anchor(driveStartToken: anchor), moreComing: false)
            }
            return
        }

        let batch = try await services.drive.collectChanges(
            from: requested, maxPages: Self.changesPagesPerEnumeration)
        // Removals are passed through unfiltered: an identifier the system does not have in this
        // container is a no-op, while dropping it here would leave a stale file on disk.
        let relevant = batch.changes.filter { change in
            guard let file = change.file else { return true }
            return include(file)
        }
        let counts = try await publish(changes: relevant, through: gate)

        // A truncated drain has no terminal start token yet, so the anchor handed back is the resume
        // token: reporting the token the call started from would rewind the system's cursor.
        let anchor = anchorAfter(batch, fallback: requested)
        let moreComing = batch.truncated
        ProviderLog.note("changes done \(kindLabel) scanned=\(batch.changes.count) "
                         + "matched=\(relevant.count) updated=\(counts.updated) "
                         + "deleted=\(counts.deleted) anchor=\(anchor) more=\(moreComing)")
        gate.perform {
            $0.finishEnumeratingChanges(
                upTo: ProviderCursor.anchor(driveStartToken: anchor), moreComing: moreComing)
        }
    }

    /// The token that describes "everything up to this batch", preferring the terminal token Drive
    /// itself returns for the drain.
    ///
    /// When Drive answers with an empty page it still includes `newStartPageToken`, so this is what
    /// lets a quiet poll advance instead of handing the caller's own token back. Falling back to
    /// `requested` keeps the cursor from rewinding when a response omits both tokens.
    private func anchorAfter(_ batch: DriveChangeBatch, fallback: String?) -> String {
        batch.startPageToken ?? batch.resumeToken ?? fallback ?? ""
    }

    /// Publishes a batch and reports how much of it reached the observer, which is what distinguishes
    /// "Drive had no changes" from "the gate closed mid-publish".
    @discardableResult
    private func publish(changes: [DriveChange],
                         through gate: ObserverGate<NSFileProviderChangeObserver>) async throws
        -> (updated: Int, deleted: Int) {
        guard !changes.isEmpty else { return (0, 0) }

        var hint: Int?
        gate.perform { hint = $0.suggestedBatchSize }
        // `suggestedBatchSize` is an optional Objective-C property: an observer that does not answer
        // it is saying "no preference", not "publish nothing".
        let batchSize = max(1, hint ?? 256)
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        var sent = (updated: 0, deleted: 0)
        updated.reserveCapacity(batchSize)

        for change in changes {
            try Task.checkCancellation()

            if change.isRemoved {
                deleted.append(ProviderIdentity.identifier(forDriveID: change.fileId))
            } else if let file = change.file {
                // Shortcuts are followed here too: a pointer published as a file is a row Finder
                // cannot open.
                let resolved = await services.resolveShortcut(file)
                await services.cache.store(resolved)
                updated.append(await services.item(for: resolved))
            } else {
                // `removed` false with no `file` happens when the change refers to something the
                // caller can no longer read; ask Drive, which answers 404 and we treat it as deleted.
                do {
                    let file = try await services.drive.file(id: change.fileId)
                    await services.cache.store(file)
                    updated.append(await services.item(for: file))
                } catch let error as DriveError {
                    if case .itemNotFound = error {
                        deleted.append(ProviderIdentity.identifier(forDriveID: change.fileId))
                    } else {
                        throw error
                    }
                }
            }

            if updated.count >= batchSize {
                let batch = updated
                updated.removeAll(keepingCapacity: true)
                if gate.perform({ $0.didUpdate(batch) }) { sent.updated += batch.count }
            }
            if deleted.count >= batchSize {
                let batch = deleted
                deleted.removeAll(keepingCapacity: true)
                if gate.perform({ $0.didDeleteItems(withIdentifiers: batch) }) {
                    sent.deleted += batch.count
                }
            }
        }

        if !updated.isEmpty {
            let batch = updated
            if gate.perform({ $0.didUpdate(batch) }) { sent.updated += batch.count }
        }
        if !deleted.isEmpty {
            let batch = deleted
            if gate.perform({ $0.didDeleteItems(withIdentifiers: batch) }) {
                sent.deleted += batch.count
            }
        }
        return sent
    }

    // MARK: Anchor

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let services = self.services
        let label = kindLabel
        ProviderLog.note("anchor begin \(label)")
        start(dropped: { completionHandler(nil) }) {
            if let stored = await services.state.syncCursor() {
                ProviderLog.note("anchor done \(label) stored")
                completionHandler(ProviderCursor.anchor(driveStartToken: stored))
                return
            }
            do {
                let fresh = try await services.drive.startChangeToken()
                try? await services.state.setSyncCursor(fresh)
                ProviderLog.note("anchor done \(label) fetched")
                completionHandler(ProviderCursor.anchor(driveStartToken: fresh))
            } catch {
                ProviderLog.failure("anchor failed \(label) error=\(error)")
                // No anchor at all makes the system retry, which is right: inventing one would let
                // it believe it was up to date.
                completionHandler(nil)
            }
        }
    }
}

/// Gates that must be closed when the system discards an enumerator.
private protocol ObserverGateProtocol: AnyObject {
    func close()
}

/// An observer that can be silenced.
///
/// `invalidate()` cancels the task, but cancellation cannot interrupt a request already suspended
/// inside `URLSession`, and the reply from that request would otherwise reach an observer File
/// Provider threw away. Every call therefore goes through this gate, which drops it once the
/// enumerator is gone. File Provider observers do not call back into the enumerator, so holding the
/// lock across the reply is what makes "closed means never called again" true rather than likely.
private final class ObserverGate<Observer>: ObserverGateProtocol {
    private let lock = NSLock()
    private var observer: Observer?

    init(_ observer: Observer) {
        self.observer = observer
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        observer = nil
    }

    /// Delivers to the observer and reports whether the gate was still open. A publisher that cannot
    /// tell a dropped batch from an empty one cannot explain why the Finder location stayed stale.
    @discardableResult
    func perform(_ body: (Observer) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let observer else { return false }
        body(observer)
        return true
    }
}
