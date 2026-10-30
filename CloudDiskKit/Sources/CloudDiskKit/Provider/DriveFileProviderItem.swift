import Foundation
import FileProvider
import UniformTypeIdentifiers

/// An `NSFileProviderItem` that mirrors one Google Drive object.
///
/// Immutable: the system may hold an item across threads and calls, so any mutable state here would
/// have to be synchronised. A new instance is produced for every lookup instead.
public final class DriveFileProviderItem: NSObject, NSFileProviderItem {

    public enum VirtualContainer: String {
        case root, trash, workingSet
    }

    private let backing: Backing

    /// Everything the item reports, decoupled from the network so the mapping can be unit tested.
    struct Backing {
        var identifier: NSFileProviderItemIdentifier
        var parentIdentifier: NSFileProviderItemIdentifier
        var filename: String
        var contentType: UTType
        var capabilities: NSFileProviderItemCapabilities
        var documentSize: NSNumber?
        var childItemCount: NSNumber?
        var creationDate: Date?
        var modificationDate: Date?
        var itemVersion: NSFileProviderItemVersion
        var isFolder: Bool
        var isShared: Bool
        var isSharedByCurrentUser: Bool
        var ownerName: String?
        var contentPolicy: NSFileProviderContentPolicy
        /// True when Drive holds no bytes for this object and a download must go through export.
        var isWorkspaceDocument: Bool
    }

    private init(_ backing: Backing) {
        self.backing = backing
        super.init()
    }

    // MARK: Construction

    /// Wraps a Drive file as it appeared in `parent`, optionally pinned for offline use.
    static func make(from file: DriveFile,
                     contentPolicy: NSFileProviderContentPolicy = .downloadLazily) -> DriveFileProviderItem {
        let identifier = ProviderIdentity.identifier(forDriveID: file.id)
        let isFolder = file.isFolder

        return DriveFileProviderItem(Backing(
            identifier: identifier,
            parentIdentifier: ProviderIdentity.parentIdentifier(for: file),
            filename: ProviderFilename.materializable(file.name),
            contentType: Self.contentType(of: file),
            capabilities: Self.capabilities(of: file),
            // Workspace documents have no byte size until they are exported, and guessing one would
            // make the system truncate or over-extend the materialized file.
            documentSize: isFolder ? nil : (file.hasMediaContent ? file.byteCount.map { NSNumber(value: $0) } : nil),
            childItemCount: nil,
            creationDate: file.parsedCreatedTime,
            modificationDate: file.parsedModifiedTime,
            itemVersion: ProviderIdentity.itemVersion(for: file),
            isFolder: isFolder,
            isShared: file.shared ?? false,
            isSharedByCurrentUser: file.ownedByMe == false && (file.shared ?? false),
            ownerName: file.owners?.first?.displayName ?? file.lastModifyingUser?.displayName,
            contentPolicy: contentPolicy,
            isWorkspaceDocument: file.isGoogleNative && !isFolder
        ))
    }

    static func driveRoot(displayName: String) -> DriveFileProviderItem {
        DriveFileProviderItem(Backing(
            identifier: ProviderIdentity.rootIdentifier,
            parentIdentifier: ProviderIdentity.rootIdentifier,
            filename: ProviderFilename.materializable(displayName),
            contentType: .folder,
            // The root of a Drive is always listable and, with the read/write scope, writable.
            capabilities: [.allowsReading, .allowsContentEnumerating,
                           .allowsWriting, .allowsAddingSubItems],
            documentSize: nil,
            childItemCount: nil,
            creationDate: nil,
            modificationDate: nil,
            itemVersion: NSFileProviderItemVersion(contentVersion: Data("clouddisk-root-v1".utf8),
                                                   metadataVersion: Data("clouddisk-root-v1".utf8)),
            isFolder: true,
            isShared: false,
            isSharedByCurrentUser: false,
            ownerName: nil,
            contentPolicy: .downloadLazily,
            isWorkspaceDocument: false
        ))
    }

    static func trashContainer() -> DriveFileProviderItem {
        DriveFileProviderItem(Backing(
            identifier: ProviderIdentity.trashIdentifier,
            parentIdentifier: ProviderIdentity.rootIdentifier,
            filename: "Trash",
            contentType: .folder,
            // Nothing may be created inside Drive's trash through CloudDisk.
            capabilities: [.allowsReading, .allowsContentEnumerating],
            documentSize: nil,
            childItemCount: nil,
            creationDate: nil,
            modificationDate: nil,
            itemVersion: NSFileProviderItemVersion(contentVersion: Data("clouddisk-trash-v1".utf8),
                                                   metadataVersion: Data("clouddisk-trash-v1".utf8)),
            isFolder: true,
            isShared: false,
            isSharedByCurrentUser: false,
            ownerName: nil,
            contentPolicy: .downloadLazily,
            isWorkspaceDocument: false
        ))
    }

