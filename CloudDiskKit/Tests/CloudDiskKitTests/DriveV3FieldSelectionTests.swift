import XCTest
@testable import CloudDiskKit

/// Every `fields=` string CloudDisk sends to Drive, checked against Drive's own v3 schema.
///
/// Drive validates a field selection strictly and answers a name its schema does not define with
/// `400 Invalid field selection <name>` — for the *whole* request, not only that field. Five v2-era
/// names (`picture`, `targetType`, `canMoveItemOutOfWorld`, `canUpdate`, `newPageToken`) sat in the
/// shared selection long enough to make every folder enumerate as empty in Finder, and the suite
/// stayed green because the stubbed transport never asked whether Google accepts the names. Here the
/// schema is asked.
///
/// `schema` below is generated, not hand-written. Refresh it from the discovery document Google
/// publishes for this API version:
///
///     curl -s https://www.googleapis.com/discovery/v1/apis/drive/v3/rest
///
/// then, for every resource reachable from File, FileList, ChangeList, Change, About and Revision,
/// list its property names mapped to the resource a sub-selection resolves to — the property's
/// `$ref`, its array `items`, a qualified `Resource.property` for Drive's inline objects, or "" for
/// a leaf. Snapshot taken 2026-10-31.
final class DriveV3FieldSelectionTests: XCTestCase {

