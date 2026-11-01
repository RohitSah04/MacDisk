import XCTest
import FileProvider
@testable import CloudDiskKit

/// Smart auto-eviction: the arithmetic that decides whether a copy can be handed back, the sweep that
/// acts on it, and the ledger that makes the decision knowable at all.
///
/// Freeing the wrong file is worse than freeing nothing, so most of what is here is written as a
/// protection test rather than a feature test: every case where CloudDisk cannot prove a copy is idle
/// has to end with the bytes still on disk. A scripted `CacheSystem` (from `CacheOfflineTests`) stands
/// in for `fileproviderd`; under test is CloudDisk's decision and its bookkeeping, never the system's
/// answer — which is why `docs/KNOWN_LIMITATIONS.md` still carries the live behaviour as unverified.
final class AutoEvictionPolicyTests: XCTestCase {

    private let last = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { last.addingTimeInterval(900) }

    private func facts(driveID: String? = "F1", folder: Bool = false, pinned: Bool = false,
                       allocated: Int64? = 4_096, declared: Int64? = 4_096,
                       accessedAt: Date? = nil, active: Bool = false,
                       locked: Bool = false) -> AutoEviction.Facts {
        AutoEviction.Facts(driveID: driveID, isFolder: folder, isPinned: pinned,
                           allocatedBytes: allocated, declaredBytes: declared,
                           lastAccessedAt: accessedAt, isActiveRead: active,
                           isLockedOnDisk: locked)
    }

    // MARK: The timeout itself

    func testTheDefaultInactivityTimeoutIsFifteenMinutes() {
        XCTAssertEqual(AutoEviction.Config.standard.inactivityTimeout, 900)
    }

