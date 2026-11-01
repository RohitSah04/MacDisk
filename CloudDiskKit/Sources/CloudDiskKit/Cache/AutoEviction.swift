import Foundation

/// Frees copies of Drive files that nobody has opened for a while.
///
/// A materialized object costs disk until something gives it back, and File Provider does not decide
/// that on its own: without help, the copy of a file the user glanced at once sits on their Mac
/// forever. Everything CloudDisk can free is a copy — the original is on Drive and stays there — so the
/// question this file answers is narrow and has to be answered conservatively: *can we prove nobody
/// still wants these bytes?* Where it cannot be proved, the copy is kept.
///
/// The two pieces are separate on purpose. `AutoEviction` is pure arithmetic over facts someone else
/// gathered, which is what makes every protection rule testable without a mounted domain;
/// `AutoEvictionSweeper` is the scheduling around it, and holds no policy of its own.
public enum AutoEviction {

    /// Tunables, with the defaults the product ships with.
    ///
    /// The timeout is a single knob rather than a literal in the decision path because it is the one
    /// number a user could reasonably want to change: fifteen minutes suits a laptop, the same rule
    /// reads as aggressive on a machine with a spinning disk and generous on one with 200 GB free.
    public struct Config: Equatable, Sendable {
        public var inactivityTimeout: TimeInterval
        /// Two processes each own a sweeper; this keeps them from both enumerating the materialized set.
        public var minimumSweepInterval: TimeInterval
        /// How long after the extension starts before the first pass runs, so a boot-time sweep does
        /// not compete with the mount coming up.
        public var firstSweepDelay: TimeInterval
        /// How long after a download settles before its pass runs, so one streamed file with dozens of
        /// extent reads costs a single sweep instead of one per range.
        public var settleDelay: TimeInterval
        /// How long an id with no copy on disk keeps its access record.
        public var ledgerRetention: TimeInterval

        public init(inactivityTimeout: TimeInterval, minimumSweepInterval: TimeInterval,
                    firstSweepDelay: TimeInterval, settleDelay: TimeInterval,
                    ledgerRetention: TimeInterval) {
            self.inactivityTimeout = inactivityTimeout
            self.minimumSweepInterval = minimumSweepInterval
            self.firstSweepDelay = firstSweepDelay
            self.settleDelay = settleDelay
            self.ledgerRetention = ledgerRetention
        }

        public static let standard = Config(inactivityTimeout: 900,
                                            minimumSweepInterval: 300,
                                            firstSweepDelay: 60,
                                            settleDelay: 30,
                                            ledgerRetention: 7 * 24 * 3600)

        /// The timeout an operator can set without a rebuild.
        ///
        /// Read from Info.plist the same way `CloudDiskConfig` reads its other keys, so both processes
        /// agree: an app-side timeout the extension cannot see would evict files the extension believes
        /// are still fresh. A missing, unexpanded or nonsensical value falls back to the default.
        public static let timeoutPlistKey = "CloudDiskAutoEvictionTimeoutSeconds"

        public static func current(bundle: Bundle = .main) -> Config {
            var config = Config.standard
            guard let raw = bundle.object(forInfoDictionaryKey: timeoutPlistKey),
                  let seconds = (raw as? NSNumber)?.doubleValue,
                  seconds > 0, seconds < 24 * 3600 else { return config }
            config.inactivityTimeout = seconds
            return config
        }
    }

    /// Everything known about one object on disk, as measured rather than as assumed.
    public struct Facts: Equatable, Sendable {
        public let driveID: String?
        public let isFolder: Bool
        public let isPinned: Bool
        /// Blocks actually allocated for this path. Nil means the path could not be measured.
        public let allocatedBytes: Int64?
        /// The length the item declares, which for a dataless file is the whole object.
        public let declaredBytes: Int64?
        /// When a copy last arrived, from the access ledger. Nil means CloudDisk never saw it land.
        public let lastAccessedAt: Date?
        /// Whether this process is transferring this object right now.
        public let isActiveRead: Bool
        /// The user-immutable flag, which is how a lock set outside CloudDisk shows up on the replica.
        public let isLockedOnDisk: Bool

        public init(driveID: String?, isFolder: Bool, isPinned: Bool, allocatedBytes: Int64?,
                    declaredBytes: Int64?, lastAccessedAt: Date?, isActiveRead: Bool,
                    isLockedOnDisk: Bool) {
            self.driveID = driveID
            self.isFolder = isFolder
            self.isPinned = isPinned
            self.allocatedBytes = allocatedBytes
            self.declaredBytes = declaredBytes
            self.lastAccessedAt = lastAccessedAt
            self.isActiveRead = isActiveRead
            self.isLockedOnDisk = isLockedOnDisk
        }
    }