    private let schema: [String: [String: String]] = [
        "About": ["appInstalled": "", "canCreateDrives": "", "canCreateTeamDrives": "", "driveThemes": "About.driveThemes", "exportFormats": "", "folderColorPalette": "", "importFormats": "", "kind": "", "maxImportSizes": "", "maxUploadSize": "", "storageQuota": "About.storageQuota", "teamDriveThemes": "About.teamDriveThemes", "user": "User"],
        "About.driveThemes": ["backgroundImageLink": "", "colorRgb": "", "id": ""],
        "About.storageQuota": ["limit": "", "usage": "", "usageInDrive": "", "usageInDriveTrash": ""],
        "About.teamDriveThemes": ["backgroundImageLink": "", "colorRgb": "", "id": ""],
        "Change": ["changeType": "", "drive": "Drive", "driveId": "", "file": "File", "fileId": "", "kind": "", "removed": "", "teamDrive": "TeamDrive", "teamDriveId": "", "time": "", "type": ""],
        "ChangeList": ["changes": "Change", "kind": "", "newStartPageToken": "", "nextPageToken": ""],
        "ClientEncryptionDetails": ["decryptionMetadata": "DecryptionMetadata", "encryptionState": ""],
        "ContentRestriction": ["ownerRestricted": "", "readOnly": "", "reason": "", "restrictingUser": "User", "restrictionTime": "", "systemRestricted": "", "type": ""],
        "DecryptionMetadata": ["aes256GcmChunkSize": "", "encryptionResourceKeyHash": "", "jwt": "", "kaclsId": "", "kaclsName": "", "keyFormat": "", "wrappedKey": ""],
        "DownloadRestriction": ["restrictedForReaders": "", "restrictedForWriters": ""],
        "DownloadRestrictionsMetadata": ["effectiveDownloadRestrictionWithContext": "DownloadRestriction", "itemDownloadRestriction": "DownloadRestriction"],
        "Drive": ["backgroundImageFile": "Drive.backgroundImageFile", "backgroundImageLink": "", "capabilities": "Drive.capabilities", "colorRgb": "", "createdTime": "", "hidden": "", "id": "", "kind": "", "name": "", "orgUnitId": "", "restrictions": "Drive.restrictions", "themeId": ""],
        "Drive.backgroundImageFile": ["id": "", "width": "", "xCoordinate": "", "yCoordinate": ""],
        "Drive.capabilities": ["canAddChildren": "", "canChangeCopyRequiresWriterPermissionRestriction": "", "canChangeDomainUsersOnlyRestriction": "", "canChangeDownloadRestriction": "", "canChangeDriveBackground": "", "canChangeDriveMembersOnlyRestriction": "", "canChangeSharingFoldersRequiresOrganizerPermissionRestriction": "", "canComment": "", "canCopy": "", "canDeleteChildren": "", "canDeleteDrive": "", "canDownload": "", "canEdit": "", "canListChildren": "", "canManageMembers": "", "canReadRevisions": "", "canRename": "", "canRenameDrive": "", "canResetDriveRestrictions": "", "canShare": "", "canTrashChildren": ""],
        "Drive.restrictions": ["adminManagedRestrictions": "", "copyRequiresWriterPermission": "", "domainUsersOnly": "", "downloadRestriction": "DownloadRestriction", "driveMembersOnly": "", "sharingFoldersRequiresOrganizerPermission": ""],
        "File": ["appProperties": "", "capabilities": "File.capabilities", "clientEncryptionDetails": "ClientEncryptionDetails", "contentHints": "File.contentHints", "contentRestrictions": "ContentRestriction", "copyRequiresWriterPermission": "", "createdTime": "", "description": "", "downloadRestrictions": "DownloadRestrictionsMetadata", "driveId": "", "explicitlyTrashed": "", "exportLinks": "", "fileExtension": "", "folderColorRgb": "", "fullFileExtension": "", "hasAugmentedPermissions": "", "hasThumbnail": "", "headRevisionId": "", "iconLink": "", "id": "", "imageMediaMetadata": "File.imageMediaMetadata", "inheritedPermissionsDisabled": "", "isAppAuthorized": "", "kind": "", "labelInfo": "File.labelInfo", "lastModifyingUser": "User", "linkShareMetadata": "File.linkShareMetadata", "md5Checksum": "", "mimeType": "", "modifiedByMe": "", "modifiedByMeTime": "", "modifiedTime": "", "name": "", "originalFilename": "", "ownedByMe": "", "owners": "User", "parents": "", "permissionIds": "", "permissions": "Permission", "properties": "", "quotaBytesUsed": "", "resourceKey": "", "sha1Checksum": "", "sha256Checksum": "", "shared": "", "sharedWithMeTime": "", "sharingUser": "User", "shortcutDetails": "File.shortcutDetails", "size": "", "spaces": "", "starred": "", "teamDriveId": "", "thumbnailLink": "", "thumbnailVersion": "", "trashed": "", "trashedTime": "", "trashingUser": "User", "version": "", "videoMediaMetadata": "File.videoMediaMetadata", "viewedByMe": "", "viewedByMeTime": "", "viewersCanCopyContent": "", "webContentLink": "", "webViewLink": "", "writersCanShare": ""],
        "File.capabilities": ["canAcceptOwnership": "", "canAccessViaGenAi": "", "canAddChildren": "", "canAddFolderFromAnotherDrive": "", "canAddMyDriveParent": "", "canChangeCopyRequiresWriterPermission": "", "canChangeItemDownloadRestriction": "", "canChangeSecurityUpdateEnabled": "", "canChangeViewersCanCopyContent": "", "canComment": "", "canCopy": "", "canDelete": "", "canDeleteChildren": "", "canDisableInheritedPermissions": "", "canDownload": "", "canEdit": "", "canEnableInheritedPermissions": "", "canListChildren": "", "canModifyContent": "", "canModifyContentRestriction": "", "canModifyEditorContentRestriction": "", "canModifyLabels": "", "canModifyOwnerContentRestriction": "", "canMoveChildrenOutOfDrive": "", "canMoveChildrenOutOfTeamDrive": "", "canMoveChildrenWithinDrive": "", "canMoveChildrenWithinTeamDrive": "", "canMoveItemIntoTeamDrive": "", "canMoveItemOutOfDrive": "", "canMoveItemOutOfTeamDrive": "", "canMoveItemWithinDrive": "", "canMoveItemWithinTeamDrive": "", "canMoveTeamDriveItem": "", "canReadDrive": "", "canReadLabels": "", "canReadRevisions": "", "canReadTeamDrive": "", "canRemoveChildren": "", "canRemoveContentRestriction": "", "canRemoveMyDriveParent": "", "canRename": "", "canShare": "", "canStartApproval": "", "canTrash": "", "canTrashChildren": "", "canUntrash": ""],
        "File.contentHints": ["indexableText": "", "thumbnail": "File.contentHints.thumbnail"],
        "File.contentHints.thumbnail": ["image": "", "mimeType": ""],
        "File.imageMediaMetadata": ["aperture": "", "cameraMake": "", "cameraModel": "", "colorSpace": "", "exposureBias": "", "exposureMode": "", "exposureTime": "", "flashUsed": "", "focalLength": "", "height": "", "isoSpeed": "", "lens": "", "location": "File.imageMediaMetadata.location", "maxApertureValue": "", "meteringMode": "", "rotation": "", "sensor": "", "subjectDistance": "", "time": "", "whiteBalance": "", "width": ""],
        "File.imageMediaMetadata.location": ["altitude": "", "latitude": "", "longitude": ""],
        "File.labelInfo": ["labels": "Label"],
        "File.linkShareMetadata": ["securityUpdateEligible": "", "securityUpdateEnabled": ""],
        "File.shortcutDetails": ["targetId": "", "targetMimeType": "", "targetResourceKey": ""],
        "File.videoMediaMetadata": ["durationMillis": "", "height": "", "width": ""],
        "FileList": ["files": "File", "incompleteSearch": "", "kind": "", "nextPageToken": ""],
        "Label": ["fields": "", "id": "", "kind": "", "revisionId": ""],
        "Permission": ["allowFileDiscovery": "", "deleted": "", "displayName": "", "domain": "", "emailAddress": "", "expirationTime": "", "id": "", "inheritedPermissionsDisabled": "", "kind": "", "pendingOwner": "", "permissionDetails": "Permission.permissionDetails", "photoLink": "", "role": "", "teamDrivePermissionDetails": "Permission.teamDrivePermissionDetails", "type": "", "view": ""],
        "Permission.permissionDetails": ["inherited": "", "inheritedFrom": "", "permissionType": "", "role": ""],
        "Permission.teamDrivePermissionDetails": ["inherited": "", "inheritedFrom": "", "role": "", "teamDrivePermissionType": ""],
        "Revision": ["exportLinks": "", "id": "", "keepForever": "", "kind": "", "lastModifyingUser": "User", "md5Checksum": "", "mimeType": "", "modifiedTime": "", "originalFilename": "", "publishAuto": "", "published": "", "publishedLink": "", "publishedOutsideDomain": "", "size": ""],
        "TeamDrive": ["backgroundImageFile": "TeamDrive.backgroundImageFile", "backgroundImageLink": "", "capabilities": "TeamDrive.capabilities", "colorRgb": "", "createdTime": "", "id": "", "kind": "", "name": "", "orgUnitId": "", "restrictions": "TeamDrive.restrictions", "themeId": ""],
        "TeamDrive.backgroundImageFile": ["id": "", "width": "", "xCoordinate": "", "yCoordinate": ""],
        "TeamDrive.capabilities": ["canAddChildren": "", "canChangeCopyRequiresWriterPermissionRestriction": "", "canChangeDomainUsersOnlyRestriction": "", "canChangeDownloadRestriction": "", "canChangeSharingFoldersRequiresOrganizerPermissionRestriction": "", "canChangeTeamDriveBackground": "", "canChangeTeamMembersOnlyRestriction": "", "canComment": "", "canCopy": "", "canDeleteChildren": "", "canDeleteTeamDrive": "", "canDownload": "", "canEdit": "", "canListChildren": "", "canManageMembers": "", "canReadRevisions": "", "canRemoveChildren": "", "canRename": "", "canRenameTeamDrive": "", "canResetTeamDriveRestrictions": "", "canShare": "", "canTrashChildren": ""],
        "TeamDrive.restrictions": ["adminManagedRestrictions": "", "copyRequiresWriterPermission": "", "domainUsersOnly": "", "downloadRestriction": "DownloadRestriction", "sharingFoldersRequiresOrganizerPermission": "", "teamMembersOnly": ""],
        "User": ["displayName": "", "emailAddress": "", "kind": "", "me": "", "permissionId": "", "photoLink": ""],
    ]