    static func workingSetContainer() -> DriveFileProviderItem {
        DriveFileProviderItem(Backing(
            identifier: ProviderIdentity.workingSetIdentifier,
            parentIdentifier: ProviderIdentity.rootIdentifier,
            filename: CloudDiskConfig.displayName,
            contentType: .folder,
            capabilities: [.allowsReading, .allowsContentEnumerating],
            documentSize: nil,
            childItemCount: nil,
            creationDate: nil,
            modificationDate: nil,
            itemVersion: NSFileProviderItemVersion(contentVersion: Data("clouddisk-ws-v1".utf8),
                                                   metadataVersion: Data("clouddisk-ws-v1".utf8)),
            isFolder: true,
            isShared: false,
            isSharedByCurrentUser: false,
            ownerName: nil,
            contentPolicy: .downloadLazily,
            isWorkspaceDocument: false
        ))
    }

    // MARK: Mappings

    static func contentType(of file: DriveFile) -> UTType {
        if file.isFolder { return .folder }

        // For a Workspace document the bytes the system will receive are the export, so the type has
        // to describe that format or Quick Look and Finder open the file with the wrong handler.
        if file.isGoogleNative {
            if let mimeType = GoogleWorkspaceExport.exportMimeType(for: file),
               let type = UTType(mimeType: mimeType) {
                return type
            }
            return .content
        }

        if let extensionName = file.fileExtension,
           let type = UTType(filenameExtension: extensionName) {
            return type
        }
        if let type = UTType(mimeType: file.mimeType) {
            return type
        }
        // Drive reports no MIME type for some binaries; fall back to the name so a .zip still opens.
        if let type = UTType(filenameExtension: (file.name as NSString).pathExtension) {
            return type
        }
        return .data
    }

    static func capabilities(of file: DriveFile) -> NSFileProviderItemCapabilities {
        let permissions = file.capabilities ?? DriveCapabilities()
        var result: NSFileProviderItemCapabilities = []

        if permissions.isReadable { result.insert(.allowsReading) }

        if file.isFolder {
            result.insert(.allowsContentEnumerating)
            if permissions.acceptsChildren { result.insert(.allowsWriting) }
        } else if permissions.isWritable && !file.isGoogleNative {
            // Google documents cannot be replaced by uploading bytes; advertising them as writable
            // would let Finder offer an edit that the extension then has to fail.
            result.insert(.allowsWriting)
        }

        if permissions.isRenameable { result.insert(.allowsRenaming) }
        if permissions.isMoveable { result.insert(.allowsReparenting) }
        // Drive has a real trash, and CloudDisk's delete moves objects into it, so both the
        // "move to Trash" gesture and a permanent delete from the Trash folder are backed by the
        // server rather than by a local copy.
        if permissions.isDeletable {
            result.insert(.allowsTrashing)
            result.insert(.allowsDeleting)
        }
        return result
    }

    // MARK: NSFileProviderItem

    public var itemIdentifier: NSFileProviderItemIdentifier { backing.identifier }
    public var parentItemIdentifier: NSFileProviderItemIdentifier { backing.parentIdentifier }
    public var filename: String { backing.filename }
    public var contentType: UTType { backing.contentType }
    public var capabilities: NSFileProviderItemCapabilities { backing.capabilities }
    public var documentSize: NSNumber? { backing.documentSize }
    public var childItemCount: NSNumber? { backing.childItemCount }
    public var creationDate: Date? { backing.creationDate }
    public var contentModificationDate: Date? { backing.modificationDate }
    public var itemVersion: NSFileProviderItemVersion { backing.itemVersion }
    public var isShared: Bool { backing.isShared }
    public var isSharedByCurrentUser: Bool { backing.isSharedByCurrentUser }
    public var ownerName: String? { backing.ownerName }
    public var contentPolicy: NSFileProviderContentPolicy { backing.contentPolicy }

    public var extendedAttributes: [String: Data] { [:] }

    /// The content always comes from Drive, so an item handed to the system is by definition uploaded.
    public var isUploaded: Bool { true }
    public var isUploading: Bool { false }

    // CloudDisk does not guess materialization: FPFS owns that state, and claiming a file is
    // downloaded when it is dataless would stop the system from fetching it. `uploadingError` and
    // `downloadingError` are optional requirements whose absence already means "no error", so they
    // are left unimplemented rather than declared in a form the protocol cannot see.
    public var isDownloaded: Bool { false }
    public var isDownloading: Bool { false }
    public var isMostRecentVersionDownloaded: Bool { false }

    public var fileSystemFlags: NSFileProviderFileSystemFlags {
        backing.isFolder ? [] : [.userReadable, .userWritable]
    }

    /// Items are equal when they describe the same Drive object at the same version, which is what
    /// the system uses to decide whether an enumeration actually changed anything.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DriveFileProviderItem else { return false }
        return other.itemIdentifier == itemIdentifier
            && other.itemVersion.contentVersion == itemVersion.contentVersion
            && other.itemVersion.metadataVersion == itemVersion.metadataVersion
    }

    public override var hash: Int { itemIdentifier.rawValue.hashValue }

    public override var description: String {
        "DriveFileProviderItem(\(itemIdentifier.rawValue), \(filename))"
    }
}