    /// Why a copy will or will not be released this pass.
    public enum Decision: Equatable, Hashable, Sendable {
        case evict
        case pinned
        case folder
        case activeRead
        case lockedOnDisk
        case unmeasurable
        case partiallyMaterialized
        case lastAccessUnknown
        case tooRecent(idleFor: TimeInterval, remaining: TimeInterval)
        case unnamed

        /// The reason as one log word, so `log show` can count decisions per cause.
        public var label: String {
            switch self {
            case .evict: return "evict"
            case .pinned: return "pinned"
            case .folder: return "folder"
            case .activeRead: return "activeRead"
            case .lockedOnDisk: return "locked"
            case .unmeasurable: return "unmeasurable"
            case .partiallyMaterialized: return "partial"
            case .lastAccessUnknown: return "unknownAccess"
            case .tooRecent: return "tooRecent"
            case .unnamed: return "unnamed"
            }
        }

        /// The seconds before this object could be reconsidered, when that is a question of time.
        public var retryIn: TimeInterval? {
            if case .tooRecent(_, let remaining) = self { return remaining }
            return nil
        }
    }

    /// The rule, applied in one order.
    ///
    /// Order matters more than the branches: a pinned file that is also mid-download answers `pinned`,
    /// because that is the sentence the user needs, and anything unverifiable is decided before the
    /// arithmetic so an idle timer can never be the reason a live file is freed.
    public static func decide(_ facts: Facts, now: Date, config: Config = .standard) -> Decision {
        if facts.isFolder { return .folder }
        guard facts.driveID != nil else { return .unnamed }
        guard !facts.isPinned else { return .pinned }
        guard !facts.isActiveRead else { return .activeRead }
        guard !facts.isLockedOnDisk else { return .lockedOnDisk }
        // Nothing measured means nothing known to free: the row exists in the materialized set but the
        // path could not be read, so a pass would be guessing at both its size and its state.
        guard let allocated = facts.allocatedBytes, allocated > 0 else { return .unmeasurable }
        // Bytes are still arriving, or a player is holding a window of them. The declared size is the
        // whole object, so anything below it says the copy is incomplete — and no declared size at all
        // is a Google-native document, which has no downloadable content to be missing.
        if let declared = facts.declaredBytes, declared > allocated { return .partiallyMaterialized }
        guard let lastAccessedAt = facts.lastAccessedAt else { return .lastAccessUnknown }
        let idle = now.timeIntervalSince(lastAccessedAt)
        guard idle >= config.inactivityTimeout else {
            return .tooRecent(idleFor: idle, remaining: config.inactivityTimeout - idle)
        }
        return .evict
    }

    /// When this object becomes eligible, or nil when there is no clock to wait for.
    public static func secondsUntilEligible(lastAccessedAt: Date?, now: Date,
                                            timeout: TimeInterval) -> TimeInterval? {
        guard let lastAccessedAt else { return nil }
        return max(0, timeout - now.timeIntervalSince(lastAccessedAt))
    }

    /// What one pass did, and when the next one is worth running.
    public struct Sweep: Equatable, Sendable {
        public var report: EvictionReport
        /// Every object kept, by the rule that kept it.
        public var kept: [Decision: Int]
        /// The soonest any kept object could be eligible, which is how the sweeper waits for a deadline
        /// instead of polling.
        public var nextEligibleAt: Date?

        public init(report: EvictionReport, kept: [Decision: Int], nextEligibleAt: Date?) {
            self.report = report
            self.kept = kept
            self.nextEligibleAt = nextEligibleAt
        }
    }
}