    func testACopyBecomesEligibleOnlyOnceTheWholeTimeoutHasPassed() {
        let fresh = facts(accessedAt: last.addingTimeInterval(1))
        XCTAssertEqual(AutoEviction.decide(fresh, now: last.addingTimeInterval(900)),
                       .tooRecent(idleFor: 899, remaining: 1),
                       "one second short of the timeout is not idle")

        let exact = facts(accessedAt: last)
        XCTAssertEqual(AutoEviction.decide(exact, now: now), .evict,
                       "\"at least 900 seconds\" means the boundary is included")

        let stale = facts(accessedAt: last.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(AutoEviction.decide(stale, now: now), .evict)
    }

    func testTheRemainingTimeIsReportedSoTheNextPassCanBeScheduledInsteadOfPolled() {
        XCTAssertEqual(AutoEviction.secondsUntilEligible(lastAccessedAt: last, now: now,
                                                          timeout: 900), 0)
        XCTAssertEqual(AutoEviction.secondsUntilEligible(lastAccessedAt: last.addingTimeInterval(600),
                                                          now: now, timeout: 900), 600)
        XCTAssertNil(AutoEviction.secondsUntilEligible(lastAccessedAt: nil, now: now, timeout: 900),
                     "no history is not a wait, it is an unknown")
    }

    func testAConfiguredTimeoutMovesTheBoundary() {
        var config = AutoEviction.Config.standard
        config.inactivityTimeout = 60
        XCTAssertEqual(AutoEviction.decide(facts(accessedAt: last.addingTimeInterval(120)),
                                           now: now, config: config), .evict)
        XCTAssertEqual(AutoEviction.decide(facts(accessedAt: last.addingTimeInterval(120)),
                                           now: now, config: .standard),
                       .tooRecent(idleFor: 780, remaining: 120))
    }

    // MARK: The protections, each of which outranks the clock

    func testAPinnedFileIsNeverEligibleHoweverLongItHasSat() {
        let pinned = facts(pinned: true, accessedAt: last.addingTimeInterval(-40 * 3600))
        XCTAssertEqual(AutoEviction.decide(pinned, now: now), .pinned,
                       "an explicit offline request is not something an idle timer may overrule")
    }

    func testACopyThisProcessIsStillTransferringIsKept() {
        XCTAssertEqual(AutoEviction.decide(facts(accessedAt: last, active: true), now: now),
                       .activeRead)
    }

    func testACopyMarkedImmutableOnDiskIsKept() {
        XCTAssertEqual(AutoEviction.decide(facts(accessedAt: last, locked: true), now: now),
                       .lockedOnDisk,
                       "a lock CloudDisk did not set is a decision it must not reverse")
    }

    func testAPartiallyMaterializedCopyIsKept() {
        // Bytes still arriving, or a player holding one window of a large object.
        XCTAssertEqual(AutoEviction.decide(facts(allocated: 65_536, declared: 1_048_576,
                                                 accessedAt: last), now: now),
                       .partiallyMaterialized)
    }

    func testAGoogleNativeDocumentWithNoDeclaredSizeIsNotCalledPartial() {
        // Drive reports no size for a Workspace document because it has no downloadable content, so a
        // missing length cannot be read as "the rest is still to come".
        XCTAssertEqual(AutoEviction.decide(facts(allocated: 4_096, declared: nil,
                                                 accessedAt: last), now: now), .evict)
    }

    func testACopyWithNoRecordedAccessIsKeptRatherThanGuessedAt() {
        XCTAssertEqual(AutoEviction.decide(facts(accessedAt: nil), now: now), .lastAccessUnknown,
                       "CloudDisk never saw these bytes land, so it cannot claim nobody wants them")
    }

    func testACopyThatCannotBeMeasuredIsKept() {
        XCTAssertEqual(AutoEviction.decide(facts(allocated: nil, accessedAt: last), now: now),
                       .unmeasurable)
        XCTAssertEqual(AutoEviction.decide(facts(allocated: 0, accessedAt: last), now: now),
                       .unmeasurable, "nothing allocated means a pass would free nothing")
    }

    func testFoldersAndUnaddressableRowsAreNeverOffered() {
        XCTAssertEqual(AutoEviction.decide(facts(folder: true, accessedAt: last), now: now), .folder)
        XCTAssertEqual(AutoEviction.decide(facts(driveID: nil, accessedAt: last), now: now), .unnamed)
    }

    func testProtectionsAreDecidedBeforeTheClockIsRead() {
        // A pinned, half-downloaded, unreadable file whose timer expired: the reasons that keep it are
        // checked in order, and the answer must name a protection, not the timeout.
        let everything = facts(pinned: true, allocated: nil, accessedAt: last, active: true)
        XCTAssertEqual(AutoEviction.decide(everything, now: now), .pinned)
        let inFlight = facts(allocated: nil, accessedAt: last, active: true)
        XCTAssertEqual(AutoEviction.decide(inFlight, now: now), .activeRead)
    }
}

/// The ledger, which is the only thing that turns eviction from a guess into a decision.
final class AccessLedgerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func state(coalesce: TimeInterval = 0) -> ProviderState {
        ProviderState(directory: directory, accessCoalesceInterval: coalesce)
    }

    func testTheLedgerSurvivesAFreshProcess() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let original = state()
        await original.noteAccess("FILE0000000000000000000000000001", at: when)