    private struct Selection {
        let name: String
        let subs: [Selection]
    }

    /// Google's field-selection grammar, as far as CloudDisk uses it: comma-separated names, each
    /// optionally followed by a parenthesised sub-selection.
    private func parse(_ text: [Character]) -> [Selection] {
        var out: [Selection] = []
        var name: [Character] = []
        var index = 0

        func flush() {
            let token = String(name)
            if !token.isEmpty { out.append(Selection(name: token, subs: [])) }
            name = []
        }

        while index < text.count {
            let character = text[index]
            switch character {
            case ",":
                flush()
            case "(":
                let token = String(name)
                name = []
                var depth = 1
                var cursor = index + 1
                var inner: [Character] = []
                while cursor < text.count, depth > 0 {
                    if text[cursor] == "(" { depth += 1 }
                    if text[cursor] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(text[cursor])
                    cursor += 1
                }
                out.append(Selection(name: token, subs: parse(inner)))
                index = cursor
            case ")":
                flush()
            default:
                name.append(character)
            }
            index += 1
        }
        flush()
        return out
    }

    /// Collects the names Drive would reject, so one failing leaf still reports every other one.
    private func validate(_ selection: [Selection], in resource: String, at path: String,
                          _ problems: inout [String]) {
        guard let properties = schema[resource] else {
            problems.append("\(path): “\(resource)” is not in the schema table")
            return
        }
        for item in selection {
            guard let child = properties[item.name] else {
                problems.append("\(path).\(item.name) — v3’s \(resource) has no such field")
                continue
            }
            guard !item.subs.isEmpty else { continue }
            guard !child.isEmpty else {
                problems.append("\(path).\(item.name) — not an object, so it has no fields to select")
                continue
            }
            validate(item.subs, in: child, at: "\(path).\(item.name)", &problems)
        }
    }

