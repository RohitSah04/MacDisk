
import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {

    let driveFile: GoogleDriveFile
    private let customIdentifier: NSFileProviderItemIdentifier?

    init(
        driveFile: GoogleDriveFile,
        identifier: NSFileProviderItemIdentifier? = nil
    ) {
        self.driveFile = driveFile
        self.customIdentifier = identifier
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        customIdentifier ?? NSFileProviderItemIdentifier(driveFile.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if customIdentifier == .rootContainer {
            return .rootContainer
        }

        if let parent = driveFile.parents?.first {
            return NSFileProviderItemIdentifier(parent)
        }

        return .rootContainer
    }

    var filename: String {
        driveFile.name
    }

    var contentType: UTType {
        if driveFile.isFolder {
            return .folder
        }

        return UTType(mimeType: driveFile.mimeType) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if driveFile.isFolder {
            return [.allowsContentEnumerating]
        }

        return [.allowsReading]
    }

    var itemVersion: NSFileProviderItemVersion {
        let contentVersion = (
            driveFile.modifiedTime ?? "unknown"
        ).data(using: .utf8)!

        let metadataVersion = (
            driveFile.name + (driveFile.size ?? "")
        ).data(using: .utf8)!

        return NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: metadataVersion
        )
    }

    var documentSize: NSNumber? {
        guard let size = driveFile.size,
              let bytes = Int64(size) else {
            return nil
        }

        return NSNumber(value: bytes)
    }

    var contentModificationDate: Date? {
        guard let modifiedTime = driveFile.modifiedTime else {
            return nil
        }

        return ISO8601DateFormatter().date(from: modifiedTime)
    }
}
