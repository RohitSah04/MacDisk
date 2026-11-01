import Foundation
import XCTest
import FileProvider
import UniformTypeIdentifiers
@testable import CloudDiskKit

/// Identifier, name and version mapping.
///
/// These three tables decide where an object appears in Finder and whether the system believes its
/// on-disk copy is current. Getting them wrong is not a visible crash — it is a stale file, a
/// duplicated row after a restart, or an item the user cannot delete — so each rule is pinned here
/// with the exact bytes the system would receive.
final class ProviderIdentityTests: XCTestCase {

    func testARootDriveIDMapsToTheSystemRootContainer() {
        XCTAssertEqual(ProviderIdentity.identifier(forDriveID: "root"),
                       ProviderIdentity.rootIdentifier)
        XCTAssertEqual(ProviderIdentity.driveID(for: ProviderIdentity.rootIdentifier), "root")
    }

    func testADriveIDIsPrefixedSoItCannotCollideWithAReservedContainer() {
        let id = "1AbCdEfGhIjKlMnOpQrStUvWxYz12345"
        let identifier = ProviderIdentity.identifier(forDriveID: id)
        XCTAssertNotEqual(identifier, ProviderIdentity.rootIdentifier)
        XCTAssertNotEqual(identifier, ProviderIdentity.trashIdentifier)
        XCTAssertNotEqual(identifier, ProviderIdentity.workingSetIdentifier)
        XCTAssertEqual(ProviderIdentity.driveID(for: identifier), id)
    }

    func testTheVirtualContainersResolveToNoDriveObject() {
        // A caller that substituted "root" for these would serve the whole Drive where a folder was
        // asked for, so the distinction has to survive the round trip.
        XCTAssertNil(ProviderIdentity.driveID(for: ProviderIdentity.trashIdentifier))
        XCTAssertNil(ProviderIdentity.driveID(for: ProviderIdentity.workingSetIdentifier))
    }

    func testAForeignOrMalformedIdentifierIsRejectedRatherThanForwarded() {
        // Anything the extension did not mint must not become a Drive request.
        XCTAssertNil(ProviderIdentity.driveID(for: NSFileProviderItemIdentifier("plain-id")))
        XCTAssertNil(ProviderIdentity.driveID(for: NSFileProviderItemIdentifier("g:has space")))
        XCTAssertNil(ProviderIdentity.driveID(for: NSFileProviderItemIdentifier("g:a'b")))
        XCTAssertNil(ProviderIdentity.driveID(for: NSFileProviderItemIdentifier("g:../../other")))
        XCTAssertNil(ProviderIdentity.driveID(for: NSFileProviderItemIdentifier("other:1234")))
    }

