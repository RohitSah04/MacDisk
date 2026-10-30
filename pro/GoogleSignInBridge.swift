import AppKit
import CloudDiskKit
import GoogleSignIn

/// The only file in this project that knows the GoogleSignIn SDK exists.
///
/// CloudDiskKit deliberately does not link it: the File Provider extension is launched by
/// `fileproviderd`, frequently while the app is not running, and must refresh the credential
/// against the plain OAuth2 endpoint by itself. So the SDK's result is converted into a
/// `GoogleCredential` here, and everything downstream is provider-agnostic.
enum GoogleSignInBridge {

    enum Failure: LocalizedError, Equatable {
        case cancelled
        case missingRefreshToken
        case driveScopeNotGranted(granted: [String])
        case misconfigured(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled, so CloudDisk is still not connected to Google Drive."
            case .missingRefreshToken:
                return "Google returned an access token but no way to renew it, so CloudDisk cannot keep working after an hour. Sign out and connect again."
            case .driveScopeNotGranted(let granted):
                return """
                Google did not grant CloudDisk full Drive access. It asked for \
                \(CloudDiskConfig.driveScope) and the account granted \
                \(granted.isEmpty ? "nothing" : granted.joined(separator: ", ")). \
                For an unverified OAuth consent screen only listed test users get this scope.
                """
            case .misconfigured(let reason):
                return "CloudDisk cannot start sign-in: \(reason)"
            }
        }
    }

    /// Runs the consent flow and returns the credential to store. Nothing is persisted here: the
    /// caller owns the keychain, so a rejected scope never leaves a half-useful grant behind.
    @MainActor
    static func signIn(from window: NSWindow) async throws -> GoogleCredential {
        let config: CloudDiskConfig
        do {
            config = try CloudDiskConfig.current()
        } catch {
            throw Failure.misconfigured(error.localizedDescription)
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: config.clientID)

        let user: GIDGoogleUser
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: window,
                hint: nil,
                additionalScopes: [CloudDiskConfig.driveScope])
            user = try await result.user.refreshTokensIfNeeded()
        } catch let error {
            throw isCancellation(error) ? Failure.cancelled : error
        }

        let refreshToken = user.refreshToken.tokenString
        guard !refreshToken.isEmpty else { throw Failure.missingRefreshToken }

        let granted = user.grantedScopes ?? []
        if !granted.isEmpty, !granted.contains(CloudDiskConfig.driveScope) {
            throw Failure.driveScopeNotGranted(granted: granted)
        }

        return GoogleCredential(
            accessToken: user.accessToken.tokenString,
            refreshToken: refreshToken,
            // With no expiry reported, treat the token as already expired so the first Drive call
            // goes through the refresh path instead of assuming an unverified lifetime.
            tokenExpiration: user.accessToken.expirationDate ?? Date(timeIntervalSinceNow: -1),
            scope: granted.isEmpty ? nil : granted.joined(separator: " "),
            accountEmail: user.profile?.email,
            accountIdentifier: user.userID,
            displayName: user.profile?.name)
    }

    /// The SDK's error enum is not imported into Swift by GoogleSignIn 10.1, so the domain constant
    /// plus the documented code for cancellation is the comparison that actually compiles.
    private static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == kGIDSignInErrorDomain && ns.code == -5
    }

    /// Clears the SDK's own keychain copy. CloudDisk's credential is revoked and deleted separately
    /// by `TokenProvider`, which is the part that matters for the extension.
    @MainActor
    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
}
