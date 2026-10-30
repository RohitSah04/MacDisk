import Foundation
import FileProvider

public let CloudDiskErrorDomain = "dev.rohitsah.clouddisk"

/// Translates CloudDisk's errors into the two domains the File Provider system accepts.
///
/// Anything outside `NSFileProviderErrorDomain` and `NSCocoaErrorDomain` is treated by the system as
/// an unspecified transient failure and retried, which would silently loop on permanent errors such
/// as "no such item". Every failure path therefore has to land on one of the codes below.
public enum ProviderErrorMapper {

    public static func bridge(_ error: Error) -> NSError {
        if error is NSFileProviderError {
            // Already in the right domain: the system reads the code straight off it.
            return error as NSError
        }
        if let coreError = error as? CloudDiskProviderCore.CoreError {
            return bridge(coreError: coreError)
        }
        if error is CancellationError {
            return cocoa(.userCancelled)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return cocoa(.userCancelled)
        }

        guard let driveError = error as? DriveError else {
            return cocoaWrap(underlying: error)
        }

        switch driveError {
        case .notAuthenticated:
            return fileProvider(.notAuthenticated)
        case .itemNotFound(let id):
            return NSError.fileProviderErrorForNonExistentItem(
                withIdentifier: ProviderIdentity.identifier(forDriveID: id))
        case .syncCursorExpired:
            return fileProvider(.syncAnchorExpired)
        case .versionUnavailable:
            return fileProvider(.versionNoLongerAvailable)
        case .storageFull(let detail):
            return fileProvider(.insufficientQuota, detail: detail)
        case .rateLimited, .network, .serverTransient:
            // Unreachable right now: the system marks the domain offline and backs off instead of
            // retrying the operation in a tight loop.
            return fileProvider(.serverUnreachable)
        case .permissionDenied(let detail):
            return cocoa(.fileReadNoPermission, detail: detail)
        case .conflict(let detail):
            return fileProvider(.filenameCollision, detail: detail)
        case .unsupportedItem(let detail):
            return cocoa(.featureUnsupported, detail: detail)
        case .invalidResponse(let detail), .misconfigured(let detail):
            // A broken install or an undecodable reply is not something the system can fix by
            // retrying, so report it as a permanent file failure with the reason attached.
            return cocoa(.fileReadCorruptFile, detail: detail)
        case .cancelled:
            return cocoa(.userCancelled)
        }
    }

    /// A name or path collision. When the extension already knows the offending item, reporting the
    /// collision explicitly lets the system bounce the name instead of failing the operation.
    public static func collisionError(existingItem: (any NSFileProviderItem)?,
                                      detail: String) -> NSError {
        guard let existingItem else {
            return fileProvider(.filenameCollision, detail: detail)
        }
        return NSError.fileProviderErrorForCollision(with: existingItem)
    }

    /// True for the one failure that also changes what the extension must store.
    ///
    /// An expired anchor is the only error the system recovers from by asking for a new one, so the
    /// dead Drive token has to be dropped from shared state at the same moment — otherwise
    /// `currentSyncAnchor` hands the same unusable value back and the two sides loop. Checked on the
    /// bridged `NSError` because the Swift `NSFileProviderError` value and the `NSError` a caller
    /// receives after one round trip are different types.
    static func isAnchorExpired(_ error: Error) -> Bool {
        if let driveError = error as? DriveError, case .syncCursorExpired = driveError {
            return true
        }
        let bridged = error as NSError
        return bridged.domain == NSFileProviderErrorDomain
            && bridged.code == NSFileProviderError.Code.syncAnchorExpired.rawValue
    }

    /// The core's own failures map onto dedicated File Provider codes, because each one tells the
    /// system what to do next rather than merely that something went wrong.
    static func bridge(coreError: CloudDiskProviderCore.CoreError) -> NSError {
        switch coreError {
        case .unknownIdentifier(let id):
            // The system removes its replica when it hears this, which is the correct outcome: the
            // object genuinely is not in Drive any more.
            return NSError.fileProviderErrorForNonExistentItem(
                withIdentifier: NSFileProviderItemIdentifier(id))
        case .directoryNotEmpty:
            // Apple requires this exact code for a non-recursive delete of a non-empty folder; the
            // system then re-creates the item instead of losing the children.
            return fileProvider(.directoryNotEmpty, detail: describe(coreError))
        case .cannotCreateInTrash, .unsupportedKind:
            return cocoa(.featureUnsupported, detail: describe(coreError))
        case .writeNotAllowed:
            // The write-specific code, because this is the failure Finder shows next to the item the
            // user tried to change; a read code would describe a problem they never had.
            return cocoa(.fileWriteNoPermission, detail: describe(coreError))
        }
    }

    // MARK: Construction helpers

    private static func fileProvider(_ code: NSFileProviderError.Code,
                                     detail: String? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let detail { userInfo[NSLocalizedDescriptionKey] = detail }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    private static func fileProvider(_ error: NSFileProviderError) -> NSError {
        fileProvider(error.code)
    }

    private static func cocoa(_ code: CocoaError.Code, detail: String? = nil) -> NSError {
        var userInfo: [String: Any] = [
            NSUnderlyingErrorKey: NSError(domain: CloudDiskErrorDomain, code: 1,
                                          userInfo: detail.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
        ]
        if let detail { userInfo[NSLocalizedDescriptionKey] = detail }
        return NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// Errors that cannot be expressed in the two accepted domains must still be reported there,
    /// wrapped so the reason survives into diagnostics. `xpcConnectionReplyInvalid` is the code
    /// Apple prescribes for exactly this case.
    private static func cocoaWrap(underlying: Error) -> NSError {
        let description = (underlying as? LocalizedError)?.errorDescription
            ?? underlying.localizedDescription
        return NSError(domain: NSCocoaErrorDomain,
                       code: CocoaError.Code.xpcConnectionReplyInvalid.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: description,
                                  NSUnderlyingErrorKey: underlying])
    }

    private static func describe(_ error: LocalizedError) -> String {
        error.errorDescription ?? "CloudDisk could not complete the operation."
    }
}

/// Encodes and decodes the cursors the system hands back to an enumerator.
///
/// A page carries a Drive `pageToken`; an anchor carries a Drive changes `startPageToken`. Both are
/// opaque ASCII from Google, so they travel as UTF-8 bytes. The two reserved initial-page values the
/// system passes on a first enumeration have to be recognised rather than sent to Google.
enum ProviderCursor {

    static func page(drivePageToken token: String) -> NSFileProviderPage {
        NSFileProviderPage(Data(token.utf8))
    }

    static func drivePageToken(from page: NSFileProviderPage?) -> String? {
        guard let page else { return nil }
        let data = page.rawValue
        if data == initialSortedByName || data == initialSortedByDate { return nil }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static let initialSortedByName: Data = NSFileProviderPage.initialPageSortedByName as Data
    static let initialSortedByDate: Data = NSFileProviderPage.initialPageSortedByDate as Data

    static func anchor(driveStartToken token: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(token.utf8))
    }

    static func driveStartToken(from anchor: NSFileProviderSyncAnchor?) -> String? {
        guard let anchor else { return nil }
        let text = String(data: anchor.rawValue, encoding: .utf8)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