    func testANamelessItemFallsBackToTheRootSoItStaysVisible() {
        let orphan = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "orphan.txt", mimeType: "text/plain")
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: orphan),
                       ProviderIdentity.rootIdentifier)
    }

    func testAMultiParentItemIsReplicatedUnderItsFirstParentOnly() {
        // File Provider cannot represent two paths for one item; Drive's `enforceSingleParent` keeps
        // CloudDisk's own writes single-parented, and pre-existing items take the first.
        let shared = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "both.txt", mimeType: "text/plain",
                               parents: ["firstparent0000000000000000000001",
                                         "secondparent000000000000000000002"])
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: shared),
                       ProviderIdentity.identifier(forDriveID: "firstparent0000000000000000000001"))
    }

    func testAChildOfTheRealMyDriveFolderIsFiledUnderTheRootContainer() {
        // Drive never puts the "root" alias in `parents`: a root listing names the account's My Drive
        // folder by its real id. An item parented to an identifier the system was never given belongs
        // to no container, and Finder shows an empty folder while the API returns every file.
        let topLevel = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "top.txt",
                                 mimeType: "text/plain", parents: ["0AIzEQ6JILNiUk9PVAxxxxxxxxxxxxx"])
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: topLevel),
                       ProviderIdentity.identifier(forDriveID: "0AIzEQ6JILNiUk9PVAxxxxxxxxxxxxx"),
                       "without the alias the item is filed under a container nobody asked for")
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: topLevel,
                                                         rootFolderID: "0AIzEQ6JILNiUk9PVAxxxxxxxxxxxxx"),
                       ProviderIdentity.rootIdentifier)
    }

    func testTheAliasOnlyAppliesToMyDriveNotToEveryFolderAtTheTop() {
        let nested = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "inside.txt",
                               mimeType: "text/plain",
                               parents: ["firstparent0000000000000000000001"])
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: nested,
                                                         rootFolderID: "0AIzEQ6JILNiUk9PVAxxxxxxxxxxxxx"),
                       ProviderIdentity.identifier(forDriveID: "firstparent0000000000000000000001"),
                       "a folder's own children must stay inside that folder")
    }

    func testATrashedItemBelongsToTheTrashContainerNotTheFolderItCameFrom() {
        // Drive keeps reporting the original parent after trashing. Listing it there would put a row
        // inside a folder whose children query filters trashed items out of existence.
        let trashed = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "gone.txt", mimeType: "text/plain",
                                parents: ["firstparent0000000000000000000001"], trashed: true)
        XCTAssertEqual(ProviderIdentity.parentIdentifier(for: trashed),
                       ProviderIdentity.trashIdentifier)
    }

    func testVersionComponentsAlwaysFitInsideTheSystemByteLimit() {
        // 128 bytes per component is a hard system cap; an over-long token interrupts synchronization.
        let absurd = DriveFile(id: "1234567890abcdefghijklmnopqrstuv",
                               name: String(repeating: "n", count: 1_024),
                               mimeType: "text/plain",
                               size: "10", version: String(repeating: "v", count: 4_000),
                               md5Checksum: nil,
                               parents: [String(repeating: "p", count: 300)])
        let version = ProviderIdentity.itemVersion(for: absurd)
        XCTAssertLessThanOrEqual(version.contentVersion.count,
                                 ProviderIdentity.maximumVersionComponentByteCount)
        XCTAssertLessThanOrEqual(version.metadataVersion.count,
                                 ProviderIdentity.maximumVersionComponentByteCount)
    }

    func testARealRevisionIsCarriedVerbatimSoADecodeStaysReadable() {
        let token = "v:0123456789abcdef0123456789abcdef"
        let file = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain",
                             version: "0123456789abcdef0123456789abcdef")
        let version = ProviderIdentity.itemVersion(for: file)
        // 8 bytes of item tag plus the token itself: anything longer would have been hashed.
        XCTAssertEqual(version.contentVersion.count, 8 + token.utf8.count)
        XCTAssertEqual(version.contentVersion.suffix(token.utf8.count), Data(token.utf8))
    }

    func testTwoItemsWithTheSameRevisionDoNotClaimTheSameVersionBytes() {
        let shared = "0123456789abcdef"
        let left = DriveFile(id: "111111111111111111111111111111111", name: "left.txt", mimeType: "text/plain", version: shared)
        let right = DriveFile(id: "222222222222222222222222222222222", name: "right.txt", mimeType: "text/plain", version: shared)
        XCTAssertNotEqual(ProviderIdentity.itemVersion(for: left).contentVersion,
                          ProviderIdentity.itemVersion(for: right).contentVersion)
    }

    func testAContentRevisionChangeMovesTheVersionButAStarChangeDoesNot() {
        // The content component decides whether the system re-downloads; starring is metadata.
        let base = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain", version: "rev-1")
        let edited = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain", version: "rev-2")
        let starred = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain", version: "rev-1",
                                starred: true)
        XCTAssertNotEqual(ProviderIdentity.itemVersion(for: base).contentVersion,
                          ProviderIdentity.itemVersion(for: edited).contentVersion)
        XCTAssertEqual(ProviderIdentity.itemVersion(for: base).contentVersion,
                       ProviderIdentity.itemVersion(for: starred).contentVersion)
        XCTAssertNotEqual(ProviderIdentity.itemVersion(for: base).metadataVersion,
                          ProviderIdentity.itemVersion(for: starred).metadataVersion)
    }

    /// The bug this closes: a released pin whose version is unchanged is never re-read by File Provider,
    /// so the replica keeps the "prevent eviction" mark and `evictItem` answers `.nonEvictable` for a
    /// file the user has just asked to let go.
    func testKeepingAndReleasingAnItemMovesOnlyItsMetadataVersion() {
        let file = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt",
                             mimeType: "text/plain", version: "rev-1")
        let kept = ProviderIdentity.itemVersion(for: file, pinned: true)
        let lazy = ProviderIdentity.itemVersion(for: file, pinned: false)

        XCTAssertNotEqual(kept.metadataVersion, lazy.metadataVersion)
        // No content re-download may cost the user their copy: bytes are the same object either way.
        XCTAssertEqual(kept.contentVersion, lazy.contentVersion)
        // And the mark is not a per-toggle nonce — the same state always publishes the same version.
        XCTAssertEqual(ProviderIdentity.itemVersion(for: file, pinned: true).metadataVersion,
                       kept.metadataVersion)
    }

    func testAnUnpinnedItemPublishesTheSameVersionAsTheOneArgumentForm() {
        let file = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt",
                             mimeType: "text/plain", version: "rev-1")
        XCTAssertEqual(ProviderIdentity.itemVersion(for: file).metadataVersion,
                       ProviderIdentity.itemVersion(for: file, pinned: false).metadataVersion)
    }

    func testVersionTokensFallBackInTheDocumentedOrder() {
        let withChecksum = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain",
                                     version: nil, md5Checksum: "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(withChecksum.contentVersionToken, "m:d41d8cd98f00b204e9800998ecf8427e")

        let withTime = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain",
                                 modifiedTime: "2026-10-29T10:00:00Z")
        XCTAssertEqual(withTime.contentVersionToken, "t:2026-10-29T10:00:00Z")

        // An empty revision from Drive is not a version: the checksum still has to win.
        let blank = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "a.txt", mimeType: "text/plain",
                              version: "", md5Checksum: "abc")
        XCTAssertEqual(blank.contentVersionToken, "m:abc")
    }
}

