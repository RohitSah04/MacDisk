import Foundation

/// A Google Drive `files` resource, limited to the fields CloudDisk actually consumes.
///
/// Drive returns camelCase JSON, so the synthesized `Decodable` conformance maps directly.
/// `size` is a string in the v3 API (uint64 can exceed JSON number precision).
/// `Identifiable` because both File Provider and every list in the app key a row by Drive's object id,
/// which is stable across a rename — `id` is already that value.
public struct DriveFile: Decodable, Equatable, Sendable, Identifiable {

    public let kind: String?
    public let id: String
    public let name: String
    public let mimeType: String
    public let fileDescription: String?
    public let fileExtension: String?
    public let size: String?
    public let version: String?
    public let md5Checksum: String?
    public let parents: [String]?
    public let trashed: Bool?
    public let starred: Bool?
    public let shared: Bool?
    public let ownedByMe: Bool?
    public let createdTime: String?
    public let modifiedTime: String?
    public let lastModifyingUser: DriveUser?
    public let owners: [DriveUser]?
    public let exportLinks: [String: String]?
    public let thumbnailLink: String?
    public let iconLink: String?
    public let shortcutDetails: DriveShortcutDetails?
    public let capabilities: DriveCapabilities?

    public init(id: String, name: String, mimeType: String, size: String? = nil,
                version: String? = nil, md5Checksum: String? = nil, parents: [String]? = nil,
                modifiedTime: String? = nil, createdTime: String? = nil,
                trashed: Bool? = nil, starred: Bool? = nil, shared: Bool? = nil,
                ownedByMe: Bool? = nil, exportLinks: [String: String]? = nil,
                thumbnailLink: String? = nil, fileExtension: String? = nil,
                fileDescription: String? = nil, lastModifyingUser: DriveUser? = nil,
                owners: [DriveUser]? = nil, iconLink: String? = nil,
                kind: String? = nil, shortcutDetails: DriveShortcutDetails? = nil,
                capabilities: DriveCapabilities? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.fileDescription = fileDescription
        self.fileExtension = fileExtension
        self.size = size
        self.version = version
        self.md5Checksum = md5Checksum
        self.parents = parents
        self.trashed = trashed
        self.starred = starred
        self.shared = shared
        self.ownedByMe = ownedByMe
        self.createdTime = createdTime
        self.modifiedTime = modifiedTime
        self.lastModifyingUser = lastModifyingUser
        self.owners = owners
        self.exportLinks = exportLinks
        self.thumbnailLink = thumbnailLink
        self.iconLink = iconLink
        self.shortcutDetails = shortcutDetails
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, name, mimeType, fileExtension, size, version, md5Checksum, parents
        case trashed, starred, shared, ownedByMe, createdTime, modifiedTime
        case lastModifyingUser, owners, exportLinks, thumbnailLink, iconLink
        case shortcutDetails, capabilities
        case fileDescription = "description"
    }

    // MARK: Shape

    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    public var isFolder: Bool { mimeType == Self.folderMimeType }
    public var isShortcut: Bool { mimeType == Self.shortcutMimeType }
    public var isGoogleNative: Bool { mimeType.hasPrefix("application/vnd.google-apps.") }
    public var isTrashed: Bool { trashed ?? false }

    /// Drive has no bytes for Workspace documents; they must be exported.
    public var hasMediaContent: Bool { !isFolder && !isGoogleNative }

    public var byteCount: Int64? { size.flatMap { Int64($0) } }

    /// The folder this item lives in, from CloudDisk's point of view.
    ///
    /// Drive allows several parents; File Provider can only represent one path per item, so the
    /// first parent wins. `shortcutDetails.targetId` is resolved by the service, not here.
    public var parentID: String? { parents?.first }

    public var parsedCreatedTime: Date? { createdTime.flatMap { DriveDate.parse($0) } }
    public var parsedModifiedTime: Date? { modifiedTime.flatMap { DriveDate.parse($0) } }

    /// Content version token used for `NSFileProviderItemVersion.contentVersion`.
    ///
    /// Prefers the opaque revision, then the checksum, then the modification timestamp so that a
    /// changed file always changes this value.
    public var contentVersionToken: String {
        if let version, !version.isEmpty { return "v:\(version)" }
        if let md5Checksum, !md5Checksum.isEmpty { return "m:\(md5Checksum)" }
        return "t:\(modifiedTime ?? "0")"
    }

    public var metadataVersionToken: String {
        "\(name)|\(parents?.joined(separator: ",") ?? "")|\(starred ?? false ? 1 : 0)|\(trashed ?? false ? 1 : 0)|\(fileDescription ?? "")"
    }

