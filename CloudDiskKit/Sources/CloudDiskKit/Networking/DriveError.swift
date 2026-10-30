import Foundation

/// Typed failure taxonomy for the Drive layer.
///
/// The File Provider extension must translate these into the handful of error codes the system
/// understands (`NSFileProviderErrorDomain`, `NSCocoaErrorDomain`), and the app must turn them into
/// user-facing copy. Collapsing everything into "HTTP 4xx with a body" — which is what the
/// prototype did — makes both of those impossible.
public enum DriveError: Error, Equatable, Sendable {

    /// No credential, or Google answered `invalid_grant`: consent was revoked.
    case notAuthenticated(revoked: Bool)
    /// 403 / 401 after a successful refresh: the token is valid but does not cover this operation.
    case permissionDenied(detail: String)
    /// 404: gone remotely. The system must remove its replica.
    case itemNotFound(id: String)
    /// 410 on the changes feed: the sync cursor expired, a full resync is required.
    case syncCursorExpired
    /// 404 on a version that no longer exists.
    case versionUnavailable
    /// 429 or 500 with `rateLimitExceeded`.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx, DNS, timeouts: worth retrying.
    case serverTransient(statusCode: Int, detail: String)
    /// The connection failed at the transport level.
    case network(detail: String)
    /// 409 / 416 style conflicts, including a filename or version clash.
    case conflict(detail: String)
    /// Drive is full or the item exceeds limits.
    case storageFull(detail: String)
    /// The item cannot be served the way the caller asked (e.g. Workspace doc has no media).
    case unsupportedItem(detail: String)
    /// A response we could not decode or a state the client could not build.
    case invalidResponse(detail: String)
    /// Missing GIDClientID / keychain group / app group — a build or install problem, not a bug.
    case misconfigured(detail: String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverTransient, .network:
            return true
        case .permissionDenied, .itemNotFound, .notAuthenticated, .syncCursorExpired,
             .versionUnavailable, .conflict, .storageFull, .unsupportedItem,
             .invalidResponse, .misconfigured, .cancelled:
            return false
        }
    }

    /// Whether the user has to act. Anything here should raise UI, not a silent retry.
    public var requiresUserAction: Bool {
        switch self {
        case .notAuthenticated, .permissionDenied, .storageFull:
            return true
        default:
            return false
        }
    }

    public static func describe(statusCode: Int, googleReason: String?, message: String) -> DriveError {
        let reason = googleReason?.lowercased() ?? ""
        let lowerMessage = message.lowercased()

        switch statusCode {
        case 401:
            return .notAuthenticated(revoked: false)
        case 403:
            if reason.contains("auth") || lowerMessage.contains("oauth")
                || lowerMessage.contains("permission disabled") {
                return .notAuthenticated(revoked: true)
            }
            if reason == "userratelexceeded" || reason == "rateLimitExceeded".lowercased() {
                return .rateLimited(retryAfter: nil)
            }
            if reason.contains("storagequota") || lowerMessage.contains("storage quota") {
                return .storageFull(detail: message)
            }
            return .permissionDenied(detail: message)
        case 404:
            return .itemNotFound(id: message)
        case 409:
            return .conflict(detail: message)
        case 410:
            if reason.contains("expiredstartpagetoken") || lowerMessage.contains("page token") {
                return .syncCursorExpired
            }
            return .itemNotFound(id: message)
        case 410...499 where reason.contains("gone"):
            return .syncCursorExpired
        case 416:
            return .conflict(detail: message)
        case 429:
            return .rateLimited(retryAfter: nil)
        case 500...599:
            return .serverTransient(statusCode: statusCode, detail: message)
        default:
            return .invalidResponse(detail: "HTTP \(statusCode): \(message)")
        }
    }
}

extension DriveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated(let revoked):
            return revoked
                ? "Google access was revoked. Reconnect your Google account in CloudDisk."
                : "CloudDisk is not signed in to Google Drive. Connect your account in CloudDisk."
        case .permissionDenied(let detail):
            return "Google Drive refused this operation: \(detail)"
        case .itemNotFound:
            return "This file is no longer in Google Drive."
        case .syncCursorExpired:
            return "CloudDisk's change history with Google Drive expired; a full rescan is needed."
        case .versionUnavailable:
            return "That version of the file is no longer available in Google Drive."
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Google Drive is rate-limiting CloudDisk; retrying in \(Int($0))s." }
                ?? "Google Drive is rate-limiting CloudDisk. Try again shortly."
        case .serverTransient(let code, let detail):
            return "Google Drive is temporarily unavailable (\(code)): \(detail)"
        case .network(let detail):
            return "No usable connection to Google Drive: \(detail)"
        case .conflict(let detail):
            return "Conflicting change: \(detail)"
        case .storageFull(let detail):
            return "Google Drive storage is full: \(detail)"
        case .unsupportedItem(let detail):
            return "Google Drive cannot serve this item as a file: \(detail)"
        case .invalidResponse(let detail):
            return "Unexpected response from Google Drive: \(detail)"
        case .misconfigured(let detail):
            return "CloudDisk is not configured correctly: \(detail)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}
