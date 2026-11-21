import CloudDiskKit
import Foundation
import Security
import XCTest


final class KeychainPersistenceTests: XCTestCase {

    /// A store for this test alone. A distinct account keeps the user's real credential untouched.
    private func probeStore() throws -> KeychainCredentialStore {
        let config = try CloudDiskConfig.current()
        guard let accessGroup = config.keychainAccessGroup else {
            throw XCTSkip("No \(CloudDiskConfig.keychainAccessGroupPlistKey) in this build's Info.plist.")
        }
        return KeychainCredentialStore(service: KeychainCredentialStore.defaultServiceName,
                                       account: "acceptance-probe",
                                       accessGroup: accessGroup,
                                       useDataProtectionKeychain: true)
    }

    private func makeCredential(marker: String) -> GoogleCredential {
        GoogleCredential(accessToken: "probe-access-\(marker)",
                         refreshToken: "probe-refresh-\(marker)",
                         tokenExpiration: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Never assert on the whole credential: a failing XCTAssertEqual would print the stored data,
    /// and the stored data is a live Google token.
    private func assertSameAccount(_ loaded: GoogleCredential, marker: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(loaded.accessToken, "probe-access-\(marker)",
                       "the access token read back is not the one written", file: file, line: line)
        XCTAssertEqual(loaded.refreshToken, "probe-refresh-\(marker)",
                       "the refresh token read back is not the one written", file: file, line: line)
    }

    func testWritingAndReadingBackOneCredentialSucceeds() throws {
        let store = try probeStore()
        let marker = UUID().uuidString
        defer { try? store.delete() }

        do {
            try store.save(makeCredential(marker: marker))
        } catch {
            XCTFail("save() refused to write: \(error.localizedDescription)")
            return
        }

        let loaded = try store.load()
        guard let loaded else {
            XCTFail("save() reported success but load() found nothing")
            return
        }
        assertSameAccount(loaded, marker: marker)
    }

    /// Sign-in runs save() twice for one account: once for Google's token, once again after the
    /// extension refreshes it. The second write has to update the item, not fail on it.
    func testOverwritingAnExistingCredentialSucceeds() throws {
        let store = try probeStore()
        let first = UUID().uuidString
        let second = UUID().uuidString
        defer { try? store.delete() }

        try store.save(makeCredential(marker: first))

        do {
            try store.save(makeCredential(marker: second))
        } catch {
            XCTFail("the second save() could not update the stored item: \(error.localizedDescription)")
            return
        }
        guard let loaded = try store.load() else {
            XCTFail("overwriting left no stored credential")
            return
        }
        assertSameAccount(loaded, marker: second)
    }

    /// The app writes the credential; only the extension's read proves the group is shared. This is
    /// the half that can be reached from the app side: the same item must be readable through the
    /// access group rather than the app's private default.
    func testTheStoredItemIsReachableThroughTheSharedAccessGroup() throws {
        let store = try probeStore()
        let marker = UUID().uuidString
        defer { try? store.delete() }

        try store.save(makeCredential(marker: marker))

        let config = try CloudDiskConfig.current()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCredentialStore.defaultServiceName,
            kSecAttrAccount as String: "acceptance-probe",
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrAccessGroup as String] = config.keychainAccessGroup

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess,
                       "the item written under the shared group cannot be read back through that group")
    }
}