    public static let rootFolderID = "root"

    /// Fields requested from the API. Kept in one place so the response decoder and the query
    /// string can never disagree.
    public static let fields = [
        "kind", "id", "name", "mimeType", "description", "fileExtension", "size", "version",
        "md5Checksum", "parents", "trashed", "starred", "shared", "ownedByMe", "createdTime",
        "modifiedTime", "lastModifyingUser(displayName,emailAddress,photoLink,picture)",
        "owners(displayName,emailAddress,picture)", "exportLinks", "thumbnailLink", "iconLink",
        "shortcutDetails(targetId,targetMimeType,targetType)",
        "capabilities(canEdit,canDownload,canTrash,canCopy,canAddChildren,canMoveItemOutOfWorld,"
            + "canRemoveChildren,canUpdate,canShare,canDeleteChildren)"
    ].joined(separator: ",")

    public static let listFields = "kind,files(\(fields)),nextPageToken,newPageToken"
    public static let changesFields =
        "kind,newStartPageToken,nextPageToken,removes,changes(kind,fileId,file(\(fields)),removed,mutationId)"
}

public struct DriveUser: Decodable, Equatable, Sendable {
    public let displayName: String?
    public let emailAddress: String?
    public let picture: String?
    public let photoLink: String?
}

public struct DriveShortcutDetails: Decodable, Equatable, Sendable {
    public let targetId: String?
    public let targetMimeType: String?
    public let targetType: String?
}

public struct DriveCapabilities: Decodable, Equatable, Sendable {
    public let canEdit: Bool?
    public let canDownload: Bool?
    public let canTrash: Bool?
    public let canCopy: Bool?
    public let canAddChildren: Bool?
    public let canRemoveChildren: Bool?
    public let canMoveItemOutOfWorld: Bool?
    public let canUpdate: Bool?
    public let canShare: Bool?
    public let canDeleteChildren: Bool?

    public init(canEdit: Bool? = nil, canDownload: Bool? = nil, canTrash: Bool? = nil,
                canCopy: Bool? = nil, canAddChildren: Bool? = nil, canShare: Bool? = nil,
                canMoveItemOutOfWorld: Bool? = nil) {
        self.canEdit = canEdit
        self.canDownload = canDownload
        self.canTrash = canTrash
        self.canCopy = canCopy
        self.canAddChildren = canAddChildren
        self.canShare = canShare
        self.canRemoveChildren = nil
        self.canMoveItemOutOfWorld = canMoveItemOutOfWorld
        self.canUpdate = nil
        self.canDeleteChildren = nil
    }

    /// Drive's own wording: `canEdit` covers content and metadata changes on the item.
    public var isWritable: Bool { canEdit ?? false }
    public var isReadable: Bool { canDownload ?? true }
    public var isDeletable: Bool { canTrash ?? canEdit ?? false }
    public var isRenameable: Bool { canEdit ?? false }
    public var isMoveable: Bool { (canEdit ?? false) && (canMoveItemOutOfWorld ?? true) }
    public var acceptsChildren: Bool { canAddChildren ?? false }
}

/// Google Workspace types and the export formats Drive can produce for them.
public enum GoogleWorkspaceExport {
    public static let preferred: [String: (mimeType: String, extensionName: String)] = [
        DriveFile.folderMimeType: ("application/vnd.google-apps.folder", ""),
        "application/vnd.google-apps.document": ("application/pdf", "pdf"),
        "application/vnd.google-apps.spreadsheet": (
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"),
        "application/vnd.google-apps.presentation": (
            "application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"),
        "application/vnd.google-apps.drawing": ("image/png", "png"),
        "application/vnd.google-apps.file": ("application/octet-stream", "bin")
    ]

    public static func exportMimeType(for file: DriveFile) -> String? {
        if let exportLinks = file.exportLinks, exportLinks.isEmpty == false {
            if let match = preferred[file.mimeType],
               exportLinks[match.mimeType] != nil {
                return match.mimeType
            }
            return exportLinks.keys.sorted().first
        }
        return preferred[file.mimeType]?.mimeType
    }

    public static func fileExtension(for file: DriveFile) -> String? {
        preferred[file.mimeType]?.extensionName.isEmpty == false
            ? preferred[file.mimeType]?.extensionName
            : nil
    }
}

/// Parses the timestamps Google returns, which may or may not carry fractional seconds.
///
/// `ISO8601DateFormatter` without `.withFractionalSeconds` rejects
/// `2026-10-29T23:12:04.500Z` outright, which is why the previous implementation silently
/// produced `nil` modification dates.
public enum DriveDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        if let date = fractional.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        return nil
    }
}