/// File names that can physically exist on the replicated volume.
final class ProviderFilenameTests: XCTestCase {

    func testCharactersAPFSRejectsAreReplacedNotDropped() {
        XCTAssertEqual(ProviderFilename.materializable("a/b"), "a-b")
        XCTAssertEqual(ProviderFilename.materializable("line\nbreak"), "line-break")
        XCTAssertEqual(ProviderFilename.materializable("carriage\rreturn"), "carriage-return")
        XCTAssertEqual(ProviderFilename.materializable("NUL\u{00}inside"), "NUL-inside")
        // Other control characters become spaces, which APFS accepts and Finder displays.
        XCTAssertEqual(ProviderFilename.materializable("bell\u{0007}here"), "bell here")
    }

    func testAnEmptyOrBlankNameBecomesARealFileName() {
        // Handing the system "" makes the item unrepresentable; it does not skip it, it fails.
        XCTAssertEqual(ProviderFilename.materializable(""), "Untitled")
        XCTAssertEqual(ProviderFilename.materializable("   "), "Untitled")
    }

    func testATooLongNameIsCutToTheAPFSComponentLimitWithItsExtensionIntact() {
        let long = String(repeating: "a", count: 400)
        let cut = ProviderFilename.materializable("\(long).txt")
        XCTAssertLessThanOrEqual(cut.utf8.count, 255)
        XCTAssertTrue(cut.hasSuffix(".txt"), "extension must survive: \(cut.suffix(10))")
        XCTAssertFalse(cut.isEmpty)

        let extensionless = ProviderFilename.materializable(long)
        XCTAssertLessThanOrEqual(extensionless.utf8.count, 255)
        XCTAssertEqual(extensionless.count, 255)
    }

    func testTruncationNeverSplitsAMultiByteCharacter() {
        // Cutting at a byte boundary would produce a name that is not valid UTF-8 and cannot be
        // written to disk at all.
        let name = String(repeating: "\u{00E9}", count: 200) // 2 UTF-8 bytes each
        let cut = ProviderFilename.materializable(name)
        XCTAssertEqual(cut.count, 127, "the last whole character must survive")
        XCTAssertLessThanOrEqual(cut.utf8.count, 255)
        XCTAssertTrue(cut.unicodeScalars.allSatisfy { $0 == "\u{00E9}" })
    }

    func testANameThatFitsIsPassedThroughUnchanged() {
        XCTAssertEqual(ProviderFilename.materializable("Quarterly Report (final).pdf"),
                       "Quarterly Report (final).pdf")
    }
}

/// How a Drive object is advertised to Finder.
final class DriveFileProviderItemTests: XCTestCase {

