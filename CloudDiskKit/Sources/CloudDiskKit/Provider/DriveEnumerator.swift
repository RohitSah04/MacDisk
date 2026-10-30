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

    private let kind: Kind
    private let services: ProviderServices
    private let stateGate = NSLock()
    private var runningTasks: [Task<Void, Never>] = []
    private var isInvalidated = false

    public init(kind: Kind, services: ProviderServices) {
        self.kind = kind
        self.services = services
        super.init()
    }

    public func invalidate() {
        stateGate.lock()
        isInvalidated = true
        let tasks = runningTasks
        runningTasks.removeAll()
        stateGate.unlock()
        tasks.forEach { $0.cancel() }
    }

    /// Starts work unless the system already discarded this enumerator, in which case the task is
    /// cancelled before it can touch an observer that no longer exists.
    private func track(_ task: Task<Void, Never>) {
        stateGate.lock()
        defer { stateGate.unlock() }
        if isInvalidated {
            task.cancel()
        } else {
            runningTasks.append(task)
        }
    }

    // MARK: Items

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                               startingAt page: NSFileProviderPage) {
        let token = ProviderCursor.drivePageToken(from: page)
        let kind = self.kind
        let services = self.services

        track(Task {
            do {
                switch kind {
                case .container(let parentDriveID):
                    let result = try await services.drive.childrenPage(parentID: parentDriveID,
                                                                       pageToken: token)
                    observer.didEnumerate(await services.items(from: result.fileList))
                    observer.finishEnumerating(upTo: next(result))

                case .trash:
                    let result = try await services.drive.trashedPage(pageToken: token)
                    observer.didEnumerate(await services.items(from: result.fileList))
                    observer.finishEnumerating(upTo: next(result))

                case .workingSet:
                    // The working set is delivered through changes, not through an item listing: the
                    // disk replica is built from container enumerations, so claiming a listing here
                    // would either duplicate it or pretend to have walked the whole Drive.
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(ProviderErrorMapper.bridge(error))
            }
        })
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

        track(Task {
            do {
                switch kind {
                case .workingSet:
                    try await enumerateWorkingSetChanges(observer: observer, requested: requested)
                case .container(let parentDriveID):
                    try await enumerateScopedChanges(observer: observer, requested: requested,
                                                     include: { $0.parentID == parentDriveID })
                case .trash:
                    try await enumerateScopedChanges(observer: observer, requested: requested,
                                                     include: { $0.isTrashed })
                }
            } catch {
                observer.finishEnumeratingWithError(ProviderErrorMapper.bridge(error))
            }
        })
    }

    /// The working set is the whole Drive, so the complete changes feed is drained and published.
    private func enumerateWorkingSetChanges(observer: NSFileProviderChangeObserver,
                                            requested: String?) async throws {
        guard let requested else {
            // First contact: take a token and publish nothing. Everything the system learns after
            // this point arrives through the next enumeration.
            let baseline = try await services.drive.startChangeToken()
            try await services.state.setSyncCursor(baseline)
            observer.finishEnumeratingChanges(upTo: ProviderCursor.anchor(driveStartToken: baseline),
                                              moreComing: false)
            return
        }

        let batch = try await services.drive.collectChanges(from: requested)
        if batch.removedEverything {
            // Google dropped our history; the only honest answer is to expire the anchor and let the
            // system re-scan, which it does far more cheaply than a provider could fake.
            throw NSFileProviderError(.syncAnchorExpired)
        }

        try await publish(changes: batch.changes, to: observer, filter: nil)

        if batch.truncated, let resume = batch.resumeToken {
            observer.finishEnumeratingChanges(upTo: ProviderCursor.anchor(driveStartToken: resume),
                                              moreComing: true)
            return
        }

        let anchor = batch.startPageToken ?? requested
        try await services.state.setSyncCursor(anchor)
        observer.finishEnumeratingChanges(upTo: ProviderCursor.anchor(driveStartToken: anchor),
                                          moreComing: false)
    }

    /// Container enumerators report only what changed inside the folder the user is looking at.
    private func enumerateScopedChanges(observer: NSFileProviderChangeObserver,
                                        requested: String?,
                                        include: @escaping (DriveFile) -> Bool) async throws {
        let current = await services.state.syncCursor()
        guard let requested, requested != current else {
            // Either the anchor is unknown (a fresh baseline is published by the working set) or it
            // already matches the newest token we know, so there is nothing to report here.
            observer.finishEnumeratingChanges(
                upTo: ProviderCursor.anchor(driveStartToken: requested ?? current ?? ""),
                moreComing: false)
            return
        }

        let batch = try await services.drive.collectChanges(from: requested)
        if batch.removedEverything { throw NSFileProviderError(.syncAnchorExpired) }
        // Removals are passed through unfiltered: an identifier the system does not have in this
        // container is a no-op, while dropping it here would leave a stale file on disk.
        let relevant = batch.changes.filter { change in
            guard let file = change.file else { return true }
            return include(file)
        }
        try await publish(changes: relevant, to: observer, filter: nil)

        let anchor = batch.startPageToken ?? requested
        observer.finishEnumeratingChanges(upTo: ProviderCursor.anchor(driveStartToken: anchor),
                                          moreComing: batch.truncated)
    }

    private func publish(changes: [DriveChange],
                         to observer: NSFileProviderChangeObserver,
                         filter: ((DriveFile) -> Bool)?) async throws {
        guard !changes.isEmpty else { return }

        let batchSize = max(1, Int(observer.suggestedBatchSize ?? 256))
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        updated.reserveCapacity(batchSize)

        for change in changes {
            try Task.checkCancellation()

            if change.isRemoved {
                deleted.append(ProviderIdentity.identifier(forDriveID: change.fileId))
            } else if var file = change.file {
                if file.isShortcut, let target = file.shortcutDetails?.targetId {
                    // A shortcut is a pointer to another object; Finder needs the target's metadata
                    // to show a real file, so the pointer is followed before publishing.
                    if let resolved = try? await services.drive.file(id: target) { file = resolved }
                }
                if filter == nil || filter?(file) == true {
                    await services.cache.store(file)
                    updated.append(await services.item(for: file))
                }
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
                observer.didUpdate(updated)
                updated.removeAll(keepingCapacity: true)
            }
            if deleted.count >= batchSize {
                observer.didDeleteItems(withIdentifiers: deleted)
                deleted.removeAll(keepingCapacity: false)
            }
        }

        if !updated.isEmpty { observer.didUpdate(updated) }
        if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
    }

    // MARK: Anchor

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let services = self.services
        track(Task {
            if let stored = await services.state.syncCursor() {
                completionHandler(ProviderCursor.anchor(driveStartToken: stored))
                return
            }
            do {
                let fresh = try await services.drive.startChangeToken()
                try? await services.state.setSyncCursor(fresh)
                completionHandler(ProviderCursor.anchor(driveStartToken: fresh))
            } catch {
                // No anchor at all makes the system retry, which is right: inventing one would let
                // it believe it was up to date.
                completionHandler(nil)
            }
        })
    }
}