        // A new actor over the same directory is what an extension relaunch is: nothing is remembered
        // in memory, so the ledger has to be on disk.
        let relaunched = state()
        let storedValue = await relaunched.accessTime(
            forDriveID: "FILE0000000000000000000000000001")
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored, when)
        let all = await relaunched.accessTimes()
        XCTAssertEqual(all.count, 1)
    }

    func testNotesInsideTheCoalesceWindowCostOneDiskWrite() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = state(coalesce: 60)
        await ledger.noteAccess("F1", at: start)
        await ledger.noteAccess("F1", at: start.addingTimeInterval(30))

        let folded = await ledger.accessTime(forDriveID: "F1")
        XCTAssertEqual(folded, start, "the second note of a burst is folded into the first")

        await ledger.noteAccess("F1", at: start.addingTimeInterval(90))
        let advanced = await ledger.accessTime(forDriveID: "F1")
        XCTAssertEqual(advanced, start.addingTimeInterval(90),
                       "past the window a newer access is recorded again")
    }

    func testAnIdThatCouldNameAnotherDirectoryIsNotWrittenAnywhere() async throws {
        let ledger = state()
        for hostile in ["../../escape", "a/b", "", String(repeating: "x", count: 65), "spaced id"] {
            await ledger.noteAccess(hostile, at: Date(timeIntervalSince1970: 1))
            let readBack = await ledger.accessTime(forDriveID: hostile)
            XCTAssertNil(readBack)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "escape.json" },
                       "a ledger key must never resolve outside the shared container")
    }

    func testDroppingACopyDropsItsHistory() async throws {
        let ledger = state()
        await ledger.noteAccess("F1", at: Date(timeIntervalSince1970: 1_700_000_000))
        await ledger.forgetAccess("F1")
        let after = await ledger.accessTime(forDriveID: "F1")
        XCTAssertNil(after,
                    "a later copy arriving by some route this extension does not see must not be "
                  + "judged idle by the previous copy's timestamp")
    }

    func testPruningDropsOnlyRecordsWithNoCopyAndNoRecentUse() async throws {
        let ledger = state()
        let old = Date(timeIntervalSince1970: 1_000_000)
        await ledger.noteAccess("GONE", at: old)
        await ledger.noteAccess("PRESENT", at: old)

        await ledger.pruneAccess(knownDriveIDs: ["PRESENT"],
                                olderThan: Date(timeIntervalSince1970: 2_000_000))
        let gone = await ledger.accessTime(forDriveID: "GONE")
        let present = await ledger.accessTime(forDriveID: "PRESENT")
        XCTAssertNil(gone)
        XCTAssertNotNil(present,
                        "an item still on disk keeps its history however old the record is")
    }

    func testACorruptLedgerRecordReadsAsNoHistoryRatherThanFailingTheSweep() async throws {
        let ledger = state()
        await ledger.noteAccess("F1", at: Date())
        let accessDirectory = directory.appendingPathComponent("access", isDirectory: true)
        try "not json".data(using: .utf8)?
            .write(to: accessDirectory.appendingPathComponent("F2.json"))

        let all = await ledger.accessTimes()
        XCTAssertEqual(all.keys.sorted(), ["F1"], "one damaged record must not cost the whole ledger")
    }
}

/// The sweep: real files on real disk, a scripted system, and the calls CloudDisk is allowed to make.
final class AutoEvictionSweepTests: XCTestCase {

    private var stateDirectory: URL!
    private var scratch: URL!
    private var state: ProviderState!
    private var cache: ScriptedCacheSystem!
    private var store: OfflineStore!

    private let idle = Date(timeIntervalSince1970: 1_600_000_000)
    private var now: Date { idle.addingTimeInterval(3600) }

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-sweep-state-\(UUID().uuidString)", isDirectory: true)
        scratch = DriveTestEnvironment.scratchDirectory()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        state = ProviderState(directory: stateDirectory, accessCoalesceInterval: 0)
        cache = ScriptedCacheSystem()
        store = OfflineStore(state: state, cacheSystem: cache)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    private func row(_ driveID: String, named name: String, folder: Bool = false,
                     declared: Int64?) -> MaterializedEntry {
        MaterializedEntry(identifier: ProviderIdentity.identifier(forDriveID: driveID),
                          name: name, driveID: driveID, isFolder: folder, declaredBytes: declared)
    }

    /// A file of `bytes` on disk, pointed at the way the system points at a materialized item.
    @discardableResult
    private func copy(_ driveID: String, named name: String, bytes: Int = 4_096) throws -> URL {
        let url = DriveTestEnvironment.writeFile(DriveTestEnvironment.deterministicBytes(bytes),
                                                 named: name, in: scratch)
        cache.point(ProviderIdentity.identifier(forDriveID: driveID), at: url)
        return url
    }

    private func labels(_ kept: [AutoEviction.Decision: Int]) -> Set<String> {
        Set(kept.keys.map(\.label))
    }

    // MARK: One pass, ordinary disk

