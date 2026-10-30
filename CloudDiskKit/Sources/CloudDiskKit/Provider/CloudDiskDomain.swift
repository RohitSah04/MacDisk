import Foundation
import FileProvider

/// The single description of the Finder location CloudDisk creates.
///
/// The app registers the domain, the extension serves the domain it is handed, and the UI reports on
/// it; all three read it from here so an identifier or a display name cannot drift apart between
/// them. `NSFileProviderDomain` is a mutable value class, so `make(from:)` configures it in one place.
public enum CloudDiskDomain {

    public static func make(identifier: String = CloudDiskConfig.domainIdentifierValue,
                            displayName: String = CloudDiskConfig.displayName) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                                         displayName: displayName)
        // Drive has a real trash and CloudDisk's delete moves objects into it, so the system may
        // present a Trash for this domain instead of hiding deleted items from Finder.
        domain.supportsSyncingTrash = true
        return domain
    }

    /// Every domain registered for this user by any build of this app.
    public static func registered() async -> [NSFileProviderDomain] {
        do {
            return try await NSFileProviderManager.domains()
        } catch {
            return []
        }
    }

    public static func isRegistered(identifier: String = CloudDiskConfig.domainIdentifierValue) async -> Bool {
        await registered().contains { $0.identifier.rawValue == identifier }
    }

    // MARK: Registration

    public enum RegistrationOutcome: Equatable, Sendable {
        /// The domain is registered, either created here or updated: `addDomain` refreshes the display
        /// name of an existing identifier instead of failing. It does *not* change which appex the
        /// system launches, which is why `repair` exists.
        case registered
        /// The identifier is free but the on-disk location it would replicate into is occupied, so
        /// the system refused. Recovered by removing the stale domain.
        case storageLocationOccupied
        case failed(userMessage: String)
    }

    /// Called on every launch, not only the first one: the display name and the domain features are
    /// taken from the domain object handed in here, and a domain that is never re-added keeps the
    /// settings — and only the settings — of whichever build first created it.
    @discardableResult
    public static func register(_ domain: NSFileProviderDomain = CloudDiskDomain.make()) async -> RegistrationOutcome {
        do {
            try await NSFileProviderManager.add(domain)
            return .registered
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteFileExistsError {
                // The replicated location already exists. If this very domain is registered, that
                // folder is its own volume and the domain is alive; if not, the folder belongs to a
                // leftover installation and nothing CloudDisk can do will make the mount succeed.
                return await isRegistered(identifier: domain.identifier.rawValue)
                    ? .registered
                    : .storageLocationOccupied
            }
            return .failed(userMessage: ns.localizedDescription)
        }
    }

    /// Removes the domain, keeping whatever the user had downloaded in a location the caller can
    /// report. Used by the "remove CloudDisk from Finder" action, never by sign-out: signing out
    /// must not delete the user's local copies.
    public enum RemovalOutcome: Equatable, Sendable {
        case removed(preservedItemsAt: URL?)
        case notRegistered
        case failed(userMessage: String)
    }

    @discardableResult
    public static func unregister(_ domain: NSFileProviderDomain = CloudDiskDomain.make()) async -> RemovalOutcome {
        guard await isRegistered(identifier: domain.identifier.rawValue) else { return .notRegistered }
        do {
            let preserved = try await NSFileProviderManager.remove(domain,
                                                                   mode: .preserveDownloadedUserData)
            return .removed(preservedItemsAt: preserved)
        } catch {
            return .failed(userMessage: (error as NSError).localizedDescription)
        }
    }

    /// Re-registers the domain so the system takes the extension bundle URL from *this* app copy.
    ///
    /// Adding a domain that already exists updates its display name but does not replace the appex the
    /// system launches, which is how an update — or a second build of the same bundle identifier on a
    /// developer machine — leaves Finder served by an extension that no longer matches the app. The
    /// domain has to be removed first, and removing it with `.preserveDownloadedUserData` keeps every
    /// file the user had downloaded.
    public enum RepairOutcome: Equatable, Sendable {
        case reregistered
        case failed(userMessage: String)
    }

    @discardableResult
    public static func repair(_ domain: NSFileProviderDomain = CloudDiskDomain.make()) async -> RepairOutcome {
        switch await unregister(domain) {
        case .failed(let message):
            return .failed(userMessage: "CloudDisk could not remove its Finder location in order to "
                                      + "re-create it: \(message)")
        case .notRegistered, .removed:
            break
        }

        // The old volume can take a moment to disappear, and `addDomain` refuses while its folder is
        // still on disk, so the registration is retried briefly rather than reported as occupied.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            switch await register(domain) {
            case .registered:
                return .reregistered
            case .storageLocationOccupied:
                continue
            case .failed(let message):
                return .failed(userMessage: message)
            }
        }
        return .failed(userMessage: "CloudDisk removed its Finder location but could not create it "
                                  + "again: the folder it mounts into is still occupied.")
    }

    // MARK: Nudging the extension

    /// Asks the running extension to re-enumerate. The app uses this after sign-in, because the
    /// extension may have cached a "not authenticated" working set from before the credential existed.
    public static func signalResync(_ domain: NSFileProviderDomain = CloudDiskDomain.make()) async -> Bool {
        guard let manager = NSFileProviderManager(for: domain) else { return false }
        do {
            try await manager.signalEnumerator(for: .rootContainer)
            try await manager.signalEnumerator(for: .workingSet)
            return true
        } catch {
            return false
        }
    }

    // MARK: Where the user sees it

    /// The folder Finder opens for this domain, or nil while the domain is not mounted.
    ///
    /// Asked of the system rather than guessed from the display name: FPFS derives the folder from
    /// both the container app and the domain, and a sandboxed app cannot read
    /// `~/Library/CloudStorage` to confirm a guess anyway.
    public static func userVisibleURL(for domain: NSFileProviderDomain = CloudDiskDomain.make()) async -> URL? {
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        return try? await manager.getUserVisibleURL(for: .rootContainer)
    }
}

/// One-time cleanup of the credential storage the prototype used.
///
/// The prototype copied the Google access token into App Group `UserDefaults`, which stores it as
/// plaintext inside the shared container. The keychain store replaced it, so those leftovers are
/// removed on launch instead of waiting for the container to be deleted.
public enum CloudDiskMigration {

    static let legacyTokenKeys = ["GoogleDriveAccessToken", "GoogleDriveAccessTokenExpiry"]

    /// Returns the number of legacy keys removed, so a test can assert on it and the UI can stay quiet.
    @discardableResult
    public static func purgeLegacyTokenBridge(suite: UserDefaults? = nil) -> Int {
        let defaults = suite ?? UserDefaults(suiteName: CloudDiskConfig.appGroupIdentifier)
        guard let defaults else { return 0 }
        var removed = 0
        for key in legacyTokenKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed += 1
        }
        if removed > 0 { defaults.synchronize() }
        return removed
    }
}
