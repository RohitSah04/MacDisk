import XCTest
import FileProvider
@testable import CloudDiskKit

/// The write decision table, tested as the pure function it is.
///
/// The provider-core cases in `ProviderCoreTests` prove the wiring — that a refusal stops the request
/// and reaches the system as a write-permission error. These prove the *rules*, including the one that
/// is easiest to get wrong in the direction that hurts the user: absent permission data is not a ban.
final class WritePolicyTests: XCTestCase {

    private func file(capabilities: DriveCapabilities?, trashed: Bool = false,
                      name: String = "notes.txt", googleNative: Bool = false) -> DriveFile {
        DriveFile(id: "fileAAA", name: name,
                  mimeType: googleNative ? "application/vnd.google-apps.document" : "text/plain",
                  size: "1024", version: "rev-1", parents: ["folderAAA"],
                  trashed: trashed, capabilities: capabilities)
    }

    func testAFieldSetThatWritesNothingIsNeverRefused() {
        let readOnly = DriveCapabilities(canEdit: false)
        let unwritten: [NSFileProviderItemFields] = [[], [.tagData], [.creationDate],
                                                    [.contentModificationDate],
                                                    [.extendedAttributes], [.favoriteRank]]
        for fields in unwritten {
            XCTAssertNil(WritePolicy.refusal(for: fields, on: file(capabilities: readOnly)),
                         "a field CloudDisk never writes to Drive must not be judged on Drive's flags")
        }
    }

    func testCanEditFalseRefusesEveryWriteItGoverns() {
        let readOnly = DriveCapabilities(canEdit: false)
        let subject = file(capabilities: readOnly)
        let writable: [NSFileProviderItemFields] = [[.contents], [.filename],
                                                   [.parentItemIdentifier],
                                                   [.contents, .filename, .parentItemIdentifier]]
        for fields in writable {
            XCTAssertEqual(WritePolicy.refusal(for: fields, on: subject),
                           .itemReadOnly(name: "notes.txt"),
                           "fields \(fields) all sit under Drive's canEdit")
        }
    }

    func testTheMoveFlagRefusesOnlyTheMove() {
        let locked = DriveCapabilities(canEdit: true, canMoveItemOutOfWorld: false)
        XCTAssertEqual(WritePolicy.refusal(for: [.parentItemIdentifier],
                                           on: file(capabilities: locked)),
                       .itemLockedInFolder(name: "notes.txt"))
        XCTAssertNil(WritePolicy.refusal(for: [.contents], on: file(capabilities: locked)),
                     "editing inside the folder is allowed even when leaving it is not")
        XCTAssertNil(WritePolicy.refusal(for: [.filename], on: file(capabilities: locked)))
    }

    func testAnItemInTheTrashIsRefusedOnItsFlagRatherThanOnItsPermissions() {
        // Drive keeps reporting canEdit for an object it has trashed, so the flag alone decides:
        // File Provider shows trashed items read-only, and a write there has no meaning.
        let trashed = file(capabilities: DriveCapabilities(canEdit: true), trashed: true)
        XCTAssertEqual(WritePolicy.refusal(for: [.contents], on: trashed), .itemInTrash(name: "notes.txt"))
        XCTAssertEqual(WritePolicy.refusal(for: [.parentItemIdentifier], on: trashed),
                       .itemInTrash(name: "notes.txt"),
                       "restoring by dragging out of the trash is not a Drive operation CloudDisk has")
    }

    func testPermissionDataThatNeverArrivedIsNotATrefusal() {
        let cases = [nil, DriveCapabilities(), DriveCapabilities(canDownload: true),
                    DriveCapabilities(canAddChildren: true)]
        for permissions in cases {
            let subject = file(capabilities: permissions)
            XCTAssertNil(WritePolicy.refusal(for: [.contents], on: subject))
            XCTAssertNil(WritePolicy.refusal(for: [.filename], on: subject))
            XCTAssertNil(WritePolicy.refusal(for: [.parentItemIdentifier], on: subject))
        }
    }

    func testExplicitFlagsDecideTheContainerChecks() {
        XCTAssertEqual(WritePolicy.containerRefusal(
            of: file(capabilities: DriveCapabilities(canAddChildren: false),
                     name: "Team Shared")),
            .containerReadOnly(name: "Team Shared"))
        XCTAssertEqual(WritePolicy.containerRefusal(
            of: file(capabilities: DriveCapabilities(canAddChildren: true), trashed: true,
                     name: "Old Stuff")),
            .containerInTrash(name: "Old Stuff"),
            "the trash flag is checked first: nothing may be filed into a folder that is itself gone")
        XCTAssertNil(WritePolicy.containerRefusal(
            of: file(capabilities: DriveCapabilities(canAddChildren: true))))
        XCTAssertNil(WritePolicy.containerRefusal(of: file(capabilities: nil)),
                     "a folder Drive said nothing about stays usable until Google says otherwise")
    }

    func testEveryRefusalSaysWhatHappenedInWordsTheUserCanActOn() {
        let refusals: [WritePolicy.Refusal] = [.itemInTrash(name: "a"), .itemReadOnly(name: "a"),
                                               .itemLockedInFolder(name: "a"),
                                               .containerInTrash(name: "a"),
                                               .containerReadOnly(name: "a")]
        for refusal in refusals {
            let sentence = refusal.errorDescription ?? ""
            XCTAssertFalse(sentence.isEmpty, "an empty message becomes a bare alert")
            XCTAssertTrue(sentence.contains("“a”"), "\(sentence) must name the item")
            XCTAssertFalse(sentence.contains("fileAAA") || sentence.contains("folderAAA"),
                           "an internal id in a user-facing sentence is noise: \(sentence)")
        }
    }

    func testTheRequestsWritableContentPredicateMatchesTheCheckedFields() {
        XCTAssertTrue(WritePolicy.requestsWritableContent([.contents]))
        XCTAssertTrue(WritePolicy.requestsWritableContent([.filename]))
        XCTAssertTrue(WritePolicy.requestsWritableContent([.parentItemIdentifier]))
        XCTAssertFalse(WritePolicy.requestsWritableContent([.favoriteRank]))
        XCTAssertFalse(WritePolicy.requestsWritableContent([.lastUsedDate]))
    }
}
