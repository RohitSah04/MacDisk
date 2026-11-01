import Foundation
import os

/// The provider side's own log stream.
///
/// `fileproviderd` records what it asked the extension for, but it cannot record what the extension
/// decided to do about it, and a folder Finder renders empty is undiagnosable without that. Carries
/// identifiers, counts and error descriptions only — never a token, a credential or file contents.
enum ProviderLog {

    private static let log = Logger(subsystem: "dev.rohitsah.clouddisk", category: "provider")

    /// `Logger` marks interpolated values private, which `log show` renders as `<private>`; the text
    /// is assembled here from non-sensitive fields, so it is published as written.
    static func note(_ message: String) {
        log.log("\(message, privacy: .public)")
    }

    static func failure(_ message: String) {
        log.error("\(message, privacy: .public)")
    }
}
