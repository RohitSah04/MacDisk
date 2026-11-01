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

    /// What CloudDisk's Finder location occupies on this Mac.
    ///
    /// The numbers come from File Provider's own materialized set and from the file system, not from a
    /// CloudDisk ledger — so `.loaded` with an empty inventory really does mean nothing is on disk.
    enum LocalCache: Equatable {
        case unknown
        case loading
        case loaded(CacheInventory)
        case unavailable(String)
    }

    @Published private(set) var account: Account = .unknown
    @Published private(set) var location: FinderLocation = .unknown
    @Published private(set) var credentialStorage: CredentialStorage = .unknown
    @Published private(set) var extensionStatus: ExtensionStatus = .unknown
    @Published private(set) var storage: Storage = .unknown
    @Published private(set) var localCache: LocalCache = .unknown
    /// The result of the last "clear cached files" run, kept until the next one so the button can say
    /// what the system refused rather than only that it finished.
    @Published private(set) var lastEviction: EvictionReport?
    @Published private(set) var activity: [ProviderState.ActivityEvent] = []
    @Published private(set) var configurationProblem: String?

    let domain = CloudDiskDomain.make()
    private(set) var services: ProviderServices?
    private var config: CloudDiskConfig?
    private let mappingUpgrade = MappingUpgrade()
    private var locationSyncWatch: Task<Void, Never>?

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
        let locationExistedBeforeLaunch = await CloudDiskDomain.isRegistered()
        await registerLocation()
        await applyMappingUpgrade(locationExistedBeforeLaunch: locationExistedBeforeLaunch)
        await refreshStorage()
        await refreshLocalCache()
        await refreshActivity()
        await verifyExtension()
        startLocationSyncWatch()
    }

    /// Brings a Finder location created by an older build up to this build's item mapping.
    ///
    /// Objects the system already materialized keep the dates and permissions of the item that created
    /// them, so a mapping fix needs a re-import to be visible; a location registered by this launch is
    /// already correct and only needs its version recorded.
    private func applyMappingUpgrade(locationExistedBeforeLaunch: Bool) async {
        guard mappingUpgrade.isNeeded() else { return }
        if locationExistedBeforeLaunch {
            await rebuildLocation()
            guard case .registered = location else { return }
        }
        mappingUpgrade.recordApplied()
    }

    // MARK: Keeping the mounted folder in step with Drive

    /// Tells File Provider that Drive has new metadata waiting, so the mounted folder follows a change
    /// that did not come through it.
    ///
    /// Nothing else asks for the changes feed. File Provider re-reads a container when a client looks
    /// at it or when its own schedule says so, and Drive's push channel needs a public callback server
    /// this app does not have, so without a nudge the folder keeps the names it imported and the user
    /// reads that as sync being broken. Found by renaming a file in CloudDisk's own browser: Drive
    /// answered with the new name, Finder still showed the old one, and nothing bridged the gap.
    func syncFinderLocation() async {
        guard isConnected else { return }
        _ = await CloudDiskDomain.signalResync(domain)
    }

    /// One nudge per wait, so a file edited on a phone or in the browser appears in Finder without the
    /// user reopening anything. Each pass costs the extension one `changes.list` call.
    private func startLocationSyncWatch() {
        locationSyncWatch?.cancel()
        locationSyncWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.locationSyncInterval)
                guard !Task.isCancelled else { return }
                await self?.syncFinderLocation()
            }
        }
    }

    private static let locationSyncInterval: Duration = .seconds(120)

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
            startLocationSyncWatch()
        } catch {
            account = .problem(error.localizedDescription)
        }
    }

    /// Revokes the grant at Google, then clears the local copies. The local delete happens even if
    /// the revoke call fails: keeping a credential the user asked to remove would be the worse
    /// failure, and Drive drops the grant anyway when the account's app permissions are revoked.
    func signOut() async {
        account = .busy
        locationSyncWatch?.cancel()
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
            await reportRegistered()
        case .storageLocationOccupied:
            location = .blocked("""
            Finder already has a folder where CloudDisk wants to mount, but no CloudDisk domain is \
            registered, so that folder is left over from an earlier installation. Delete the \
            CloudDisk folder in ~/Library/CloudStorage, then register again.
            """)
        case .failed(let message):
            // `addDomain` also refuses when a record exists for the identifier but the app copy that
            // created it is gone — which is what an update that moved or deleted the old bundle
            // leaves behind. Re-adding cannot fix that, so this is the one place repair is reached
            // from a location that does not report itself registered; without it "Register again"
            // could never succeed.
            switch await CloudDiskDomain.repair(domain) {
            case .reregistered:
                await reportRegistered()
            case .failed(let repairMessage):
                location = .blocked("\(message) \(repairMessage)")
            }
        }
    }

    /// Mounting is asynchronous, so one short retry keeps a domain that is coming up from being
    /// reported as absent.
    private func reportRegistered() async {
        var mountedAt = await CloudDiskDomain.userVisibleURL(for: domain)
        if mountedAt == nil {
            try? await Task.sleep(for: .milliseconds(600))
            mountedAt = await CloudDiskDomain.userVisibleURL(for: domain)
        }
        location = .registered(url: mountedAt)
    }

    func refreshLocation() async {
        await registerLocation()
        await verifyExtension()
    }

    /// Removes and re-creates the Finder location so File Provider materializes every item again.
    ///
    /// The system takes an object's permissions from the item at the moment it creates the folder and
    /// leaves them alone while that item's version is unchanged, so a folder created by an older
    /// CloudDisk keeps whatever mode that build published — including one Finder cannot list. Rebuilding
    /// is the only way to apply a corrected mapping to objects already on disk; the removal preserves
    /// everything the user had downloaded.
    func rebuildLocation() async {
        location = .registering
        switch await CloudDiskDomain.repair(domain) {
        case .reregistered:
            await reportRegistered()
        case .failed(let message):
            location = .blocked(message)
        }
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

    // MARK: Local cache

    /// Asks Finder what it is holding for CloudDisk and measures those paths. Needs no Drive access:
    /// a signed-out user can still see and free what the last session left on disk.
    func refreshLocalCache() async {
        guard let services else { return }
        localCache = .loading
        do {
            localCache = .loaded(try await services.offline.inventory())
        } catch {
            localCache = .unavailable(error.localizedDescription)
        }
    }

    /// Frees every cached file the user has not asked to keep offline.
    ///
    /// The system has the last word — a document open in another app stays — so this reports what came
    /// back rather than assuming the bytes are gone, and re-measures afterwards.
    func clearLocalCache() async {
        guard let services else { return }
        localCache = .loading
        do {
            lastEviction = try await services.offline.releaseEligibleItems()
        } catch {
            lastEviction = nil
            localCache = .unavailable(error.localizedDescription)
            await refreshActivity()
            return
        }
        await refreshLocalCache()
        await refreshActivity()
    }

    /// Sets or clears one object's "keep offline" mark. Used by the file browser; the answer is
    /// returned so the caller can say plainly whether the bytes are on their way.
    @discardableResult
    func setKeepOffline(_ file: DriveFile, pinned: Bool) async -> PinOutcome? {
        guard let services else { return nil }
        let outcome = await services.offline.setPinned(file, pinned: pinned)
        await refreshLocalCache()
        await refreshActivity()
        return outcome
    }

    /// The marks CloudDisk's own browser shows, read from the same file the extension enumerates from.
    func pinnedDriveIDs() async -> Set<String> {
        guard let state = services?.state else { return [] }
        return await state.pinnedDriveIDs()
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
