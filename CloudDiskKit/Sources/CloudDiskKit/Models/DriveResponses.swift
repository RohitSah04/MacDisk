import Foundation

/// One entry of the Drive `changes` feed.
public struct DriveChange: Decodable, Equatable, Sendable {
    public let kind: String?
    public let fileId: String
    /// Present unless `removed` is true.
    public let file: DriveFile?
    public let removed: Bool?

    public var isRemoved: Bool { removed ?? false }
}

public struct DriveChangesPage: Decodable, Equatable, Sendable {
    public let kind: String?
    public let changes: [DriveChange]?
    public let nextPageToken: String?
    public let newStartPageToken: String?

    public var changeList: [DriveChange] { changes ?? [] }
}

/// `about.get` — storage numbers and the signed-in user.
public struct DriveAbout: Decodable, Equatable, Sendable {
    public struct StorageQuota: Decodable, Equatable, Sendable {
        public let limit: String?
        public let usage: String?
        public let usageInDrive: String?

        public var limitBytes: Int64? { limit.flatMap(Int64.init) }
        public var usageBytes: Int64? { usage.flatMap(Int64.init) }
        public var usageInDriveBytes: Int64? { usageInDrive.flatMap(Int64.init) }
    }

    public struct User: Decodable, Equatable, Sendable {
        public let kind: String?
        public let displayName: String?
        public let emailAddress: String?
        public let photoLink: String?
        public let me: Bool?
    }

    public let kind: String?
    public let storageQuota: StorageQuota?
    public let user: User?

    public static let fields =
        "kind,storageQuota(limit,usage,usageInDrive),user(kind,displayName,emailAddress,photoLink,me)"
}

/// A page of children returned by `files.list`.
public struct DriveChildrenPage: Decodable, Equatable, Sendable {
    public let kind: String?
    public let files: [DriveFile]?
    public let nextPageToken: String?

    public var fileList: [DriveFile] { files ?? [] }
}