    private func file() -> DriveFile {
        DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "notes.txt",
                  mimeType: "text/plain", size: "2048", version: "rev-1",
                  parents: ["fold00000000000000000000000000001"],
                  modifiedTime: "2026-10-29T10:00:00Z",
                  createdTime: "2026-01-02T03:04:05.500Z",
                  capabilities: DriveCapabilities(canEdit: true, canDownload: true,
                                                  canTrash: true, canCopy: true,
                                                  canAddChildren: false))
    }

    func testABinaryFileIsAdvertisedWithItsSizeTypeAndDates() {
        let item = DriveFileProviderItem.make(from: file())
        XCTAssertEqual(item.filename, "notes.txt")
        XCTAssertEqual(item.documentSize, NSNumber(value: 2048))
        XCTAssertEqual(item.contentType, UTType(filenameExtension: "txt"))
        XCTAssertEqual(item.contentModificationDate, DriveDate.parse("2026-10-29T10:00:00Z"))
        XCTAssertEqual(item.creationDate, DriveDate.parse("2026-01-02T03:04:05.500Z"))
        XCTAssertEqual(item.parentItemIdentifier,
                       ProviderIdentity.identifier(forDriveID: "fold00000000000000000000000000001"))
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
        XCTAssertTrue(item.capabilities.contains(.allowsRenaming))
        XCTAssertTrue(item.capabilities.contains(.allowsTrashing))
        XCTAssertFalse(item.isDownloaded, "the provider never claims bytes it has not materialized")
    }

    func testAFolderIsAdvertisedAsAContainerNotAsData() {
        let folder = DriveFile(id: "fold00000000000000000000000000001", name: "Reports",
                               mimeType: DriveFile.folderMimeType,
                               capabilities: DriveCapabilities(canEdit: true, canDownload: true,
                                                               canTrash: true, canAddChildren: true))
        let item = DriveFileProviderItem.make(from: folder)
        XCTAssertEqual(item.contentType, .folder)
        XCTAssertNil(item.documentSize, "a folder with a size would be materialized as a file")
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(item.capabilities.contains(.allowsAddingSubItems))
    }

    func testAFolderThatRejectsChildrenIsNotAdvertisedAsWritable() {
        let readOnly = DriveFile(id: "fold00000000000000000000000000001", name: "Shared",
                                 mimeType: DriveFile.folderMimeType,
                                 capabilities: DriveCapabilities(canEdit: false, canDownload: true,
                                                                 canTrash: false, canAddChildren: false))
        let item = DriveFileProviderItem.make(from: readOnly)
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsAddingSubItems))
        XCTAssertFalse(item.capabilities.contains(.allowsTrashing))
    }

    func testAFolderAdvertisesTheBitsThatMakeItListable() {
        // Without `userReadable` the system files the directory as mode `--x`, `readdir` answers
        // EACCES and Finder shows a folder that never fills, no matter how many children the
        // provider published. `userExecutable` is what makes a path traversable at all.
        let folder = DriveFile(id: "fold00000000000000000000000000001", name: "Family",
                               mimeType: DriveFile.folderMimeType,
                               capabilities: DriveCapabilities(canEdit: true, canDownload: true,
                                                               canTrash: true, canAddChildren: true))
        let item = DriveFileProviderItem.make(from: folder)
        XCTAssertEqual(item.fileSystemFlags, [.userReadable, .userWritable, .userExecutable])
    }

    func testAFolderReadOnlyInDriveIsStillListable() {
        let readOnly = DriveFile(id: "fold00000000000000000000000000001", name: "Shared",
                                 mimeType: DriveFile.folderMimeType,
                                 capabilities: DriveCapabilities(canAddChildren: false))
        let item = DriveFileProviderItem.make(from: readOnly)
        XCTAssertTrue(item.fileSystemFlags.contains(.userReadable),
                      "a shared folder the user cannot write to must still be openable")
        XCTAssertTrue(item.fileSystemFlags.contains(.userExecutable))
    }

    func testAFileAdvertisesNoExecuteBit() {
        // An executable data file would be offered as an application to run.
        XCTAssertEqual(DriveFileProviderItem.make(from: file()).fileSystemFlags,
                       [.userReadable, .userWritable])
    }

    func testADateOlderThanTheSystemCanStoreIsReplacedByTheCreationTime() throws {
        // Drive answers 1601-01-01 — a zero Windows FILETIME — for files imported from other
        // systems. File Provider keeps dates as int64 nanoseconds and clamps anything below 1677, so
        // publishing that date would leave the file stamped 1677 in Finder and the on-disk object
        // disagreeing with the item reported for it, which FPCK then reports forever.
        let imported = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "certificate.pdf",
                                 mimeType: "application/pdf",
                                 modifiedTime: "1601-01-01T00:00:00Z",
                                 createdTime: "2025-02-14T08:47:23.808Z")
        let item = DriveFileProviderItem.make(from: imported)
        XCTAssertEqual(item.contentModificationDate, DriveDate.parse("2025-02-14T08:47:23.808Z"))
        XCTAssertEqual(item.creationDate, DriveDate.parse("2025-02-14T08:47:23.808Z"))
    }

    func testAUsableModifiedTimeIsPublishedExactlyAsDriveReportsIt() {
        let file = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "notes.txt",
                             mimeType: "text/plain",
                             modifiedTime: "2026-10-29T23:12:04.500Z",
                             createdTime: "2026-01-01T00:00:00Z")
        let item = DriveFileProviderItem.make(from: file)
        XCTAssertEqual(item.contentModificationDate, DriveDate.parse("2026-10-29T23:12:04.500Z"))
        XCTAssertEqual(item.creationDate, DriveDate.parse("2026-01-01T00:00:00Z"))
    }

    func testADateTheSystemCannotStoreIsNeverPublishedAsEitherDate() {
        let unusable = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "ancient.pdf",
                                 mimeType: "application/pdf",
                                 modifiedTime: "1601-01-01T00:00:00Z",
                                 createdTime: "1601-01-01T00:00:00Z")
        XCTAssertNil(unusable.fileProviderModificationDate)
        XCTAssertNil(unusable.fileProviderCreationDate)
        XCTAssertNotNil(unusable.parsedModifiedTime, "the timestamp is readable, just not storeable")
    }

    func testTheFileProviderDateFloorIsTheBoundaryItself() {
        XCTAssertEqual(DriveDate.representableForFileProvider(DriveDate.fileProviderDateFloor),
                       DriveDate.fileProviderDateFloor)
        XCTAssertNil(DriveDate.representableForFileProvider(
            DriveDate.fileProviderDateFloor.addingTimeInterval(-1)))
        XCTAssertNil(DriveDate.representableForFileProvider(nil))
    }

    func testAGoogleDocumentIsReadOnlyAndTypedAsItsExportFormat() {
        // Bytes the system receives are the export, so the type has to describe the export or Quick
        // Look and Finder open the file with the wrong handler.
        let doc = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "Roadmap",
                            mimeType: "application/vnd.google-apps.document",
                            exportLinks: ["application/pdf": "https://export/1"])
        let item = DriveFileProviderItem.make(from: doc)
        XCTAssertEqual(item.contentType.identifier, UTType.pdf.identifier)
        XCTAssertNil(item.documentSize, "an unexported document has no byte count to report")
        XCTAssertFalse(item.capabilities.contains(.allowsWriting),
                       "advertising writes the extension cannot perform invites a guaranteed failure")
    }

    func testATrashedItemOffersImmediateDeletionInsteadOfATrashMove() {
        let trashed = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "old.txt", mimeType: "text/plain",
                                trashed: true,
                                capabilities: DriveCapabilities(canEdit: true, canDownload: true,
                                                                canTrash: true))
        let item = DriveFileProviderItem.make(from: trashed)
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(item.capabilities.contains(.allowsTrashing))
        XCTAssertFalse(item.capabilities.contains(.allowsRenaming))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertEqual(item.parentItemIdentifier, ProviderIdentity.trashIdentifier)
    }

    func testATrashedFolderStillLetsTheUserLookInsideIt() {
        let folder = DriveFile(id: "fold00000000000000000000000000001", name: "2024",
                               mimeType: DriveFile.folderMimeType, trashed: true)
        let item = DriveFileProviderItem.make(from: folder)
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
    }

    func testAnItemDriveWillNotLetUsDownloadAdvertisesNoRead() {
        let restricted = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "locked.pdf",
                                   mimeType: "application/pdf",
                                   capabilities: DriveCapabilities(canEdit: false, canDownload: false,
                                                                   canTrash: false))
        let item = DriveFileProviderItem.make(from: restricted)
        XCTAssertFalse(item.capabilities.contains(.allowsReading))
    }

    func testAnAbsentCapabilitiesBlockDegradesToReadingOnly() {
        // `files.get` with a narrow field mask legitimately returns no capabilities; that must not
        // turn into a crash or an invented write permission.
        let bare = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "bare.txt", mimeType: "text/plain")
        let item = DriveFileProviderItem.make(from: bare)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
    }

    func testAPinnedItemIsTheOnlyOneTheSystemIsToldToKeepDownloaded() {
        let value = file()
        let pinned = DriveFileProviderItem.make(from: value,
                                                contentPolicy: .downloadEagerlyAndKeepDownloaded)
        let lazy = DriveFileProviderItem.make(from: value, contentPolicy: .downloadLazily)
        XCTAssertEqual(pinned.contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(lazy.contentPolicy, .downloadLazily)
    }

    func testAnUnknownBinaryTypeFallsBackToTheExtensionSoArchiveStillOpens() {
        let archive = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "bundle.zip",
                                mimeType: "application/x-not-registered")
        // Drive keeps whatever MIME string the uploader sent. `UTType(mimeType:)` would hand back a
        // dynamic `dyn.` type for it, which no application declares and so nothing can open.
        XCTAssertEqual(DriveFileProviderItem.contentType(of: archive).identifier,
                       UTType.zip.identifier)

        let noHint = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "mystery",
                               mimeType: "application/x-not-registered")
        XCTAssertEqual(DriveFileProviderItem.contentType(of: noHint), .data)
    }

    func testARegisteredMimeTypeWinsOverAConflictingExtension() {
        // The bytes are what Drive says they are; a user renaming the file does not change them.
        let mislabeled = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "photo.jpg",
                                   mimeType: "image/png")
        XCTAssertEqual(DriveFileProviderItem.contentType(of: mislabeled).identifier,
                       UTType.png.identifier)
    }

    func testAVideoIsTypedSoThePlayerAndQuickLookBothGetAHandler() {
        let movie = DriveFile(id: "1234567890abcdefghijklmnopqrstuv", name: "clip.mp4",
                              mimeType: "video/mp4", size: "4294967296")
        let item = DriveFileProviderItem.make(from: movie)
        XCTAssertEqual(item.contentType.identifier, UTType(mimeType: "video/mp4")?.identifier)
        XCTAssertEqual(item.documentSize, NSNumber(value: 4_294_967_296),
                       "a 4 GB size must survive as an Int64, not clamp")
    }

    func testItemsAreEqualOnlyWhenTheSameObjectIsAtTheSameVersion() {
        let base = file()
        let edited = DriveFile(id: base.id, name: base.name, mimeType: base.mimeType,
                               size: base.size, version: "rev-2", parents: base.parents)
        let renamed = DriveFile(id: base.id, name: "renamed.txt", mimeType: base.mimeType,
                                size: base.size, version: "rev-1", parents: base.parents)
        let same = DriveFileProviderItem.make(from: base)
        XCTAssertEqual(same, DriveFileProviderItem.make(from: base))
        XCTAssertNotEqual(same, DriveFileProviderItem.make(from: edited),
                          "a new revision must look like a change to the system")
        XCTAssertNotEqual(same, DriveFileProviderItem.make(from: renamed))
        XCTAssertEqual(same.hash, DriveFileProviderItem.make(from: base).hash)
    }

    func testTheVirtualContainersAreReadableButNotWritable() {
        let trash = DriveFileProviderItem.trashContainer()
        XCTAssertEqual(trash.itemIdentifier, ProviderIdentity.trashIdentifier)
        XCTAssertTrue(trash.capabilities.contains(.allowsContentEnumerating))
        XCTAssertFalse(trash.capabilities.contains(.allowsAddingSubItems),
                       "Drive has no way to file an object straight into the trash")

        let root = DriveFileProviderItem.driveRoot(displayName: "CloudDisk")
        XCTAssertEqual(root.itemIdentifier, ProviderIdentity.rootIdentifier)
        XCTAssertEqual(root.parentItemIdentifier, ProviderIdentity.rootIdentifier)
        XCTAssertTrue(root.capabilities.contains(.allowsAddingSubItems))

        let working = DriveFileProviderItem.workingSetContainer()
        XCTAssertEqual(working.itemIdentifier, ProviderIdentity.workingSetIdentifier)
    }
}

