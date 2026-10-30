import Foundation
@preconcurrency import FileProvider
import UniformTypeIdentifiers

/// The business logic behind the File Provider extension.
///
/// Kept separate from `CloudDiskFileProviderAgent` so that every rule — identifier mapping, version
/// handling, conflict policy, reimport matching — can be exercised in unit tests without
/// `fileproviderd` involvement.
public actor CloudDiskProviderCore {

    public struct FetchedContent: Sendable {
        public let url: URL
        public let item: NSFileProviderItem
    }

    public struct WriteOutcome: Sendable {
        public let item: NSFileProviderItem
        /// Fields the extension did not apply. The system retries them later, or stops sending them,
        /// which is how an unsupported field is reported honestly instead of being silently dropped.
        public let pendingFields: NSFileProviderItemFields
        /// True when the bytes on disk must be replaced by what the provider returns.
        public let shouldFetchContent: Bool

        public init(item: NSFileProviderItem,
                    pendingFields: NSFileProviderItemFields = [],
                    shouldFetchContent: Bool = false) {
            self.item = item
            self.pendingFields = pendingFields
            self.shouldFetchContent = shouldFetchContent
        }
    }

    public enum CoreError: LocalizedError, Equatable {
        case unknownIdentifier(String)
        case cannotCreateInTrash
        case unsupportedKind(String)
        case directoryNotEmpty(String)

        public var errorDescription: String? {
            switch self {
            case .unknownIdentifier(let id):
                return "CloudDisk no longer knows the item “\(id)” in Google Drive."
            case .cannotCreateInTrash:
                return "Google Drive has no way to add a file directly to the trash."
            case .unsupportedKind(let kind):
                return "Google Drive cannot store this kind of item: \(kind)."
            case .directoryNotEmpty(let name):
                return "“\(name)” still contains files, so it cannot be deleted without emptying it."
            }
        }
    }

    /// Metadata File Provider may ask us to write that Google Drive computes for itself.
    static let nonWritableFields: [NSFileProviderItemFields] = [
        .creationDate, .contentModificationDate, .fileSystemFlags, .extendedAttributes
    ]

    public let services: ProviderServices

    public init(services: ProviderServices) {
        self.services = services
    }

    // MARK: - Reading

    /// Pure identifier arithmetic, so the enumerator can be created synchronously as the protocol
    /// requires without hopping onto the actor.
    nonisolated public func enumeratorKind(for identifier: NSFileProviderItemIdentifier) throws -> DriveEnumerator.Kind {
        switch identifier {
        case ProviderIdentity.workingSetIdentifier:
            return .workingSet
        case ProviderIdentity.trashIdentifier:
            return .trash
        case ProviderIdentity.rootIdentifier:
            return .container(parentDriveID: DriveFile.rootFolderID)
        default:
            guard let driveID = ProviderIdentity.driveID(for: identifier) else {
                throw CoreError.unknownIdentifier(identifier.rawValue)
            }
            return .container(parentDriveID: driveID)
        }
    }

    public func item(for identifier: NSFileProviderItemIdentifier) async throws -> NSFileProviderItem {
        switch identifier {
        case ProviderIdentity.rootIdentifier:
            return services.rootItem
        case ProviderIdentity.trashIdentifier:
            return DriveFileProviderItem.trashContainer()
        case ProviderIdentity.workingSetIdentifier:
            return DriveFileProviderItem.workingSetContainer()
        default:
            let file = try await driveFile(for: identifier)
            return services.item(for: file, pinned: await services.state.isPinned(file.id))
        }
    }

    /// Metadata for an identifier, served from the cache when fresh so one Finder click does not fan
    /// out into a dozen Drive requests.
    public func driveFile(for identifier: NSFileProviderItemIdentifier) async throws -> DriveFile {
        guard let driveID = ProviderIdentity.driveID(for: identifier) else {
            throw CoreError.unknownIdentifier(identifier.rawValue)
        }
        return try await services.cache.value(forDriveID: driveID) { [drive = services.drive] in
            try await drive.file(id: driveID)
        }
    }

    /// Downloads the whole object into the directory the system reserved for it.
    ///
    /// The bytes go straight to disk, so a 40 GB file never enters memory, and the item handed back is
    /// built from the metadata fetched alongside that download so its version describes the content on
    /// disk.
    ///
    /// `requestedVersion` is the version the system believes it is missing. CloudDisk cannot address a
    /// Drive revision, so when the server copy no longer matches it the download is discarded and the
    /// version is reported unavailable rather than answered with newer bytes.
    public func fetchContents(for identifier: NSFileProviderItemIdentifier,
                              requestedVersion: NSFileProviderItemVersion?,
                              progress: Progress) async throws -> FetchedContent {
        let driveID = try requireDriveID(identifier)
        let destination = try services.temporaryFileURL()

        do {
            let file = try await services.drive.download(fileID: driveID, to: destination,
                                                          progress: progress)
            if let requestedVersion,
               !requestedVersion.contentVersion.isEmpty,
               !ProviderIdentity.contentVersion(requestedVersion.contentVersion, matches: file) {
                try? FileManager.default.removeItem(at: destination)
                throw DriveError.versionUnavailable
            }
            await services.cache.store(file)
            let pinned = await services.state.isPinned(driveID)
            try await services.state.record(.init(kind: .download, outcome: .success, subject: file.name))
            return FetchedContent(url: destination, item: services.item(for: file, pinned: pinned))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await reportFailure(.download, subject: driveID, error: error)
            throw error
        }
    }

    // MARK: - Writing

    public func create(basedOn template: NSFileProviderItem,
                       fields: NSFileProviderItemFields,
                       contents: URL?,
                       options: NSFileProviderCreateItemOptions,
                       progress: Progress) async throws -> WriteOutcome {
        let parentIdentifier = template.parentItemIdentifier
        if parentIdentifier == ProviderIdentity.trashIdentifier {
            throw CoreError.cannotCreateInTrash
        }
        let parentID = ProviderIdentity.driveID(for: parentIdentifier) ?? DriveFile.rootFolderID
        let name = ProviderFilename.materializable(template.filename)
        // A template imported from disk can legitimately have no resolvable type; Drive then stores it
        // as a binary object rather than the extension inventing a MIME type.
        let declaredType = template.contentType
        if declaredType == .symbolicLink || declaredType == .aliasFile {
            throw CoreError.unsupportedKind(declaredType?.preferredMIMEType ?? "link")
        }
        let isFolder = declaredType.map { $0 == .folder || $0.conforms(to: .folder) } ?? false

        // A reimport (after a restart, a backup restore, or a domain move) replays files that already
        // exist on disk. Matching them to the server copy is what keeps a restart from duplicating
        // everything the user had locally.
        if options.contains(.mayAlreadyExist),
           let matched = try await resolveReimport(name: name, parentID: parentID, localContent: contents) {
            return WriteOutcome(item: matched.item, shouldFetchContent: matched.fetchContent)
        }

        let mimeType = isFolder ? DriveFile.folderMimeType
            : (declaredType?.preferredMIMEType ?? "application/octet-stream")

        let created: DriveFile
        do {
            if isFolder {
                created = try await services.drive.createFolder(name: name, parentID: parentID)
            } else if let contents {
                created = try await services.drive.upload(fileURL: contents, name: name,
                                                          parentID: parentID, mimeType: mimeType,
                                                          progress: progress)
            } else {
                // A dataless item replayed from disk arrives with no content. Drive can store an
                // empty object, so create one instead of failing the import.
                let placeholder = try makeEmptyFile()
                defer { try? FileManager.default.removeItem(at: placeholder) }
                created = try await services.drive.upload(fileURL: placeholder, name: name,
                                                          parentID: parentID, mimeType: mimeType,
                                                          progress: progress)
            }
        } catch {
            await reportFailure(.upload, subject: name, error: error)
            throw error
        }

        await services.cache.store(created)
        try await services.state.record(.init(kind: created.isFolder ? .create : .upload,
                                              outcome: .success, subject: created.name))
        return WriteOutcome(item: services.item(for: created,
                                                pinned: await services.state.isPinned(created.id)))
    }

    public func modify(_ item: NSFileProviderItem,
                       baseVersion: NSFileProviderItemVersion,
                       changedFields: NSFileProviderItemFields,
                       contents newContents: URL?,
                       options: NSFileProviderModifyItemOptions,
                       progress: Progress) async throws -> WriteOutcome {
        let driveID = try requireDriveID(item.itemIdentifier)
        let current = try await services.drive.file(id: driveID)
        let pinned = await services.state.isPinned(driveID)

        if current.isGoogleNative && !current.isFolder {
            // Workspace documents are exported on read and have no upload path, so none of their
            // fields can be written. Declaring every requested field still pending is the extension
            // saying "not supported" without failing the user's action.
            return WriteOutcome(item: services.item(for: current, pinned: pinned),
                                pendingFields: changedFields)
        }

        var pending = NSFileProviderItemFields()
        for field in Self.nonWritableFields where changedFields.contains(field) {
            pending.insert(field)
        }

        var result = current
        var shouldFetchContent = false

        if changedFields.contains(.contents), let newContents {
            let upload = try await uploadContent(newContents, onto: current, baseVersion: baseVersion,
                                                 newName: changedFields.contains(.filename)
                                                    ? ProviderFilename.materializable(item.filename)
                                                    : nil,
                                                 options: options, progress: progress)
            result = upload.item
            shouldFetchContent = upload.replaceLocalBytes
        } else if changedFields.contains(.contents) {
            // Asked to sync content with nothing to upload: the disk copy is authoritative and already
            // matches, so acknowledge without touching the server.
            pending.insert(.contents)
        }

        if changedFields.contains(.filename), result.name != item.filename {
            result = try await services.drive.rename(fileID: result.id,
                                                     to: ProviderFilename.materializable(item.filename))
        }

        if changedFields.contains(.parentItemIdentifier) {
            let newParentID = ProviderIdentity.driveID(for: item.parentItemIdentifier)
                ?? DriveFile.rootFolderID
            if newParentID != current.parentID {
                result = try await services.drive.move(fileID: result.id,
                                                       from: current.parentID ?? DriveFile.rootFolderID,
                                                       to: newParentID)
            }
        }

        // `favoriteRank` is deliberately not handled: it is an iOS-only member of
        // NSFileProviderItem, so macOS never asks for it and Drive's starred flag is surfaced in
        // CloudDisk's own browser instead.
        if changedFields.contains(.tagData) {
            // Drive's label data is not exposed through the API, so Finder colour labels cannot land.
            pending.insert(.tagData)
        }

        await services.cache.invalidate(driveID)
        await services.cache.store(result)
        try await services.state.record(.init(kind: Self.activityKind(for: changedFields),
                                              outcome: .success, subject: result.name))

        return WriteOutcome(item: services.item(for: result, pinned: pinned),
                            pendingFields: pending,
                            shouldFetchContent: shouldFetchContent)
    }

    public func delete(identifier: NSFileProviderItemIdentifier,
                       baseVersion: NSFileProviderItemVersion?,
                       options: NSFileProviderDeleteItemOptions) async throws {
        let driveID = try requireDriveID(identifier)

        if !options.contains(.recursive) {
            let children = try await services.drive.childrenPage(parentID: driveID)
            if let first = children.fileList.first {
                throw CoreError.directoryNotEmpty(first.name)
            }
        }

        do {
            // Drive's `files.delete` moves the object to the trash, and deleting an object that is
            // already trashed removes it for good — the same two cases File Provider distinguishes.
            try await services.drive.delete(fileID: driveID)
            await services.cache.invalidate(driveID)
            try await services.state.record(.init(kind: .delete, outcome: .success, subject: driveID))
        } catch let error as DriveError {
            if case .itemNotFound = error {
                // Already gone remotely: the requested state holds, so report success as Apple requires.
                await services.cache.invalidate(driveID)
                return
            }
            await reportFailure(.delete, subject: driveID, error: error)
            throw error
        }
    }

    // MARK: - Restart and reimport

    /// Called after the system rebuilds the disk replica. The changes cursor is the only state that
    /// has to exist for updates to flow again, so this is where a fresh install or a restored machine
    /// establishes it.
    public func importDidFinish() async {
        if await services.state.syncCursor() == nil {
            guard let baseline = try? await services.drive.startChangeToken() else { return }
            try? await services.state.setSyncCursor(baseline)
        }
        await services.signalWorkingSet()
    }

    // MARK: - Helpers

    private func requireDriveID(_ identifier: NSFileProviderItemIdentifier) throws -> String {
        guard let driveID = ProviderIdentity.driveID(for: identifier) else {
            throw CoreError.unknownIdentifier(identifier.rawValue)
        }
        return driveID
    }

    static func activityKind(for fields: NSFileProviderItemFields) -> ProviderState.ActivityEvent.Kind {
        if fields.contains(.contents) { return .upload }
        if fields.contains(.parentItemIdentifier) { return .move }
        if fields.contains(.filename) { return .rename }
        return .synchronize
    }

    private func reportFailure(_ kind: ProviderState.ActivityEvent.Kind,
                               subject: String,
                               error: Error) async {
        let outcome: ProviderState.ActivityEvent.Outcome =
            (error is CancellationError) ? .cancelled : .failure
        // Detail is the user-facing sentence only: it never contains tokens or response bodies.
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        try? await services.state.record(.init(kind: kind, outcome: outcome,
                                               subject: subject, detail: detail))
    }

    // MARK: Reimport matching

    /// Finds the server object a reimported disk file most likely refers to.
    private func resolveReimport(name: String,
                                 parentID: String,
                                 localContent: URL?) async throws
        -> (item: NSFileProviderItem, fetchContent: Bool)? {
        guard let match = (try? await services.drive.exactMatches(named: name, in: parentID))?.first else {
            return nil
        }
        await services.cache.store(match)

        guard let localContent, match.hasMediaContent else {
            return (services.item(for: match, pinned: await services.state.isPinned(match.id)), false)
        }

        // Same size means the disk copy already is the server copy; anything else is a local edit that
        // survived a restore, so its bytes are pushed onto the matched object rather than discarded.
        if DriveService.byteCount(of: localContent) == match.byteCount {
            return (services.item(for: match, pinned: await services.state.isPinned(match.id)), false)
        }

        let updated = try await services.drive.replaceContents(of: match.id, with: localContent,
                                                              name: match.name)
        await services.cache.store(updated)
        return (services.item(for: updated, pinned: await services.state.isPinned(updated.id)), false)
    }

    private func makeEmptyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-empty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: Content upload and conflicts

    /// Uploads the disk copy, keeping the user's local edits and the remote edits both.
    ///
    /// - Parameter replaceLocalBytes: the remote version won and the system must re-download it.
    private func uploadContent(_ newContents: URL,
                               onto current: DriveFile,
                               baseVersion: NSFileProviderItemVersion,
                               newName: String?,
                               options: NSFileProviderModifyItemOptions,
                               progress: Progress) async throws
        -> (item: DriveFile, replaceLocalBytes: Bool) {
        // An empty version means the system never received one for this item, so there is no server
        // snapshot to have diverged from; anything else is compared byte for byte against the version
        // the freshly fetched Drive object would be published with.
        let diverged = !baseVersion.contentVersion.isEmpty
            && !ProviderIdentity.contentVersion(baseVersion.contentVersion, matches: current)

        if !diverged {
            let updated = try await services.drive.replaceContents(of: current.id, with: newContents,
                                                                   name: newName, progress: progress)
            return (updated, false)
        }

        if #available(macOS 26.0, *) , options.contains(.failOnConflict) {
            throw NSFileProviderError(.localVersionConflictingWithServer) as NSError
        }

        // Nothing is thrown away: the remote object keeps its newest version, the local bytes become a
        // separate file, and the disk copy is refreshed from the server. This is the same resolution
        // Drive's own desktop client applies.
        let conflictedName = ProviderFilename.materializable(Self.conflictedCopyName(for: current))
        _ = try await services.drive.upload(fileURL: newContents,
                                            name: conflictedName,
                                            parentID: current.parentID ?? DriveFile.rootFolderID,
                                            mimeType: current.mimeType,
                                            progress: progress)
        try await services.state.record(.init(kind: .synchronize, outcome: .success,
                                              subject: current.name,
                                              detail: "Kept remote and local edits as two files"))
        return (current, true)
    }

    static func conflictedCopyName(for file: DriveFile) -> String {
        let stem = (file.name as NSString).deletingPathExtension
        let ext = (file.name as NSString).pathExtension
        let suffix = " (conflicted copy)"
        return ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
    }
}
