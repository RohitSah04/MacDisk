import Foundation
import FileProvider
import CryptoKit

/// Translates between Google Drive object ids and `NSFileProviderItemIdentifier` values.
///
/// Drive ids are already stable and opaque, but two things have to be handled:
///
/// - the three virtual containers (root, Trash, working set), which the system addresses with its
///   own reserved identifiers instead of a provider id;
/// - the fact that a Drive item can have several parents while File Provider can only replicate one
///   path per item. `enforceSingleParent` is set on every write so Drive never hands us a second
///   parent for something we created, and for pre-existing multi-parent items the first parent wins.
public enum ProviderIdentity {

    /// Prefix that keeps a Drive id from colliding with a reserved container identifier.
    static let drivePrefix = "g:"

    /// Drive's synthetic id for "My Drive".
    public static let driveRootID = "root"

    public static let rootIdentifier = NSFileProviderItemIdentifier.rootContainer
    public static let trashIdentifier = NSFileProviderItemIdentifier.trashContainer
    public static let workingSetIdentifier = NSFileProviderItemIdentifier.workingSet

    public static func identifier(forDriveID id: String) -> NSFileProviderItemIdentifier {
        id == driveRootID ? rootIdentifier : NSFileProviderItemIdentifier(drivePrefix + id)
    }

    /// The Drive id behind an identifier, or nil when it addresses a virtual container.
    ///
    /// `.trashContainer` and `.workingSet` have no Drive object, so they deliberately return nil;
    /// callers must not substitute "root" for them.
    public static func driveID(for identifier: NSFileProviderItemIdentifier) -> String? {
        switch identifier {
        case rootIdentifier:
            return driveRootID
        case trashIdentifier, workingSetIdentifier:
            return nil
        default:
            guard identifier.rawValue.hasPrefix(drivePrefix) else { return nil }
            let candidate = String(identifier.rawValue.dropFirst(drivePrefix.count))
            return DriveQuery.isValidIdentifier(candidate) ? candidate : nil
        }
    }

    public static func isContainerIdentifier(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        identifier == rootIdentifier || identifier == trashIdentifier
            || identifier == workingSetIdentifier
    }

    /// The single parent File Provider will replicate this item under.
    ///
    /// `rootFolderID` is the account's real "My Drive" folder id. Drive puts it in `parents` for every
    /// top-level object while the provider addresses that folder with the reserved root container
    /// identifier, so the two have to be reconciled here: an item parented to an id the system was
    /// never given is not filed under anything, and Finder shows an empty folder.
    static func parentIdentifier(for file: DriveFile,
                                 rootFolderID: String? = nil) -> NSFileProviderItemIdentifier {
        if file.isTrashed {
            // Drive keeps reporting the folder a trashed object came from. A children query excludes
            // trashed items, so that parent would hold a row the system can never list — and the
            // user could not empty it. Trash is the only place a trashed item can live.
            return trashIdentifier
        }
        guard let parent = file.parentID else {
            // Drive omits `parents` for items reachable only through a shared-drive shortcut or
            // when the caller lacks the permission to see the parent. Root is the only safe answer:
            // it keeps the item visible instead of dropping it out of the replica entirely.
            return rootIdentifier
        }
        if parent == driveRootID || parent == rootFolderID { return rootIdentifier }
        return identifier(forDriveID: parent)
    }

    // MARK: Versions

    /// The system caps each version component at 128 bytes. Drive's revision ids and checksums fit
    /// comfortably, but a token is only useful if it is *different* for different content, so an
    /// unexpectedly long one is hashed rather than truncated — truncating could make two revisions
    /// look identical and leave the system serving stale bytes.
    static let maximumVersionComponentByteCount = 128

    /// Metadata for an item changes with its name, parent, star, trash state and keep-offline mark, and
    /// a Drive name can reach 1024 characters, so the metadata component is hashed even when it would fit.
    ///
    /// The pin belongs in the version because File Provider reads an item's `contentPolicy` once and
    /// keeps the answer — a released pin whose version is unchanged leaves the replica marked
    /// "prevent eviction" forever, and `evictItem` then answers `.nonEvictable` for a file the user has
    /// explicitly asked to let go. Restating the mark as a metadata change is what makes the system ask
    /// for the item again and take the new policy. Content bytes are untouched: `contentVersion` does
    /// not vary with the pin, so a pin toggle never costs a re-download.
    static func itemVersion(for file: DriveFile, pinned: Bool = false) -> NSFileProviderItemVersion {
        let metadataToken = file.metadataVersionToken + "|keep:\(pinned ? 1 : 0)"
        return NSFileProviderItemVersion(
            contentVersion: bounded(file.id, Data(file.contentVersionToken.utf8)),
            metadataVersion: bounded(file.id, Data(SHA256.hash(data: Data(metadataToken.utf8))))
        )
    }

    /// Decides whether the version bytes the system handed back still describe the server copy.
    ///
    /// The comparison re-derives the version from `file` instead of decoding `version`: the encoded
    /// form is namespaced with the item id and, for long tokens, hashed, so the Drive token cannot be
    /// read back out of it. Decoding the raw bytes as UTF-8 — the obvious shortcut — fails outright,
    /// because the id namespace prefix is hash bytes that are usually not valid UTF-8.
    static func contentVersion(_ version: Data, matches file: DriveFile) -> Bool {
        version == itemVersion(for: file).contentVersion
    }

    /// Namespaces the component with the item id, so two items can never present the same version
    /// bytes, and keeps the result inside the system's limit.
    private static func bounded(_ id: String, _ bytes: Data) -> Data {
        let tag = Data(SHA256.hash(data: Data(id.utf8)).prefix(8))
        let payload = bytes.count <= maximumVersionComponentByteCount - tag.count
            ? bytes
            : Data(SHA256.hash(data: bytes))
        return tag + payload
    }
}

/// File names that can actually exist on the replicated volume.
enum ProviderFilename {

    /// Turns a Drive name into a legal, non-empty APFS file name.
    ///
    /// Drive forbids `/` and control characters but allows names up to 1024 characters; APFS caps a
    /// component at 255 UTF-8 bytes. Over-long names are truncated with the extension preserved,
    /// because handing the system an unrepresentable name produces a replica entry that can never be
    /// written to disk.
    static func materializable(_ raw: String) -> String {
        var cleaned = raw.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value == 0 || scalar == "/" || scalar == "\n" || scalar == "\r" {
                result.append(Character("-"))
            } else if scalar.value < 0x20 {
                result.append(Character(" "))
            } else {
                result.append(Character(scalar))
            }
        }
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleaned = "Untitled"
        }
        return truncate(to255UTF8Bytes: cleaned)
    }

    private static func truncate(to255UTF8Bytes name: String) -> String {
        if name.utf8.count <= 255 { return name }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let reserved = ext.isEmpty ? 0 : (utf8Count(ext) + 1)
        let allowance = max(1, 255 - reserved)

        var kept = ""
        var bytes = 0
        for character in base {
            let length = utf8Count(String(character))
            if bytes + length > allowance { break }
            kept.append(character)
            bytes += length
        }
        return ext.isEmpty ? kept : "\(kept).\(ext)"
    }

    private static func utf8Count(_ string: String) -> Int { string.utf8.count }
}
