import AppKit
import CloudDiskKit
import Combine
import Foundation

/// The app process' copy of the service graph that the File Provider extension also builds.
///
/// Both processes construct `ProviderServices` from their own Info.plist, so the quota this window
/// shows, the errors it reports and the metadata the extension enumerates all come from one Drive
/// client and one credential — the app is not a mock of the provider.
@MainActor
final class AppCore: ObservableObject {

    enum Account: Equatable {
        case unknown
        case signedOut
        case busy
        case connected(email: String?, displayName: String?)
        case problem(String)
    }

    enum FinderLocation: Equatable {
        case unknown
        case registering
        /// Registered. A nil URL means the volume is not mounted under `~/Library/CloudStorage`
        /// yet, which is normal for a few seconds after registration and after waking the Mac.
        case registered(url: URL?)
        case absent
        case blocked(String)
    }

    enum CredentialStorage: Equatable {
        case unknown
        case usable
        case unusable(String)
    }

    /// Which File Provider extension the system is actually running for the Finder location.
    ///
    /// The app cannot ask `NSFileProviderManager` for the registered appex, so it nudges the domain to
    /// enumerate and waits for that extension to record its own bundle path. See
    /// `ProviderState.ProviderHeartbeat`.
    enum ExtensionStatus: Equatable {
        case unknown
        case checking
        /// The appex inside this app bundle answered. Finder and the app agree on which build is live.
        case live(at: Date)
        /// A different appex answered — an older installation still registered to this domain.
        case servedByOtherBuild(path: String)
        /// The domain is registered but no extension answered, so Finder would show an empty location.
        case notAnswering
        case unavailable(String)
    }

    enum Storage: Equatable {
        case unknown
        case loading
        case loaded(usedBytes: Int64?, limitBytes: Int64?, accountName: String?)
        case unavailable(String)
    }

    @Published private(set) var account: Account = .unknown
    @Published private(set) var location: FinderLocation = .unknown
    @Published private(set) var credentialStorage: CredentialStorage = .unknown
    @Published private(set) var extensionStatus: ExtensionStatus = .unknown
    @Published private(set) var storage: Storage = .unknown
    @Published private(set) var activity: [ProviderState.ActivityEvent] = []
    @Published private(set) var configurationProblem: String?

    let domain = CloudDiskDomain.make()
    private(set) var services: ProviderServices?
    private var config: CloudDiskConfig?

    var isConnected: Bool {
        if case .connected = account { return true }
        return false
    }

    // MARK: Startup

    /// Called once per launch. Each step stands on its own: a missing keychain group must not stop
    /// the Finder location from being registered, and an unregistered domain must not hide a
    /// credential that is already stored.
    func prepare() async {
        CloudDiskMigration.purgeLegacyTokenBridge()

        let config: CloudDiskConfig
        do {
            config = try CloudDiskConfig.current()
            configurationProblem = nil
        } catch {
            configurationProblem = error.localizedDescription
            account = .problem(error.localizedDescription)
            location = .absent
            credentialStorage = .unusable("Not checked: CloudDisk has no usable configuration.")
            extensionStatus = .unavailable("Not checked: CloudDisk has no usable configuration.")
            storage = .unavailable("Not checked: CloudDisk has no usable configuration.")
            return
        }
        self.config = config

        do {
            services = try ProviderServices.make(config: config, domain: domain)
        } catch {
            configurationProblem = error.localizedDescription
            credentialStorage = .unusable(error.localizedDescription)
            return
        }

        await readCredential()
        checkKeychain()
        await registerLocation()
        await refreshStorage()
        await refreshActivity()
        await verifyExtension()
    }

    // MARK: Account

    func signIn() async {
        guard let services else {
            account = .problem(configurationProblem ?? "CloudDisk is not configured.")
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            account = .problem("CloudDisk could not find its window to attach the Google sign-in "
                             + "sheet to. Click in the CloudDisk window and try again.")
            return
        }

        account = .busy
        do {
            let credential = try await GoogleSignInBridge.signIn(from: window)
            try await services.drive.tokens.save(credential)
            account = .connected(email: credential.accountEmail, displayName: credential.displayName)
            checkKeychain()
            await registerLocation()
            await verifyExtension()
            await refreshStorage()
            await refreshActivity()
        } catch {
            account = .problem(error.localizedDescription)
        }
    }

    /// Revokes the grant at Google, then clears the local copies. The local delete happens even if
    /// the revoke call fails: keeping a credential the user asked to remove would be the worse
    /// failure, and Drive drops the grant anyway when the account's app permissions are revoked.
    func signOut() async {
        account = .busy
        await services?.drive.tokens.signOut()
        GoogleSignInBridge.signOut()
        storage = .unknown
        activity = []
        account = .signedOut
    }

    private func readCredential() async {
        guard let services else {
            account = .signedOut
            return
        }
        do {
            if let credential = try await services.drive.tokens.storedCredential() {
                account = .connected(email: credential.accountEmail, displayName: credential.displayName)
            } else {
                account = .signedOut
            }
        } catch {
            // A store that cannot be read is reported by checkKeychain(), which probes the same item
            // with its own statuses; the account row stays "not connected" rather than guessing.
            account = .signedOut
        }
    }