/// The scheduling around one pass: coalesce requests, respect the shared throttle, stay quiet when the
/// machine is asking to be left alone.
///
/// Both processes build one of these, so the throttle lives in shared state rather than in memory —
/// see `AutoEvictionSweeper.run`.
public actor AutoEvictionSweeper {

    private let store: OfflineStore
    private let state: ProviderState
    public nonisolated let config: AutoEviction.Config
    /// The set of objects this process is transferring right now, read at the moment of decision rather
    /// than captured earlier, so a download that started during a sweep is still protected.
    private let activeReads: @Sendable () -> Set<String>
    private let lowPower: @Sendable () -> Bool
    private var pending: Task<Void, Never>?
    /// A pass is measuring the disk, so a second one starting before the first answers would walk the
    /// same items twice and could free one the first pass is in the middle of releasing.
    private var isSweeping = false

    public init(store: OfflineStore,
                state: ProviderState,
                config: AutoEviction.Config = .standard,
                activeReads: @escaping @Sendable () -> Set<String> = { [] },
                lowPower: @escaping @Sendable () -> Bool = {
                    ProcessInfo.processInfo.isLowPowerModeEnabled
                }) {
        self.store = store
        self.state = state
        self.config = config
        self.activeReads = activeReads
        self.lowPower = lowPower
    }

    /// Asks for a pass no sooner than `delay` from now.
    ///
    /// A request that arrives while one is already waiting is dropped rather than re-armed: the pending
    /// pass will run sooner than the new one would, and it re-reads the ledger when it runs, so the
    /// work asked for now is already covered. That is what keeps a streamed file — which settles a
    /// hundred times a minute — from turning into a hundred sweeps.
    public func schedule(after delay: TimeInterval, reason: String) {
        guard pending == nil else { return }
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            _ = await self?.run(reason: reason)
        }
    }

    public func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    @discardableResult
    public func runNow(reason: String) async -> AutoEviction.Sweep? { await run(reason: reason) }

    private func run(reason: String) async -> AutoEviction.Sweep? {
        // The waiting task is the pass now running, so its slot is cleared first: leaving it filled is
        // how a finished pass would go on blocking the very follow-up it meant to schedule.
        pending = nil
        let now = Date()

        guard !isSweeping else {
            ProviderLog.note("evict pass skipped reason=busy (\(reason))")
            return nil
        }
        guard !lowPower() else {
            // Nothing is re-armed here on purpose. A Mac asking to be left alone gets left alone: the
            // next download, or the next time the system launches this extension, brings another pass.
            ProviderLog.note("evict pass skipped reason=lowPower (\(reason))")
            return nil
        }
        if let last = await state.lastAutoEvictionAt(),
           now.timeIntervalSince(last) < config.minimumSweepInterval {
            // Either this process already swept, or the other one did seconds ago. Saying so is what
            // makes a "why is my cache full" question answerable from the log alone — and the pass that
            // stamped the throttle armed whatever deadline is still worth waiting for.
            let elapsed = now.timeIntervalSince(last)
            ProviderLog.note("evict pass skipped reason=throttled since=\(Int(elapsed))s (\(reason))")
            return nil
        }

        isSweeping = true
        let sweep: AutoEviction.Sweep
        do {
            sweep = try await store.sweepForInactivity(now: now, config: config,
                                                        activeReads: activeReads())
        } catch {
            isSweeping = false
            ProviderLog.failure("evict pass failed reason=\(reason) error=\(error)")
            // A pass that never ran records no throttle stamp, so the next attempt is not delayed by
            // this one; the inventory usually fails only because the domain is not mounted yet.
            return nil
        }
        isSweeping = false
        await state.recordAutoEviction(at: now)

        let nextInSeconds = sweep.nextEligibleAt.map { String(Int($0.timeIntervalSince(now))) } ?? "none"
        ProviderLog.note("evict pass done reason=\(reason) scanned=\(sweep.report.scanned) "
                         + "released=\(sweep.report.released.count) bytes=\(sweep.report.freedBytes) "
                         + "kept=\(Self.describe(kept: sweep.kept)) "
                         + "failed=\(sweep.report.failures.count) next=\(nextInSeconds)s")

        // The next pass is armed against the earliest deadline this one produced, so waiting for a file
        // to go idle costs one sleep instead of a poll. Nothing is armed when every copy was either
        // freed or refused for a reason no timer changes.
        if let next = sweep.nextEligibleAt {
            schedule(after: max(config.minimumSweepInterval, next.timeIntervalSince(now)),
                     reason: "deadline")
        }
        return sweep
    }

    private static func describe(kept: [AutoEviction.Decision: Int]) -> String {
        guard !kept.isEmpty else { return "none" }
        return kept.sorted { $0.key.label < $1.key.label }
            .map { "\($0.key.label):\($0.value)" }
            .joined(separator: ",")
    }
}

/// Which objects this process is transferring right now.
///
/// Counted rather than set because the same object can be in flight twice — the system re-asking for an
/// extent it timed out on, or a preview and a read overlapping — and the first of those to finish must
/// not uncover the second. This is the only in-use signal CloudDisk genuinely has: another app holding
/// the file open is invisible here, which is why eviction also listens for the system's `EBUSY`.
public final class ActiveReadRegistry: @unchecked Sendable {

    private let gate = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    public func begin(_ driveID: String) {
        gate.lock()
        counts[driveID, default: 0] += 1
        gate.unlock()
    }

    public func end(_ driveID: String) {
        gate.lock()
        if let remaining = counts[driveID], remaining > 1 { counts[driveID] = remaining - 1 }
        else { counts[driveID] = nil }
        gate.unlock()
    }

    public func isActive(_ driveID: String) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return counts[driveID] != nil
    }

    public func snapshot() -> Set<String> {
        gate.lock()
        defer { gate.unlock() }
        return Set(counts.keys)
    }
}
