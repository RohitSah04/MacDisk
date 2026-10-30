import Foundation

/// Where CloudDisk keeps state that both the app and the File Provider extension must see.
///
/// Everything lives in the shared App Group container as small JSON files, written atomically. The
/// extension is the only writer of the sync cursor; the pin set is written by whichever process the
/// user acted in, so it is re-read immediately before each write to keep last-write-wins honest.
public actor ProviderState {

    public enum StateError: LocalizedError, Equatable {
        case appGroupUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable(let group):
                return "CloudDisk's shared storage container for \(group) is not available. Both the app and its File Provider extension need the same App Group."
            }
        }
    }

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates the App Group container directory for a domain.
    public static func shared(config: CloudDiskConfig,
                              fileManager: FileManager = .default) throws -> ProviderState {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: CloudDiskConfig.appGroupIdentifier) else {
            throw StateError.appGroupUnavailable(CloudDiskConfig.appGroupIdentifier)
        }
        let domainDirectory = container
            .appendingPathComponent("domains", isDirectory: true)
            .appendingPathComponent(config.domainIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: domainDirectory, withIntermediateDirectories: true)
        return ProviderState(directory: domainDirectory)
    }

    private func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    /// Reads a JSON file, treating unreadable or corrupt content as absent instead of an error: a
    /// damaged cursor only costs a rescan, it must not wedge the extension.
    private func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try encoder.encode(value)
        let target = url(for: name)
        let temporary = target.appendingPathExtension("writing")
        try data.write(to: temporary, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
    }

    // MARK: Sync cursor

    struct Cursor: Codable, Equatable {
        var startPageToken: String
        var updatedAt: Date
    }

    public func syncCursor() -> String? { read(Cursor.self, name: "changes-cursor.json")?.startPageToken }

    public func setSyncCursor(_ token: String) throws {
        try write(Cursor(startPageToken: token, updatedAt: Date()), name: "changes-cursor.json")
    }

    /// Forces the next working-set enumeration to restart from a fresh token. Used when the
    /// extension has learned that its cursor is no longer usable.
    public func clearSyncCursor() throws {
        try? FileManager.default.removeItem(at: url(for: "changes-cursor.json"))
    }

    // MARK: Offline pinning

    struct Pins: Codable, Equatable {
        var driveIDs: [String]
    }

    /// Drive items the user asked CloudDisk to keep available offline.
    public func pinnedDriveIDs() -> Set<String> {
        Set(read(Pins.self, name: "pinned-items.json")?.driveIDs ?? [])
    }

    public func isPinned(_ driveID: String) -> Bool { pinnedDriveIDs().contains(driveID) }

    /// Returns the resulting pin set so the caller can publish the change without re-reading.
    @discardableResult
    public func setPinned(_ driveID: String, _ pinned: Bool) throws -> Set<String> {
        // Read-then-write rather than a cached copy: the app and the extension both mutate this.
        var current = pinnedDriveIDs()
        if pinned { current.insert(driveID) } else { current.remove(driveID) }
        try write(Pins(driveIDs: current.sorted()), name: "pinned-items.json")
        return current
    }

    // MARK: Activity log

    /// One line of the user-facing activity log. It never carries tokens, URLs with credentials or
    /// response bodies — only what the user needs to understand what CloudDisk did.
    public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case download, upload, create, rename, move, copy, delete, synchronize, signOut, signIn, other
        }

        public enum Outcome: String, Codable, Sendable {
            case success, failure, cancelled
        }

        public var id: String
        public var kind: Kind
        public var outcome: Outcome
        public var subject: String
        public var detail: String?
        public var date: Date

        public init(kind: Kind, outcome: Outcome, subject: String, detail: String? = nil, date: Date = Date()) {
            id = UUID().uuidString
            self.kind = kind
            self.outcome = outcome
            self.subject = subject
            self.detail = detail
            self.date = date
        }
    }

    /// The activity log is a directory of one-file-per-event records. Concurrent writers (app and
    /// extension) then never read-modify-write the same file, which is the only way to make this
    /// cross-process safe without a database.
    private var activityDirectory: URL {
        directory.appendingPathComponent("activity", isDirectory: true)
    }

    public func record(_ event: ActivityEvent) throws {
        try FileManager.default.createDirectory(at: activityDirectory, withIntermediateDirectories: true)
        let name = "\(Int(event.date.timeIntervalSince1970 * 1000))-\(event.id).json"
        let data = try encoder.encode(event)
        try data.write(to: activityDirectory.appendingPathComponent(name), options: [.atomic])
        try trimActivityLog(keeping: 300)
    }

    public func recentActivity(limit: Int = 100) -> [ActivityEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: activityDirectory, includingPropertiesForKeys: nil)) ?? []
        let events = files.compactMap { url -> ActivityEvent? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ActivityEvent.self, from: data)
        }
        return Array(events.sorted { $0.date > $1.date }.prefix(max(1, limit)))
    }

    public func clearActivity() throws {
        try? FileManager.default.removeItem(at: activityDirectory)
    }

    private func trimActivityLog(keeping count: Int) throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: activityDirectory, includingPropertiesForKeys: nil)) ?? []
        guard files.count > count else { return }
        // File names start with the event's epoch-milliseconds, so ordering by name orders by time and
        // dropping from the front removes the oldest records.
        let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in ordered.dropFirst(ordered.count - count) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension CloudDiskConfig {
    /// The App Group container directory this domain's state lives in, or nil when the App Group is
    /// not provisioned for this build.
    public func stateDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: CloudDiskConfig.appGroupIdentifier) else { return nil }
        return container
            .appendingPathComponent("domains", isDirectory: true)
            .appendingPathComponent(domainIdentifier, isDirectory: true)
    }
}
