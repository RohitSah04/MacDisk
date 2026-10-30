import Foundation

/// Builds the Drive `files.list` query string.
///
/// Drive's `q` parameter is a mini-DSL whose string literals are single-quoted, so an unescaped
/// quote in an interpolated value changes the query. IDs are validated rather than trusted.
enum DriveQuery {

    /// Google Drive IDs are base64-ish: `[A-Za-z0-9_-]{5,}` plus the literal `root`.
    static func isValidIdentifier(_ value: String) -> Bool {
        guard value.count >= 1, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    static func escapedStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func children(of parentID: String, includeTrashed: Bool = false) throws -> String {
        guard isValidIdentifier(parentID) else {
            throw DriveError.invalidResponse(detail: "rejected unsafe parent identifier")
        }
        let base = "\(escapedStringLiteral(parentID)) in parents"
        return includeTrashed ? base : "\(base) and trashed = false"
    }

    /// Exact-name lookup inside one folder. The name is escaped, never interpolated raw.
    static func nameExactly(_ name: String, in parentID: String) throws -> String {
        guard isValidIdentifier(parentID) else {
            throw DriveError.invalidResponse(detail: "rejected unsafe parent identifier")
        }
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw DriveError.invalidResponse(detail: "empty name cannot be matched")
        }
        return "name = \(escapedStringLiteral(target)) and \(escapedStringLiteral(parentID)) in parents"
            + " and trashed = false"
    }

    /// Search inside a provider, used by the app's browser search box.
    static func nameContains(_ text: String, in parentID: String?) throws -> String {
        let sanitized = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var clauses = ["name contains '\(sanitized)'", "trashed = false"]
        if let parentID {
            // The parent id is interpolated into its own quoted literal, so it is validated rather
            // than trusted — the same rule `children(of:)` applies.
            guard isValidIdentifier(parentID) else {
                throw DriveError.invalidResponse(detail: "rejected unsafe parent identifier")
            }
            clauses.insert(escapedStringLiteral(parentID) + " in parents", at: 0)
        }
        return clauses.joined(separator: " and ")
    }
}

/// Backoff for retryable Drive failures.
public struct DriveRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 0.4, maxDelay: TimeInterval = 20) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let standard = DriveRetryPolicy()

    /// Exponential with jitter, honouring Google's `Retry-After` when it provides one.
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(maxDelay, max(0.1, retryAfter)) }
        let exponential = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        let clamped = min(maxDelay, exponential)
        return clamped + Double.random(in: 0...(clamped * 0.25))
    }
}

enum RetryRunner {
    static func run<T>(policy: DriveRetryPolicy,
                       isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
                       _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let driveError as DriveError {
                let cancelled = isCancelled()
                guard !cancelled, driveError.isRetryable, attempt < policy.maxAttempts else {
                    if cancelled { throw DriveError.cancelled }
                    throw driveError
                }
                let wait = policy.delay(forAttempt: attempt, retryAfter: driveError.retryAfter)
                try await Task.sleep(nanoseconds: UInt64(max(0.05, wait) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

extension DriveError {
    var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }
}
