
import FileProvider
import Foundation

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    required init(domain: NSFileProviderDomain) {
        super.init()
    }

    func invalidate() {
        // No persistent connection to invalidate.
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {

        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            let rootFile = GoogleDriveFile(
                id: "root",
                name: "Google Drive",
                mimeType: "application/vnd.google-apps.folder",
                size: nil,
                modifiedTime: nil,
                parents: nil
            )

            completionHandler(
                FileProviderItem(
                    driveFile: rootFile,
                    identifier: .rootContainer
                ),
                nil
            )

            progress.completedUnitCount = 1
            return progress
        }

        Task {
            do {
                let file = try await GoogleDriveService.getFile(
                    id: identifier.rawValue
                )

                completionHandler(
                    FileProviderItem(driveFile: file),
                    nil
                )

            } catch {
                completionHandler(nil, error)
            }

            progress.completedUnitCount = 1
        }

        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {

        completionHandler(
            nil,
            nil,
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [:]
            )
        )

        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {

        completionHandler(itemTemplate, [], false, nil)
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {

        completionHandler(
            nil,
            [],
            false,
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [:]
            )
        )

        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {

        completionHandler(
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [:]
            )
        )

        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {

        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier
        )
    }
}