/// The two error domains the File Provider system accepts.
final class ProviderErrorBridgeTests: XCTestCase {

    private func bridge(_ error: DriveError) -> NSError { ProviderErrorMapper.bridge(error) }

    func testEveryDriveFailureLandsInADomainTheSystemUnderstands() {
        // Anything outside NSFileProviderErrorDomain and NSCocoaErrorDomain is treated as a
        // transient failure and retried forever, which is how a permanent error becomes a loop.
        let table: [(DriveError, String, Int)] = [
            (.notAuthenticated(revoked: true), NSFileProviderErrorDomain,
             NSFileProviderError.Code.notAuthenticated.rawValue),
            (.itemNotFound(id: "1234567890abcdefghijklmnopqrstuv"), NSFileProviderErrorDomain,
             NSFileProviderError.Code.noSuchItem.rawValue),
            (.syncCursorExpired, NSFileProviderErrorDomain,
             NSFileProviderError.Code.syncAnchorExpired.rawValue),
            (.versionUnavailable, NSFileProviderErrorDomain,
             NSFileProviderError.Code.versionNoLongerAvailable.rawValue),
            (.storageFull(detail: "Storage quota of drive filled"), NSFileProviderErrorDomain,
             NSFileProviderError.Code.insufficientQuota.rawValue),
            (.conflict(detail: "Name taken"), NSFileProviderErrorDomain,
             NSFileProviderError.Code.filenameCollision.rawValue),
            (.rateLimited(retryAfter: 5), NSFileProviderErrorDomain,
             NSFileProviderError.Code.serverUnreachable.rawValue),
            (.network(detail: "The Internet connection appears to be offline."),
             NSFileProviderErrorDomain, NSFileProviderError.Code.serverUnreachable.rawValue),
            (.serverTransient(statusCode: 503, detail: "upstream busy"), NSFileProviderErrorDomain,
             NSFileProviderError.Code.serverUnreachable.rawValue),
            (.permissionDenied(detail: "The user does not have sufficient permissions"),
             NSCocoaErrorDomain, CocoaError.Code.fileReadNoPermission.rawValue),
            (.unsupportedItem(detail: "Google Docs cannot be uploaded"), NSCocoaErrorDomain,
             CocoaError.Code.featureUnsupported.rawValue),
            (.invalidResponse(detail: "files.list"), NSCocoaErrorDomain,
             CocoaError.Code.fileReadCorruptFile.rawValue),
            (.misconfigured(detail: "GIDClientID missing"), NSCocoaErrorDomain,
             CocoaError.Code.fileReadCorruptFile.rawValue),
            (.cancelled, NSCocoaErrorDomain, CocoaError.Code.userCancelled.rawValue)
        ]

        for (error, domain, code) in table {
            let bridged = bridge(error)
            XCTAssertEqual(bridged.domain, domain, "\(error) bridged to \(bridged)")
            XCTAssertEqual(bridged.code, code, "\(error) bridged to \(bridged)")
        }
    }

