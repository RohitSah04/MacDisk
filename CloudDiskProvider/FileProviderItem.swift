
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {

    private let identifier: NSFileProviderItemIdentifier
    private let displayName: String
    private let type: UTType

    init(
        identifier: NSFileProviderItemIdentifier,
        filename: String? = nil,
        contentType: UTType? = nil
    ) {
        self.identifier = identifier
        self.displayName = filename ?? identifier.rawValue
        self.type = contentType ?? (
            identifier == .rootContainer ? .folder : .data
        )
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        identifier
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        .rootContainer
    }

    var filename: String {
        displayName
    }

    var contentType: UTType {
        type
    }

    var capabilities: NSFileProviderItemCapabilities {
        if identifier == .rootContainer {
            return [.allowsContentEnumerating]
        }

        return [.allowsReading]
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("cloud-disk-v1".utf8),
            metadataVersion: Data(displayName.utf8)
        )
    }
}