    func testASweepEvictsTheIdleCopyAndLeavesEveryOtherCopyAlone() async throws {
        try copy("IDLE", named: "idle.txt", bytes: 4_096)
        try copy("FRESH", named: "fresh.txt")
        try copy("PINNED", named: "pinned.txt")
        cache.load([row("IDLE", named: "idle.txt", declared: 4_096),
                    row("FRESH", named: "fresh.txt", declared: 4_096),
                    row("PINNED", named: "pinned.txt", declared: 4_096)])
        await state.noteAccess("IDLE", at: idle)
        await state.noteAccess("FRESH", at: now.addingTimeInterval(-60))
        await state.noteAccess("PINNED", at: idle)
        try await state.setPinned("PINNED", true)

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(cache.evictedIdentifiers,
                       [ProviderIdentity.identifier(forDriveID: "IDLE").rawValue],
                       "only the provably idle copy is offered")
        XCTAssertEqual(sweep.report.released.count, 1)
        XCTAssertEqual(sweep.kept[.pinned], 1)
        XCTAssertEqual(labels(sweep.kept), ["tooRecent", "pinned"])
    }

    func testTheSweepReachesNoGoogleAPIAndNeverDeletesTheOriginal() async throws {
        try copy("IDLE", named: "idle.txt")
        cache.load([row("IDLE", named: "idle.txt", declared: 4_096)])
        await state.noteAccess("IDLE", at: idle)

        _ = try await store.sweepForInactivity(now: now)

        // `evict` is the only mutating call `CacheSystem` has, and `OfflineStore` holds no DriveService
        // at all: the object on Drive is out of reach from here by construction, and the recorded calls
        // say so.
        XCTAssertEqual(cache.evictedIdentifiers.count, 1)
        XCTAssertTrue(cache.downloadIdentifiers.isEmpty, "an eviction pass must not download anything")
        XCTAssertTrue(cache.signalIdentifiers.isEmpty, "the row did not change, so no container is upset")
    }

    func testAFreedCopyLosesItsLedgerEntryAndTheActivityLogSaysSo() async throws {
        try copy("IDLE", named: "idle.txt")
        cache.load([row("IDLE", named: "idle.txt", declared: 4_096)])
        await state.noteAccess("IDLE", at: idle)

        _ = try await store.sweepForInactivity(now: now)

        let cleared = await state.accessTime(forDriveID: "IDLE")
        XCTAssertNil(cleared)
        let events = await state.recentActivity()
        let event = try XCTUnwrap(events.first { $0.kind == .synchronize })
        XCTAssertEqual(event.subject, "Local cache")
        XCTAssertTrue(event.detail?.contains("idle") == true, "got \(event.detail ?? "nil")")
    }

    func testAPassThatFreesNothingWritesNoActivityLine() async throws {
        try copy("FRESH", named: "fresh.txt")
        cache.load([row("FRESH", named: "fresh.txt", declared: 4_096)])
        await state.noteAccess("FRESH", at: now)

        _ = try await store.sweepForInactivity(now: now)

        let activity = await state.recentActivity()
        XCTAssertTrue(activity.isEmpty,
                      "a sweep every few minutes must not become a wall of noise in the user's log")
    }

    // MARK: Refusals and failures