    func testCancellationFromEitherFrameworkBecomesAUserCancel() {
        XCTAssertEqual(ProviderErrorMapper.bridge(CancellationError()).domain, NSCocoaErrorDomain)
        XCTAssertEqual(ProviderErrorMapper.bridge(CancellationError()).code,
                       CocoaError.Code.userCancelled.rawValue)
        let urlError = URLError(.cancelled)
        XCTAssertEqual(ProviderErrorMapper.bridge(urlError).code,
                       CocoaError.Code.userCancelled.rawValue)
    }

    func testAnUnrecognisableErrorIsWrappedRatherThanHandedOverRaw() {
        let foreign = NSError(domain: "com.example.something", code: 42, userInfo: nil)
        let bridged = ProviderErrorMapper.bridge(foreign)
        XCTAssertEqual(bridged.domain, NSCocoaErrorDomain)
        XCTAssertEqual(bridged.code, CocoaError.Code.xpcConnectionReplyInvalid.rawValue)
        // The reason has to survive into diagnostics, or a support request cannot be answered.
        XCTAssertNotNil(bridged.userInfo[NSUnderlyingErrorKey])
    }

    func testAFileProviderErrorIsPassedThroughWithoutReEncoding() {
        let original = NSFileProviderError(.syncAnchorExpired) as NSError
        XCTAssertTrue(ProviderErrorMapper.bridge(original) === original)
    }

