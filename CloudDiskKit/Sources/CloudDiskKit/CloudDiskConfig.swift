import Foundation

/// Build-time configuration shared by the app and the File Provider extension.
///
/// Every value here has to be readable from both processes, so it comes either from a
/// compiled-in default or from the Info.plist of the process that loaded the package.
public struct CloudDiskConfig: Equatable, Sendable {

    public static let appGroupIdentifier = "group.dev.rohitsah.clouddisk"

    /// File Provider domain identifier. Changing this orphans the previously registered
    /// domain, so it must stay stable for existing users.
    public static let domainIdentifierValue = "primary-google-drive"

    public static let driveAPIBaseURL = "https://www.googleapis.com/drive/v3"
    public static let driveUploadBaseURL = "https://www.googleapis.com/upload/drive/v3"
    public static let googleTokenURLString = "https://oauth2.googleapis.com/token"
    public static let googleRevokeURLString = "https://oauth2.googleapis.com/revoke"

    /// Scope required to enumerate, read and write a whole Drive. This is a *sensitive*
    /// Google scope: an unverified OAuth consent screen limits sign-in to listed test users.
    public static let driveScope = "https://www.googleapis.com/auth/drive"

    /// Keychain access group used to share the credential between the container app and
    /// the extension. It must be the full `TEAMID.<suffix>` string, which is why it is read
    /// from Info.plist (`$(AppIdentifierPrefix)` is expanded at build time) instead of
    /// being hardcoded.
    public static let keychainAccessGroupPlistKey = "CloudDiskKeychainAccessGroup"

    /// OAuth client id, read from `GIDClientID` so one value drives both sign-in and refresh.
    public static let clientIDPlistKey = "GIDClientID"

    /// The name the domain appears under in Finder's sidebar and in the "Keep downloaded" menu.
    /// It is fixed rather than configurable because renaming a registered domain's display name
    /// does not move the on-disk volume, and two names for one location confuses users.
    public static let displayName = "CloudDisk"

    public let clientID: String
    public let keychainAccessGroup: String?
    public let domainIdentifier: String

    public init(
        clientID: String,
        keychainAccessGroup: String?,
        domainIdentifier: String = CloudDiskConfig.domainIdentifierValue
    ) {
        self.clientID = clientID
        self.keychainAccessGroup = keychainAccessGroup
        self.domainIdentifier = domainIdentifier
    }

    public enum ConfigError: LocalizedError, Equatable {
        case missingClientID
        case unresolvedKeychainAccessGroup(String)

        public var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "CloudDisk is missing its Google OAuth client id (GIDClientID)."
            case .unresolvedKeychainAccessGroup(let value):
                return "CloudDisk's shared keychain access group is not configured for this build (found \"\(value)\"). The $(AppIdentifierPrefix) placeholder was not expanded, so the app and the File Provider extension cannot share credentials."
            }
        }
    }

    /// Reads the process' own Info.plist. Works in both the app and the extension because
    /// both bundles carry the same keys.
    ///
    /// Unexpanded `$(...)` placeholders are treated as missing configuration: an Info.plist whose
    /// build setting was never defined reads back as a literal `$(CLOUDDISK_GOOGLE_CLIENT_ID)`,
    /// which would otherwise be sent to Google as a client id.
    public static func current(bundle: Bundle = .main) throws -> CloudDiskConfig {
        guard let clientID = bundle.object(forInfoDictionaryKey: clientIDPlistKey) as? String,
              isConfigured(clientID) else {
            throw ConfigError.missingClientID
        }

        let accessGroup = bundle.object(forInfoDictionaryKey: keychainAccessGroupPlistKey) as? String
        if let accessGroup, !isConfigured(accessGroup) {
            throw ConfigError.unresolvedKeychainAccessGroup(accessGroup)
        }

        return CloudDiskConfig(clientID: clientID, keychainAccessGroup: accessGroup)
    }

    private static func isConfigured(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("$(")
    }
}
