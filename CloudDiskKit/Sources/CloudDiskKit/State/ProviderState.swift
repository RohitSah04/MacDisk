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
    /// How close together two access notes for the same object have to be to collapse into one write.
    private let accessCoalesceInterval: TimeInterval
    /// The last access time actually written per Drive id, so a burst of extent reads for one streaming
    /// file costs one file write instead of one per range.
    private var lastAccessWrite: [String: Date] = [:]

    public init(directory: URL, accessCoalesceInterval: TimeInterval = 30) {
        self.directory = directory
        self.accessCoalesceInterval = accessCoalesceInterval
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
    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        read(type, at: url(for: name))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        let temporary = url.appendingPathExtension("writing")
        try data.write(to: temporary, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try write(value, to: url(for: name))
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

    // MARK: My Drive identity

    /// Drive's real id for the account's "My Drive" folder, as last observed.
    ///
    /// `files.list(q: "'root' in parents")` answers children whose `parents` names that id rather
    /// than the `root` alias, so without this the provider parents every top-level item to a
    /// container identifier File Provider has never heard of and the replica loses them. It is
    /// remembered across launches because a restart must not put the folder's contents back to zero.
    struct RootFolder: Codable, Equatable {
        var folderID: String
        var observedAt: Date
    }

    public func driveRootFolderID() -> String? {
        read(RootFolder.self, name: "drive-root.json")?.folderID
    }

    public func setDriveRootFolderID(_ folderID: String) throws {
        try write(RootFolder(folderID: folderID, observedAt: Date()), name: "drive-root.json")
    }

    // MARK: Extension liveness

    /// Written by the File Provider extension, read by the app: which appex the system really launched.
    ///
    /// The system keeps the extension bundle URL it was handed when the domain was registered, and
    /// neither `NSFileProviderManager` nor `NSFileProviderDomain` lets the app read it back. So after
    /// a rebuild or a move of the app, a domain can silently stay served by an appex from an older
    /// installation — or by another app copy that happens to share the bundle identifier. The
    /// extension records its own bundle path here so the app can compare it against itself.
    public struct ProviderHeartbeat: Codable, Equatable, Sendable {
        public var extensionBundlePath: String
        public var updatedAt: Date

        /// True when this heartbeat came from an extension living inside `appBundleURL`.
        public func isServedBy(appBundleURL: URL) -> Bool {
            let root = appBundleURL.standardizedFileURL.path
            let candidate = URL(fileURLWithPath: extensionBundlePath).standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    public func providerHeartbeat() -> ProviderHeartbeat? {
        read(ProviderHeartbeat.self, name: "provider-heartbeat.json")
    }

    /// Best effort by design: a heartbeat that fails to reach disk only costs the app one liveness
    /// check, it must never turn into a failed enumeration.
    public func recordProviderHeartbeat(extensionBundlePath: String) {
        try? write(ProviderHeartbeat(extensionBundlePath: extensionBundlePath, updatedAt: Date()),
                   name: "provider-heartbeat.json")
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

    // MARK: Access ledger

    /// The last time a copy of one object reached this Mac, per Drive id.
    ///
    /// This is what makes auto-eviction a decision instead of a guess: the inventory says what is on
    /// disk, only a record of use says whether anything still wants it. One small file per id, which is
    /// the activity log's arrangement and for the same reason — the app and the extension both write
    /// here, and one shared JSON would need a read-modify-write in which either process can lose the
    /// other's records. Per-item files make the last writer correct by construction.
    struct AccessRecord: Codable, Equatable {
        var accessedAt: Date
    }

    private var accessDirectory: URL {
        directory.appendingPathComponent("access", isDirectory: true)
    }

    /// A ledger file name for a Drive id, or nil when the id is not a plain token.
    ///
    /// The id comes from Drive, but it becomes a path component here, so it is checked rather than
    /// trusted: an id able to name a parent directory would let one record escape the shared container.
    static func ledgerFileName(forDriveID driveID: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !driveID.isEmpty, driveID.count <= 64,
              driveID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(driveID).json"
    }

    private func ledgerURL(forDriveID driveID: String) -> URL? {
        guard let name = Self.ledgerFileName(forDriveID: driveID) else { return nil }
        return accessDirectory.appendingPathComponent(name)
    }

    /// Records that an object's bytes arrived. Best effort by design: a ledger write that fails only
    /// costs this item one eviction pass, because an unknown last access is treated as still in use.
    public func noteAccess(_ driveID: String, at date: Date = Date()) {
        guard let url = ledgerURL(forDriveID: driveID) else { return }
        if let written = lastAccessWrite[driveID],
           date.timeIntervalSince(written) < accessCoalesceInterval { return }
        do {
            try FileManager.default.createDirectory(at: accessDirectory, withIntermediateDirectories: true)
            try write(AccessRecord(accessedAt: date), to: url)
            lastAccessWrite[driveID] = date
        } catch {
            // Nothing to report upward: the fetch that just succeeded is the user's news, not this.
        }
    }

    public func accessTime(forDriveID driveID: String) -> Date? {
        guard let url = ledgerURL(forDriveID: driveID) else { return nil }
        return read(AccessRecord.self, at: url)?.accessedAt
    }

    /// Every recorded access, skipping ids that are not valid ledger keys — a damaged or unforeseen
    /// name must not abort a sweep, it simply leaves that item protected as unknown.
    public func accessTimes() -> [String: Date] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: accessDirectory, includingPropertiesForKeys: nil)) ?? []
        var collected: [String: Date] = [:]
        for url in files where url.pathExtension == "json" {
            let driveID = url.deletingPathExtension().lastPathComponent
            guard Self.ledgerFileName(forDriveID: driveID) != nil,
                  let record = read(AccessRecord.self, at: url) else { continue }
            collected[driveID] = record.accessedAt
        }
        return collected
    }

    /// Drops one item's history once its copy is gone, so a later copy that arrives by some route this
    /// extension does not see — Finder's own "Keep downloaded", a reimport after a restore — is not
    /// judged idle by a timestamp from the previous one.
    public func forgetAccess(_ driveID: String) {
        guard let url = ledgerURL(forDriveID: driveID) else { return }
        try? FileManager.default.removeItem(at: url)
        lastAccessWrite[driveID] = nil
    }

    /// Forgets recorded ids that no longer have a copy on disk and have not been seen for a while, so
    /// the ledger cannot grow without bound as the account changes.
    ///
    /// Measured from each record's own date rather than the file's modification time, because a note
    /// written minutes ago about an access long past is exactly what this is looking to drop — and the
    /// clock of the machine that wrote it is not the fact being kept.
    public func pruneAccess(knownDriveIDs: Set<String>, olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: accessDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let driveID = url.deletingPathExtension().lastPathComponent
            guard !knownDriveIDs.contains(driveID) else { continue }
            guard let record = read(AccessRecord.self, at: url),
                  record.accessedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
            lastAccessWrite[driveID] = nil
        }
    }

    // MARK: Auto-eviction bookkeeping

    /// The last sweep, written by whichever process ran it.
    ///
    /// Kept on disk rather than in memory because the app and the extension each hold their own
    /// sweeper: without a shared stamp both would enumerate the materialized set every few minutes and
    /// double the work for the same bytes.
    struct EvictionRun: Codable, Equatable {
        var at: Date
    }

    public func lastAutoEvictionAt() -> Date? {
        read(EvictionRun.self, name: "auto-eviction.json")?.at
    }

    public func recordAutoEviction(at date: Date = Date()) {
        try? write(EvictionRun(at: date), name: "auto-eviction.json")
    }

    // MARK: Activity log

    /// One line of the user-facing activity log. It never carries tokens, URLs with credentials or
    /// response bodies — only what the user needs to understand what CloudDisk did.
    public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case download, upload, create, rename, move, copy, delete, synchronize, signOut, signIn
            case pin, unpin, other
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
