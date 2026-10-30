import Foundation
import Security

/// Keychain-backed credential store, shared between the container app and the File Provider
/// extension through a keychain access group.
///
/// This replaces the prototype's `UserDefaults(suiteName:)` token bridge, which stored a live
/// Google access token as plaintext in the App Group container.
public struct KeychainCredentialStore: CredentialStore {

    public static let defaultServiceName = "dev.rohitsah.clouddisk.google-credential"
    public static let defaultAccountName = "primary"

    /// Info.plist override for the data-protection keychain switch.
    public static let useDataProtectionKeychainPlistKey = "CloudDiskKeychainUseDataProtectionKeychain"

    public let service: String
    public let account: String
    /// Full `TEAMID.<suffix>` string, e.g. `59YP46BFR2.dev.rohitsah.clouddisk`.
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool

    public init(service: String = KeychainCredentialStore.defaultServiceName,
                account: String = KeychainCredentialStore.defaultAccountName,
                accessGroup: String?,
                useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    /// Store for the current process, configured from its own Info.plist.
    public static func current(config: CloudDiskConfig, bundle: Bundle = .main) -> KeychainCredentialStore {
        let flagValue = bundle.object(forInfoDictionaryKey: useDataProtectionKeychainPlistKey)
        let flag: Bool
        if let string = flagValue as? String {
            flag = !(string == "0" || string.lowercased() == "false" || string.lowercased() == "no")
        } else if let number = flagValue as? NSNumber {
            flag = number.boolValue
        } else {
            flag = true
        }
        return KeychainCredentialStore(accessGroup: config.keychainAccessGroup,
                                       useDataProtectionKeychain: flag)
    }

    // MARK: CredentialStore

    public func load() throws -> GoogleCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedResult(operation: "load")
            }
            return try JSONDecoder().decode(GoogleCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: "load")
        }
    }

    public func save(_ credential: GoogleCredential) throws {
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "CloudDisk Google Drive credential"
        // The extension must be able to read the credential after a reboot, without the app ever
        // having been launched in that boot session.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "CloudDisk Google Drive credential"

        // Update first, insert on miss: keeps the operation idempotent when both processes sign in
        // around the same time.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                        attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                // A second process can win the race between the update and the add. Treat the
                // duplicate as success, since the stored value is the one we just wrote elsewhere.
                if addStatus == errSecDuplicateItem { return }
                throw KeychainError(status: addStatus, operation: "save")
            }
            return
        default:
            throw KeychainError(status: updateStatus, operation: "save")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    // MARK: Diagnostics

    /// Result of a save/read/delete round-trip. The app surfaces this so a keychain-group mistake
    /// is reported as a configuration error instead of a mysterious "not signed in".
    public struct ProbeResult: Sendable, Equatable {
        public let saveStatus: OSStatus
        public let readStatus: OSStatus
        public let readBackMatched: Bool
        public let deleteStatus: OSStatus
        public var isUsable: Bool {
            saveStatus == errSecSuccess && readStatus == errSecSuccess && readBackMatched
        }
    }

    public func probe() -> ProbeResult {
        let marker = "clouddisk-probe-\(UUID().uuidString)"
        let probeAccount = "\(account).probe"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        let payload = marker.data(using: .utf8)!
        var addAttributes = query
        addAttributes[kSecValueData as String] = payload
        let saveStatus = SecItemAdd(addAttributes as CFDictionary, nil)

        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        let matched = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } == marker
        let deleteStatus = SecItemDelete(query as CFDictionary)

        return ProbeResult(saveStatus: saveStatus, readStatus: readStatus,
                           readBackMatched: matched, deleteStatus: deleteStatus)
    }

    // MARK: Plumbing

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public enum KeychainError: LocalizedError, Equatable {
        case status(OSStatus, operation: String)
        case unexpectedResult(operation: String)

        public init(status: OSStatus, operation: String) {
            self = .status(status, operation: operation)
        }

        public var errorDescription: String? {
            switch self {
            case .status(let status, let operation):
                let hint: String
                switch status {
                case errSecMissingEntitlement:
                    hint = " The keychain-access-groups entitlement does not cover this access group; check both targets' entitlements files."
                case errSecAuthFailed, -25293:
                    hint = " The item exists but was written by a different signing identity; sign out and reconnect the Google account."
                default:
                    hint = ""
                }
                return "CloudDisk could not \(operation) its credential in the shared keychain (OSStatus \(status)).\(hint)"
            case .unexpectedResult(let operation):
                return "CloudDisk read an unexpected value from the shared keychain during \(operation)."
            }
        }
    }
}