    func testARefusedEvictionIsKeptAndKeepsItsHistoryForTheNextPass() async throws {
        try copy("IDLE", named: "playing.mp4")
        cache.load([row("IDLE", named: "playing.mp4", declared: 4_096)])
        await state.noteAccess("IDLE", at: idle)
        cache.refuseEviction(ProviderIdentity.identifier(forDriveID: "IDLE"),
                             with: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)))

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(sweep.report.keptCount(.inUse), 1)
        XCTAssertTrue(sweep.report.released.isEmpty)
        let history = await state.accessTime(forDriveID: "IDLE")
        XCTAssertEqual(history, idle,
                       "a copy that is still there must not become unmeasurable history")
    }

    func testOneFailingCopyDoesNotStopThePass() async throws {
        try copy("BAD", named: "bad.txt")
        try copy("GOOD", named: "good.txt")
        cache.load([row("BAD", named: "bad.txt", declared: 4_096),
                    row("GOOD", named: "good.txt", declared: 4_096)])
        await state.noteAccess("BAD", at: idle)
        await state.noteAccess("GOOD", at: idle)
        cache.refuseEviction(ProviderIdentity.identifier(forDriveID: "BAD"),
                             with: NSError(domain: NSCocoaErrorDomain, code: 42))

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(sweep.report.failures.count, 1)
        XCTAssertEqual(cache.evictedIdentifiers.count, 2, "both were offered; one of them failed")
        XCTAssertEqual(sweep.report.released.map(\.name), ["good.txt"])
        let events = await state.recentActivity()
        let event = try XCTUnwrap(events.first { $0.kind == .synchronize })
        XCTAssertEqual(event.outcome, .failure)
    }

    func testAnItemTheSystemCannotNameAPathForIsCountedNotGuessed() async throws {
        cache.load([row("MISSING", named: "vanished.txt", declared: 4_096)])
        cache.point(ProviderIdentity.identifier(forDriveID: "MISSING"),
                    at: scratch.appendingPathComponent("not-there.txt"))
        await state.noteAccess("MISSING", at: idle)

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(sweep.kept[.unmeasurable], 1)
        XCTAssertTrue(cache.evictedIdentifiers.isEmpty)
    }

    func testACopyLockedOnRealDiskIsNotOffered() async throws {
        let url = try copy("LOCKED", named: "locked.txt")
        guard chflags(url.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw XCTSkip("cannot set the immutable flag on this volume")
        }
        defer { chflags(url.path, 0) }
        XCTAssertTrue(OfflineStore.isLocked(url), "the flag is what the rule reads")

        cache.load([row("LOCKED", named: "locked.txt", declared: 4_096)])
        await state.noteAccess("LOCKED", at: idle)

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(sweep.kept[.lockedOnDisk], 1)
        XCTAssertTrue(cache.evictedIdentifiers.isEmpty)
    }

    func testTheNextPassIsScheduledForTheEarliestDeadlineThePassProduced() async throws {
        try copy("SOON", named: "soon.txt")
        try copy("LATER", named: "later.txt")
        cache.load([row("SOON", named: "soon.txt", declared: 4_096),
                    row("LATER", named: "later.txt", declared: 4_096)])
        await state.noteAccess("SOON", at: now.addingTimeInterval(-800))
        await state.noteAccess("LATER", at: now.addingTimeInterval(-100))

        let sweep = try await store.sweepForInactivity(now: now)

        XCTAssertEqual(sweep.nextEligibleAt, now.addingTimeInterval(100),
                       "waiting for one timer beats polling, and the sooner copy decides it")
    }
}

/// Scheduling: one pass at a time, throttled across processes, quiet when asked to be.
final class AutoEvictionSweeperTests: XCTestCase {

    private var stateDirectory: URL!
    private var scratch: URL!
    private var state: ProviderState!
    private var cache: ScriptedCacheSystem!
    private var store: OfflineStore!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-sweeper-state-\(UUID().uuidString)", isDirectory: true)
        scratch = DriveTestEnvironment.scratchDirectory()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        state = ProviderState(directory: stateDirectory, accessCoalesceInterval: 0)
        cache = ScriptedCacheSystem()
        store = OfflineStore(state: state, cacheSystem: cache)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func config(timeout: TimeInterval = 900, minimum: TimeInterval = 0)
        -> AutoEviction.Config {
        AutoEviction.Config(inactivityTimeout: timeout, minimumSweepInterval: minimum,
                            firstSweepDelay: 0, settleDelay: 0, ledgerRetention: 7 * 24 * 3600)
    }

    private func sweeper(lowPower: @escaping @Sendable () -> Bool = { false },
                         active: @escaping @Sendable () -> Set<String> = { [] },
                         config: AutoEviction.Config? = nil) -> AutoEvictionSweeper {
        AutoEvictionSweeper(store: store, state: state, config: config ?? self.config(),
                            activeReads: active, lowPower: lowPower)
    }

    /// One copy on disk with a recorded access, addressed the way the system addresses a materialized
    /// item. Awaited rather than fire-and-forget: a pass that races the ledger write proves nothing.
    private func loadCopy(accessedAt: Date) async throws {
        let url = DriveTestEnvironment.writeFile(DriveTestEnvironment.deterministicBytes(4_096),
                                                 named: "idle.txt", in: scratch)
        let identifier = ProviderIdentity.identifier(forDriveID: "IDLE")
        cache.point(identifier, at: url)
        cache.load([MaterializedEntry(identifier: identifier, name: "idle.txt", driveID: "IDLE",
                                      isFolder: false, declaredBytes: 4_096)])
        await state.noteAccess("IDLE", at: accessedAt)
    }