    func testEveryFieldSelectionNamesFieldsDriveV3Has() {
        let selections: [(label: String, selection: String, root: String)] = [
            ("DriveFile.fields", DriveFile.fields, "File"),
            ("DriveFile.listFields", DriveFile.listFields, "FileList"),
            ("DriveFile.changesFields", DriveFile.changesFields, "ChangeList"),
            ("DriveFile.deleteDecisionFields", DriveFile.deleteDecisionFields, "File"),
            ("DriveAbout.fields", DriveAbout.fields, "About")
        ]

        var problems: [String] = []
        for entry in selections {
            validate(parse(Array(entry.selection)), in: entry.root, at: entry.label, &problems)
        }
        XCTAssertTrue(problems.isEmpty,
                      "Drive answers these requests with 400 Invalid field selection:\n"
                          + problems.joined(separator: "\n"))
    }

    func testTheGuardItselfRejectsAKnownV2Name() {
        // A validator that accepts everything is what let the five bad names through.
        var problems: [String] = []
        validate(parse(Array("owners(displayName,emailAddress,picture)")), in: "File",
                 at: "sample", &problems)
        XCTAssertEqual(problems, ["sample.owners.picture — v3’s User has no such field"])
    }

    func testTheMoveFlagsAskedForAreTheOnesV3Reports() {
        XCTAssertTrue(DriveFile.fields.contains("canMoveItemWithinDrive"))
        XCTAssertTrue(DriveFile.fields.contains("canMoveItemOutOfDrive"))
        XCTAssertFalse(DriveFile.fields.contains("canMoveItemOutOfWorld"),
                       "v2 vocabulary: Drive has no such field, so the whole request fails")
    }
}