    func testTheCoreOwnFailuresMapToCodesThatTellTheSystemWhatToDoNext() {
        let unknown = ProviderErrorMapper.bridge(
            CoreErrorProbe.unknown)
        XCTAssertEqual(unknown.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(unknown.code, NSFileProviderError.Code.noSuchItem.rawValue)

        let notEmpty = ProviderErrorMapper.bridge(CoreErrorProbe.directoryNotEmpty)
        XCTAssertEqual(notEmpty.code, NSFileProviderError.Code.directoryNotEmpty.rawValue)

        let trashWrite = ProviderErrorMapper.bridge(CoreErrorProbe.cannotCreateInTrash)
        XCTAssertEqual(trashWrite.domain, NSCocoaErrorDomain)
        XCTAssertEqual(trashWrite.code, CocoaError.Code.featureUnsupported.rawValue)

        let unsupported = ProviderErrorMapper.bridge(CoreErrorProbe.unsupportedKind)
        XCTAssertEqual(unsupported.code, CocoaError.Code.featureUnsupported.rawValue)
    }

    func testAMissingItemErrorCarriesTheItemTheSystemShouldDrop() {
        let bridged = bridge(.itemNotFound(id: "1234567890abcdefghijklmnopqrstuv"))
        let identifier = bridged.userInfo[NSFileProviderErrorNonExistentItemIdentifierKey]
            as? NSFileProviderItemIdentifier
        XCTAssertEqual(identifier,
                       ProviderIdentity.identifier(forDriveID: "1234567890abcdefghijklmnopqrstuv"))
    }

    func testABridgedErrorNeverCarriesACredentialInItsText() {
        let bridged = bridge(.invalidResponse(detail: "files.list failed"))
        let text = "\(bridged.domain) \(bridged.code) \(bridged.userInfo)"
        XCTAssertFalse(text.contains("access-token"))
        XCTAssertFalse(text.contains("refresh-token"))
    }

    func testACollisionIsReportedAsACollisionWithOrWithoutAKnownItem() {
        let existing = DriveFileProviderItem.make(from: DriveFile(
            id: "1234567890abcdefghijklmnopqrstuv", name: "taken.txt",
            mimeType: "text/plain"))
        let collision = ProviderErrorMapper.collisionError(existingItem: existing, detail: "exists")
        XCTAssertEqual(collision.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(collision.code, NSFileProviderError.Code.filenameCollision.rawValue)

        let anonymous = ProviderErrorMapper.collisionError(existingItem: nil, detail: "exists")
        XCTAssertEqual(anonymous.code, NSFileProviderError.Code.filenameCollision.rawValue)
        XCTAssertEqual(anonymous.userInfo[NSLocalizedDescriptionKey] as? String, "exists")
    }
}

/// Bridges the internal error construction so the mapping is asserted, not the enum declaration.
private enum CoreErrorProbe {
    static var unknown: CloudDiskProviderCore.CoreError { .unknownIdentifier("g:whatever") }
    static var directoryNotEmpty: CloudDiskProviderCore.CoreError { .directoryNotEmpty("a folder") }
    static var cannotCreateInTrash: CloudDiskProviderCore.CoreError { .cannotCreateInTrash }
    static var unsupportedKind: CloudDiskProviderCore.CoreError { .unsupportedKind("symlink") }
}

/// The opaque cursors that travel between the enumerator and the system.
final class ProviderCursorTests: XCTestCase {

    func testA_drivePageTokenSurvivesTheRoundTrip() {
        let page = ProviderCursor.page(drivePageToken: "CAESAhgBIiA0ZmE0ZA")
        XCTAssertEqual(ProviderCursor.drivePageToken(from: page), "CAESAhgBIiA0ZmE0ZA")
    }

    func testTheReservedInitialPagesAreReadAsNoTokenAtAll() {
        // Sending Apple's sentinel page values to Google would produce an opaque `pageToken` error on
        // the first enumeration of every folder.
        let sortedByName = NSFileProviderPage(Data(ProviderCursor.initialSortedByName))
        let sortedByDate = NSFileProviderPage(Data(ProviderCursor.initialSortedByDate))
        XCTAssertNil(ProviderCursor.drivePageToken(from: sortedByName))
        XCTAssertNil(ProviderCursor.drivePageToken(from: sortedByDate))
        XCTAssertNil(ProviderCursor.drivePageToken(from: nil))
        XCTAssertNil(ProviderCursor.drivePageToken(from: NSFileProviderPage(Data())))
    }

    func testASyncAnchorSurvivesTheRoundTrip() {
        let anchor = ProviderCursor.anchor(driveStartToken: "AAAAAAAACg4")
        XCTAssertEqual(ProviderCursor.driveStartToken(from: anchor), "AAAAAAAACg4")
        XCTAssertNil(ProviderCursor.driveStartToken(from: nil))
        XCTAssertNil(ProviderCursor.driveStartToken(from: NSFileProviderSyncAnchor(Data())))
    }

    func testACursorStaysInsideThe500ByteLimitTheSystemEnforces() {
        // An over-long page or anchor silently aborts enumeration (or expires the anchor), so the
        // values CloudDisk produces must be short by construction.
        let typical = ProviderCursor.page(drivePageToken: String(repeating: "a", count: 64))
        XCTAssertLessThanOrEqual(typical.rawValue.count, 500)
        let anchor = ProviderCursor.anchor(driveStartToken: "AAAAAAAACg4")
        XCTAssertLessThanOrEqual(anchor.rawValue.count, 500)
    }
}