    private func loadIdleCopy() async throws {
        try await loadCopy(accessedAt: Date(timeIntervalSince1970: 1))
    }

    func testTwoRequestsInQuickSuccessionRunOnePass() async throws {
        try await loadIdleCopy()
        let sweeper = sweeper()

        await sweeper.schedule(after: 0.05, reason: "first")
        await sweeper.schedule(after: 0.05, reason: "second")
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(cache.materializedEntryCalls, 1,
                       "a streamed file settles hundreds of times a minute; it must not sweep that often")
    }

    func testASecondPassInsideTheThrottleIsSkipped() async throws {
        try await loadIdleCopy()
        let sweeper = sweeper(config: config(minimum: 3_600))

        let first = await sweeper.runNow(reason: "first")
        let second = await sweeper.runNow(reason: "second")

        XCTAssertNotNil(first)
        XCTAssertNil(second, "the app and the extension share one throttle, not two")
        XCTAssertEqual(cache.materializedEntryCalls, 1)
        let stamp = await state.lastAutoEvictionAt()
        XCTAssertNotNil(stamp)
    }

    /// A pass that frees nothing still leaves one timer behind: the copy's own deadline. This is the
    /// whole shape of the feature — wait for the moment a file goes idle instead of asking repeatedly.
    func testADeadlineArmsThePassThatFreesTheCopyOnceItGoesIdle() async throws {
        try await loadCopy(accessedAt: Date().addingTimeInterval(-899))
        let sweeper = sweeper(config: config(timeout: 900, minimum: 0))

        let first = await sweeper.runNow(reason: "test")
        let kept = try XCTUnwrap(first)
        XCTAssertTrue(cache.evictedIdentifiers.isEmpty, "one second short of idle is not idle")
        XCTAssertEqual(Set(kept.kept.keys.map(\.label)), ["tooRecent"],
                       "the reason is recorded, not swallowed")
        XCTAssertEqual(kept.kept.values.reduce(0, +), 1)

        try await Task.sleep(nanoseconds: 1_800_000_000)

        XCTAssertEqual(cache.evictedIdentifiers.count, 1,
                       "the pass the deadline armed freed it, with nothing else asking for one")
        XCTAssertEqual(cache.materializedEntryCalls, 2)
    }

    func testLowPowerModeLeavesTheDiskAlone() async throws {
        try await loadIdleCopy()

        let skipped = await sweeper(lowPower: { true }).runNow(reason: "test")

        XCTAssertNil(skipped)
        XCTAssertEqual(cache.materializedEntryCalls, 0, "not even the read should happen")
    }

    func testAnActiveTransferInThisProcessSurvivesThePass() async throws {
        try await loadIdleCopy()

        _ = await sweeper(active: { ["IDLE"] }).runNow(reason: "test")

        XCTAssertTrue(cache.evictedIdentifiers.isEmpty,
                      "the bytes are arriving right now")
    }

    func testAFailedInventoryLeavesTheThrottleUntouched() async throws {
        cache.failInventory(CacheSystemError.unavailable("no domain"))

        let result = await sweeper().runNow(reason: "test")

        XCTAssertNil(result)
        let stamp = await state.lastAutoEvictionAt()
        XCTAssertNil(stamp, "a pass that never ran must not delay the next one")
    }

    func testTheRegistryUncoversAnItemOnlyWhenItsLastReadEnds() {
        let reads = ActiveReadRegistry()
        reads.begin("F1")
        reads.begin("F1")
        reads.end("F1")
        XCTAssertTrue(reads.isActive("F1"), "a second read of the same object is still a read")
        XCTAssertEqual(reads.snapshot(), ["F1"])
        reads.end("F1")
        XCTAssertFalse(reads.isActive("F1"))
        XCTAssertTrue(reads.snapshot().isEmpty)
    }
}

