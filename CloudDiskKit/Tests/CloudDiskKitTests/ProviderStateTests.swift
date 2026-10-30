import XCTest
import FileProvider
@testable import CloudDiskKit

/// Tests for the state the app and the File Provider extension share through the App Group container,
/// and for the error translation the extension hands to the system.
///
/// A unit test cannot create a real App Group container, so every case points `ProviderState` at a
/// temporary directory. What is under test is the file format, the cross-process visibility of those
/// files and the codes the system receives — not the container itself.
final class ProviderStateTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A second instance over the same directory stands in for the other process.
    private func reopened() -> ProviderState { ProviderState(directory: directory) }

    // MARK: Extension liveness

    func testHeartbeatWrittenByTheExtensionIsVisibleToTheApp() async throws {
        let path = "/Applications/CloudDisk.app/Contents/PlugIns/CloudDiskProvider.appex"
        await reopened().recordProviderHeartbeat(extensionBundlePath: path)

        let heartbeat = await reopened().providerHeartbeat()
        XCTAssertEqual(heartbeat?.extensionBundlePath, path)
        XCTAssertNotNil(heartbeat?.updatedAt)
    }

    func testHeartbeatRecognisesWhichAppBundleServesTheDomain() throws {
        let app = URL(fileURLWithPath: "/Applications/CloudDisk.app")
        let inside = ProviderState.ProviderHeartbeat(
            extensionBundlePath: "/Applications/CloudDisk.app/Contents/PlugIns/CloudDiskProvider.appex",
            updatedAt: .now)
        let outside = ProviderState.ProviderHeartbeat(
            extensionBundlePath: "/Users/someone/DerivedData/old.app/Contents/PlugIns/CloudDiskProvider.appex",
            updatedAt: .now)
        // A sibling folder whose path merely starts with the same characters is not inside the bundle.
        let lookalike = ProviderState.ProviderHeartbeat(
            extensionBundlePath: "/Applications/CloudDisk.appExtra/CloudDiskProvider.appex",
            updatedAt: .now)

        XCTAssertTrue(inside.isServedBy(appBundleURL: app))
        XCTAssertFalse(outside.isServedBy(appBundleURL: app))
        XCTAssertFalse(lookalike.isServedBy(appBundleURL: app))
    }

    func testCorruptStateFileReadsAsAbsentInsteadOfFailing() async throws {
        try Data("this is not json".utf8)
            .write(to: directory.appendingPathComponent("provider-heartbeat.json"))
        let unreadable = await reopened().providerHeartbeat()
        XCTAssertNil(unreadable)

        await reopened().recordProviderHeartbeat(
            extensionBundlePath: "/tmp/new.app/Contents/PlugIns/CloudDiskProvider.appex")
        let recovered = await reopened().providerHeartbeat()
        XCTAssertNotNil(recovered)
    }

    // MARK: Pins and sync cursor

    func testPinsWrittenByOneProcessAreVisibleToTheOther() async throws {
        let extensionSide = ProviderState(directory: directory)
        try await extensionSide.setPinned("1AbcDef", true)
        try await extensionSide.setPinned("2GhiJkl", true)
        try await extensionSide.setPinned("1AbcDef", false)

        let appSide = reopened()
        let pinned = await appSide.pinnedDriveIDs()
        let keptPinned = await appSide.isPinned("2GhiJkl")
        let unpinned = await appSide.isPinned("1AbcDef")

        XCTAssertEqual(pinned, ["2GhiJkl"])
        XCTAssertTrue(keptPinned)
        XCTAssertFalse(unpinned)
    }

    func testSyncCursorRoundTripAndReset() async throws {
        let state = ProviderState(directory: directory)
        let before = await state.syncCursor()
        XCTAssertNil(before)

        try await state.setSyncCursor("now:1793000000")
        let written = await reopened().syncCursor()
        XCTAssertEqual(written, "now:1793000000")

        try await reopened().clearSyncCursor()
        let cleared = await reopened().syncCursor()
        XCTAssertNil(cleared)
    }

    // MARK: Activity log

    func testActivityIsNewestFirstAndCapped() async throws {
        let state = ProviderState(directory: directory)
        for index in 0..<12 {
            try await state.record(.init(kind: .download, outcome: .success, subject: "file-\(index)",
                                         date: Date(timeIntervalSince1970: 1_000 + Double(index))))
        }
        let all = await reopened().recentActivity(limit: 100)
        XCTAssertEqual(all.count, 12)

        let recent = await reopened().recentActivity(limit: 5)
        XCTAssertEqual(recent.map(\.subject),
                       ["file-11", "file-10", "file-9", "file-8", "file-7"])
    }

    func testFailureDetailSurvivesTheRoundTrip() async throws {
        try await reopened().record(.init(kind: .upload, outcome: .failure, subject: "video.mp4",
                                         detail: "Drive refused the upload", date: .now))
        let events = await reopened().recentActivity(limit: 10)
        let first = events.first
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(first?.outcome, .failure)
        XCTAssertEqual(first?.detail, "Drive refused the upload")
    }

    func testClearingActivityLeavesOtherStateAlone() async throws {
        let state = ProviderState(directory: directory)
        try await state.record(.init(kind: .delete, outcome: .success, subject: "old.txt", date: .now))
        try await state.setPinned("1AbcDef", true)

        try await state.clearActivity()

        let pinned = await reopened().pinnedDriveIDs()
        let events = await reopened().recentActivity()
        XCTAssertEqual(pinned, ["1AbcDef"])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Legacy credential bridge

    func testLegacyTokenBridgeIsPurged() throws {
        let suiteName = "clouddisk-legacy-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("placeholder-not-a-token", forKey: "GoogleDriveAccessToken")
        defaults.set(1_793_000_000, forKey: "GoogleDriveAccessTokenExpiry")
        defaults.set("unrelated", forKey: "something-else")

        let removed = CloudDiskMigration.purgeLegacyTokenBridge(suite: defaults)
        let secondPass = CloudDiskMigration.purgeLegacyTokenBridge(suite: defaults)

        XCTAssertEqual(removed, 2)
        XCTAssertNil(defaults.object(forKey: "GoogleDriveAccessToken"))
        XCTAssertNil(defaults.object(forKey: "GoogleDriveAccessTokenExpiry"))
        XCTAssertEqual(defaults.string(forKey: "something-else"), "unrelated")
        XCTAssertEqual(secondPass, 0)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Error bridging

    func testAuthenticationFailureReachesTheSystemAsNotAuthenticated() {
        let bridged = ProviderErrorMapper.bridge(DriveError.notAuthenticated(revoked: true))
        XCTAssertEqual(bridged.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(bridged.code, NSFileProviderError.Code.notAuthenticated.rawValue)
    }

    func testMissingItemReachesTheSystemAsNoSuchItem() throws {
        let bridged = ProviderErrorMapper.bridge(DriveError.itemNotFound(id: "1AbcDef"))
        let identifier = try XCTUnwrap(
            bridged.userInfo[NSFileProviderErrorNonExistentItemIdentifierKey]
                as? NSFileProviderItemIdentifier)

        XCTAssertEqual(bridged.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(bridged.code, NSFileProviderError.Code.noSuchItem.rawValue)
        XCTAssertEqual(ProviderIdentity.driveID(for: identifier), "1AbcDef")
    }

    func testTransientFailuresAreReportedAsUnreachableNotPermanent() {
        let transient: [DriveError] = [
            .rateLimited(retryAfter: 1),
            .network(detail: "The Internet connection appears to be offline."),
            .serverTransient(statusCode: 503, detail: "backendError"),
        ]
        for error in transient {
            let bridged = ProviderErrorMapper.bridge(error)
            XCTAssertEqual(bridged.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(bridged.code, NSFileProviderError.Code.serverUnreachable.rawValue)
        }
    }

    func testExpiredCursorIsReportedAsNeedingAResync() {
        let bridged = ProviderErrorMapper.bridge(DriveError.syncCursorExpired)
        XCTAssertEqual(bridged.code, NSFileProviderError.Code.syncAnchorExpired.rawValue)
    }

    func testCancellationReachesTheSystemAsUserCancelled() {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let bridged = ProviderErrorMapper.bridge(error)
            XCTAssertEqual(bridged.domain, NSCocoaErrorDomain)
            XCTAssertEqual(bridged.code, CocoaError.Code.userCancelled.rawValue)
        }
    }

    func testUnrecognizableErrorIsWrappedRatherThanDropped() {
        struct Odd: Error {}
        let bridged = ProviderErrorMapper.bridge(Odd())
        XCTAssertEqual(bridged.domain, NSCocoaErrorDomain)
        XCTAssertEqual(bridged.code, CocoaError.Code.xpcConnectionReplyInvalid.rawValue)
        XCTAssertNotNil(bridged.userInfo[NSUnderlyingErrorKey])
    }

    // MARK: Cursors

    func testPageCursorRoundTrip() {
        let page = ProviderCursor.page(drivePageToken: "WMuuFWPkBdIE")
        XCTAssertEqual(ProviderCursor.drivePageToken(from: page), "WMuuFWPkBdIE")
    }

    func testReservedFirstPagesAreNotSentToDrive() {
        let byName = ProviderCursor.drivePageToken(from: NSFileProviderPage(ProviderCursor.initialSortedByName))
        let byDate = ProviderCursor.drivePageToken(from: NSFileProviderPage(ProviderCursor.initialSortedByDate))
        let empty = ProviderCursor.drivePageToken(from: NSFileProviderPage(Data()))
        XCTAssertNil(byName)
        XCTAssertNil(byDate)
        XCTAssertNil(empty)
    }

    func testAnchorCursorRoundTrip() {
        let anchor = ProviderCursor.anchor(driveStartToken: "now:1793000000")
        XCTAssertEqual(ProviderCursor.driveStartToken(from: anchor), "now:1793000000")
    }

    // MARK: Domain description

    func testDomainIdentityIsStableAndTrashAware() {
        let domain = CloudDiskDomain.make()
        XCTAssertEqual(domain.identifier.rawValue, "primary-google-drive")
        XCTAssertEqual(domain.displayName, "CloudDisk")
        XCTAssertTrue(domain.supportsSyncingTrash)
    }
}
