import CloudDiskKit
import FileProvider
import Foundation
import XCTest

/// What a domain has to survive: an app that quits, is rebuilt, and starts again.
///
/// This is the claim the status screen makes in words — "Finder location: registered, serving this
/// build" — turned into an assertion. It is read-only: it never registers, repairs or removes a domain,
/// because a test that repairs what it is checking would pass for the wrong reason.
///
/// The machine-reboot half of the claim cannot be tested from here. Nothing in a test run can restart
/// macOS, so persistence across a reboot stays a manual observation.
final class DomainPersistenceTests: XCTestCase {

    private func cloudDiskDomain() async throws -> NSFileProviderDomain {
        let domains = await CloudDiskDomain.registered()
        guard let domain = domains.first(where: {
            $0.identifier.rawValue == CloudDiskConfig.domainIdentifierValue
        }) else {
            throw XCTSkip("""
            No \(CloudDiskConfig.domainIdentifierValue) domain is registered for this user, so \
            nothing has survived anything yet. Launch CloudDisk.app once to register it.
            """)
        }
        return domain
    }

    func testTheDomainStillCarriesTheIdentityTheCodeAsksFor() async throws {
        let domain = try await cloudDiskDomain()
        XCTAssertEqual(domain.displayName, CloudDiskConfig.displayName,
                       "the registered location is named something else, so the display name changed "
                       + "without the domain identifier and Finder is showing a stale label")
        XCTAssertTrue(domain.supportsSyncingTrash,
                      "the system-side trash flag is off, so a Drive trashed file would vanish from "
                      + "Finder instead of appearing in its Trash")
    }

    /// A second domain with the same display name is what a renamed identifier leaves behind: the old
    /// one keeps its appex registration and Finder shows two CloudDisks.
    func testThereIsOnlyOneCloudDiskDomain() async throws {
        _ = try await cloudDiskDomain()
        let domains = await CloudDiskDomain.registered()
        let byName = domains.filter { $0.displayName == CloudDiskConfig.displayName }
        XCTAssertEqual(byName.count, 1, "Finder has \(byName.count) locations named "
                       + "\(CloudDiskConfig.displayName); only one of them can be served by this build")
    }

    func testTheMountedLocationIsTheOneUnderLibraryCloudStorage() async throws {
        let domain = try await cloudDiskDomain()
        guard let url = await CloudDiskDomain.userVisibleURL(for: domain) else {
            throw XCTSkip("The domain is registered but the volume is not mounted in this session, "
                        + "so there is no path to check.")
        }
        // The test host is sandboxed, so `homeDirectoryForCurrentUser` is the app container; the
        // mount the user sees is under the *real* home, which only the password database knows.
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let expectedParent = realHome + "/Library/CloudStorage"
        XCTAssertTrue(url.path.hasPrefix(expectedParent + "/"),
                      "\(url.path) is outside \(expectedParent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the system names \(url.path) as the user-visible root and it is not there")
    }

    /// The check that catches the hazard this project actually hit: a domain left pointing at an older
    /// copy of the bundle, so the new extension never runs and Finder shows the old code's answers.
    func testTheExtensionThatAnsweredLivesInsideThisBuild() async throws {
        _ = try await cloudDiskDomain()
        let config = try CloudDiskConfig.current()
        let state = try await ProviderState.shared(config: config)
        guard let heartbeat = await state.providerHeartbeat() else {
            throw XCTSkip("No extension has answered an enumeration since the domain existed, so "
                        + "there is no bundle path to compare with this build.")
        }
        let thisBuild = Bundle.main.bundleURL.standardizedFileURL.path
        XCTAssertTrue(heartbeat.isServedBy(appBundleURL: Bundle.main.bundleURL),
                      "Finder is being served by \(heartbeat.extensionBundlePath), which is not "
                      + "inside \(thisBuild) — this copy of CloudDisk is not the one the location runs")
    }
}