/// The wiring: a download through the real provider path has to leave a timestamp behind, because a
/// ledger nothing writes to is a ledger that keeps everything forever.
final class AutoEvictionFetchTests: XCTestCase {

    private static let fileID = "file0000000000000000000000000001"
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-fetch-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func remoteFile(size: Int) -> [String: Any] {
        DriveJSON.file(id: Self.fileID, name: "clip.mp4", mimeType: "video/mp4",
                       size: Int64(size), version: "rev-1", parents: ["fold00000000000000000000000000001"],
                       modifiedTime: "2026-10-29T10:00:00Z")
    }

    private struct Wiring {
        let services: ProviderServices
        let core: CloudDiskProviderCore
        let state: ProviderState
        let transport: StubTransport
    }

    private func wiring(_ script: [StubTransport.Reply]) -> Wiring {
        let transport = StubTransport(script: script)
        let env = DriveTestEnvironment.make(transport: transport)
        let state = ProviderState(directory: stateDirectory, accessCoalesceInterval: 0)
        let services = ProviderServices(config: env.config, drive: env.service, state: state)
        return Wiring(services: services, core: CloudDiskProviderCore(services: services),
                      state: state, transport: transport)
    }

    func testAWholeDownloadRecordsItsAccessInTheSharedLedger() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(4_096)
        let wired = wiring([
            .json(remoteFile(size: payload.count)),
            StubTransport.Reply(statusCode: 200,
                                headers: ["Content-Type": "application/octet-stream"],
                                body: payload)
        ])

        let content = try await wired.core.fetchContents(
            for: ProviderIdentity.identifier(forDriveID: Self.fileID),
            requestedVersion: nil, progress: Progress(totalUnitCount: 100))
        defer { try? FileManager.default.removeItem(at: content.url) }

        let notedValue = await wired.state.accessTime(forDriveID: Self.fileID)
        let noted = try XCTUnwrap(notedValue)
        XCTAssertLessThan(abs(noted.timeIntervalSinceNow), 120,
                          "the copy is fresh, so a sweep must not touch it for fifteen minutes")
        XCTAssertFalse(wired.services.activeReads.isActive(Self.fileID),
                       "the transfer ended, so the protection ends with it")
    }

    func testAnExtentDownloadRecordsItsAccessToo() async throws {
        let total = 1_048_576
        let window = DriveTestEnvironment.deterministicBytes(65_536)
        let wired = wiring([
            .json(remoteFile(size: total)),
            StubTransport.Reply(statusCode: 206,
                                headers: ["Content-Type": "application/octet-stream",
                                          "Content-Range": "bytes 0-\(window.count - 1)/\(total)"],
                                body: window)
        ])

        let extent = try await wired.core.fetchPartialContents(
            for: ProviderIdentity.identifier(forDriveID: Self.fileID),
            requestedVersion: nil, minimalRange: NSRange(location: 0, length: 4_096),
            aligningTo: 4_096, strictVersioning: false, progress: Progress(totalUnitCount: 100))
        defer { try? FileManager.default.removeItem(at: extent.url) }

        let extentRecord = await wired.state.accessTime(forDriveID: Self.fileID)
        XCTAssertNotNil(extentRecord,
                        "a player reading one window is using the file, and that is what keeps it")
        XCTAssertFalse(wired.services.activeReads.isActive(Self.fileID))
    }

    func testAFailedDownloadRecordsNoAccess() async throws {
        let wired = wiring([
            .json(remoteFile(size: 4_096)),
            StubTransport.Reply(statusCode: 500, headers: [:], body: Data())
        ])

        do {
            _ = try await wired.core.fetchContents(
                for: ProviderIdentity.identifier(forDriveID: Self.fileID),
                requestedVersion: nil, progress: Progress(totalUnitCount: 100))
            XCTFail("the scripted server error should surface")
        } catch {
            let after = await wired.state.accessTime(forDriveID: Self.fileID)
            XCTAssertNil(after, "nothing arrived, so nothing was used")
            XCTAssertFalse(wired.services.activeReads.isActive(Self.fileID),
                           "a failed transfer must not protect itself forever")
        }
    }
}
