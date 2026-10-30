
import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let enumeratedItemIdentifier:
        NSFileProviderItemIdentifier

    private let anchor = NSFileProviderSyncAnchor(
        Data("CloudDisk-v1".utf8)
    )

    init(
        enumeratedItemIdentifier: NSFileProviderItemIdentifier
    ) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        super.init()
    }

    func invalidate() {
        // No persistent connection to invalidate.
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let parentID = enumeratedItemIdentifier == .rootContainer
            ? "root"
            : enumeratedItemIdentifier.rawValue

        Task {
            do {
                let files = try await GoogleDriveService.listFiles(
                    in: parentID
                )

                let items = files.map {
                    FileProviderItem(driveFile: $0)
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)

                print(
                    "CloudDisk: Enumerated \(items.count) Google Drive items."
                )

            } catch {
                print(
                    "CloudDisk enumeration error: \(error.localizedDescription)"
                )

                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(
            upTo: self.anchor,
            moreComing: false
        )
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(anchor)
    }
}
