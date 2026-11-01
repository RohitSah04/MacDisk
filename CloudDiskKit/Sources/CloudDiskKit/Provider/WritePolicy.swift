import Foundation
@preconcurrency import FileProvider

/// The write checks CloudDisk makes against Google's own permission flags before it spends a request.
///
/// Two facts decide every case. A capability Google has explicitly set to false is a refusal the user
/// can be told about now, in the words Finder uses for a denied save. A capability CloudDisk has never
/// seen is not a refusal but an unknown, and the write still goes to Drive, which is the only authority
/// on a permission that changed after the item was listed. Treating absent fields as "forbidden" would
/// block edits of folders the user can plainly change — Drive omits `capabilities` for some shared
/// items entirely — so every rule here resolves an unknown in the user's favour.
///
/// The checks cost nothing where the core already holds fresh metadata (`modify`, which reads the object
/// before writing it) or where the parent was listed moments ago (the metadata cache). Everywhere else
/// the advertisement in `DriveFileProviderItem.capabilities` plus Drive's 403 is the enforcement, and a
/// second request per write would be the price of checking twice.
enum WritePolicy {

    /// A write the item's own Drive permissions do not allow.
    enum Refusal: Equatable, LocalizedError {
        case itemInTrash(name: String)
        case itemReadOnly(name: String)
        case itemLockedInFolder(name: String)
        case containerInTrash(name: String)
        case containerReadOnly(name: String)

        public var errorDescription: String? {
            switch self {
            case .itemInTrash(let name):
                return "“\(name)” is in the Google Drive trash, so it cannot be changed."
            case .itemReadOnly(let name):
                return "Google Drive only lets you read “\(name)”, not edit it."
            case .itemLockedInFolder(let name):
                return "Google Drive does not let “\(name)” move, so it has to stay where it is."
            case .containerInTrash(let name):
                return "“\(name)” is in the Google Drive trash, so nothing can be filed into it."
            case .containerReadOnly(let name):
                return "Google Drive only lets you open “\(name)”, not add files to it."
            }
        }
    }

    /// Whether the field set asks for anything Google's `canEdit` governs.
    ///
    /// Star, trash state and sharing are not in this set because the extension never writes them, and
    /// dates, flags and extended attributes are answered from the object the system already holds.
    static func requestsWritableContent(_ fields: NSFileProviderItemFields) -> Bool {
        fields.contains(.contents) || fields.contains(.filename)
            || fields.contains(.parentItemIdentifier)
    }

    /// The reason a write of `file` cannot happen, or nil when nothing proves it cannot.
    static func refusal(for fields: NSFileProviderItemFields, on file: DriveFile) -> Refusal? {
        guard requestsWritableContent(fields) else { return nil }
        // The trash flag is a fact rather than a permission, so it refuses on its own: Drive's
        // `canEdit` for a trashed object is not something CloudDisk can rely on either way.
        if file.isTrashed { return .itemInTrash(name: file.name) }

        let permissions = file.capabilities
        // Drive documents `canEdit` as covering both content and metadata, so one false rules out
        // every write in this set — which is why it is checked before the move-specific flag.
        if permissions?.canEdit == false { return .itemReadOnly(name: file.name) }
        if fields.contains(.parentItemIdentifier),
           permissions?.canMoveItemWithinDrive == false,
           permissions?.canMoveItemOutOfDrive == false {
            return .itemLockedInFolder(name: file.name)
        }
        return nil
    }

    /// The reason a folder cannot receive new objects, or nil when nothing proves it cannot.
    ///
    /// A parent's `canAddChildren` is the one permission the system cannot check for the provider: it
    /// validates the item being moved (`.allowsReparenting`), not the folder it is dropped into, so a
    /// stale listing of the destination is a hole only CloudDisk can close.
    static func containerRefusal(of parent: DriveFile) -> Refusal? {
        if parent.isTrashed { return .containerInTrash(name: parent.name) }
        return parent.capabilities?.canAddChildren == false
            ? .containerReadOnly(name: parent.name)
            : nil
    }
}