    // MARK: Keychain sharing

    /// Writes and reads back a throwaway item in the shared access group. This is the only way to
    /// know that the app's and the extension's entitlements agree, and neither the compiler nor the
    /// build log can tell you before the extension really runs.
    private func checkKeychain() {
        guard let config else { return }
        let result = KeychainCredentialStore.current(config: config).probe()
        if result.isUsable {
            credentialStorage = .usable
        } else {
            credentialStorage = .unusable("""
            A test item could not be written to the shared keychain group (save: OSStatus \
            \(result.saveStatus), read: OSStatus \(result.readStatus), delete: OSStatus \
            \(result.deleteStatus)). The app and the File Provider extension must list the same \
            keychain access group in their entitlements.
            """)
        }
    }

    // MARK: Finder location

    private func registerLocation() async {
        location = .registering
        switch await CloudDiskDomain.register(domain) {
        case .registered:
            var mountedAt = await CloudDiskDomain.userVisibleURL(for: domain)
            if mountedAt == nil {
                // Mounting is asynchronous, so one short retry keeps a domain that is coming up from
                // being reported as absent.
                try? await Task.sleep(for: .milliseconds(600))
                mountedAt = await CloudDiskDomain.userVisibleURL(for: domain)
            }
            location = .registered(url: mountedAt)
        case .storageLocationOccupied:
            location = .blocked("""
            Finder already has a folder where CloudDisk wants to mount, but no CloudDisk domain is \
            registered, so that folder is left over from an earlier installation. Delete the \
            CloudDisk folder in ~/Library/CloudStorage, then register again.
            """)
        case .failed(let message):
            location = .blocked(message)
        }
    }

    func refreshLocation() async {
        await registerLocation()
        await verifyExtension()
    }

    /// Nudges the domain and waits for whichever extension answers to record its own bundle path, then
    /// compares that with this app. An answer from a different bundle, or no answer at all, means
    /// Finder is not being served by this build; re-registering the domain is what fixes it, and the
    /// repair runs at most once per launch so a slow Mac is not punished with a loop.
    private func verifyExtension() async {
        guard services != nil else { return }
        guard case .registered = location else {
            if case .blocked(let message) = location { extensionStatus = .unavailable(message) }
            return
        }
        extensionStatus = .checking
        if let heartbeat = await waitForHeartbeat(),
           heartbeat.isServedBy(appBundleURL: Bundle.main.bundleURL) {
            extensionStatus = .live(at: heartbeat.updatedAt)
            return
        }

        switch await CloudDiskDomain.repair(domain) {
        case .failed(let message):
            extensionStatus = .unavailable(message)
            return
        case .reregistered:
            break
        }
        switch await waitForHeartbeat(timeout: 20) {
        case .none:
            extensionStatus = .notAnswering
        case .some(let heartbeat) where heartbeat.isServedBy(appBundleURL: Bundle.main.bundleURL):
            extensionStatus = .live(at: heartbeat.updatedAt)
        case .some(let heartbeat):
            extensionStatus = .servedByOtherBuild(path: heartbeat.extensionBundlePath)
        }
        location = .registered(url: await CloudDiskDomain.userVisibleURL(for: domain))
    }

    /// Signals an enumeration and polls the shared state until an extension has written a heartbeat
    /// newer than the moment this check started.
    private func waitForHeartbeat(timeout: TimeInterval = 12) async -> ProviderState.ProviderHeartbeat? {
        guard let state = services?.state else { return nil }
        let notBefore = Date().addingTimeInterval(-2)
        _ = await CloudDiskDomain.signalResync(domain)
        var heartbeat = await state.providerHeartbeat()
        let deadline = Date().addingTimeInterval(timeout)
        while (heartbeat?.updatedAt ?? .distantPast) < notBefore, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            heartbeat = await state.providerHeartbeat()
        }
        return (heartbeat?.updatedAt ?? .distantPast) >= notBefore ? heartbeat : nil
    }

    func revealLocation() {
        guard case .registered(let url) = location, let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Drive facts

    func refreshStorage() async {
        guard let services else { return }
        guard isConnected else {
            storage = .unavailable("Connect a Google account to see Drive usage.")
            return
        }
        storage = .loading
        do {
            let about = try await services.drive.about()
            storage = .loaded(usedBytes: about.storageQuota?.usageInDriveBytes ?? about.storageQuota?.usageBytes,
                              limitBytes: about.storageQuota?.limitBytes,
                              accountName: about.user?.displayName)
        } catch {
            if let problem = AuthFailure.describe(error) { account = .problem(problem) }
            storage = .unavailable(error.localizedDescription)
        }
        await refreshActivity()
    }

    func refreshActivity() async {
        guard let state = services?.state else { activity = []; return }
        activity = await state.recentActivity(limit: 12)
    }
}

/// Turns the credential failures that CloudDiskKit raises into the one sentence the user can act on.
enum AuthFailure {
    static func describe(_ error: Error) -> String? {
        guard let driveError = error as? DriveError else { return nil }
        switch driveError {
        case .notAuthenticated(let revoked):
            return DriveError.notAuthenticated(revoked: revoked).localizedDescription
        default:
            return nil
        }
    }
}
