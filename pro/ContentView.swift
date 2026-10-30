import AppKit
import CloudDiskKit
import SwiftUI

/// CloudDisk's status window.
///
/// Every value here is read from the running system: the credential in the shared keychain, the
/// domain registered with File Provider, the quota returned by Drive, and the activity log the
/// extension writes. Nothing is simulated, so a green row means that part actually works.
struct ContentView: View {
    @ObservedObject var core: AppCore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let problem = core.configurationProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                statusCard
                activityCard

                Text("Files in Finder download when you open them. Choose “Keep downloaded” on a file or folder to keep it on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 720, minHeight: 460)
        .refreshable {
            await core.refreshStorage()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CloudDisk")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Your Google Drive as a Finder location")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusCard: some View {
        Card(title: "Setup") {
            accountRow
            Divider()
            locationRow
            Divider()
            extensionRow
            Divider()
            keychainRow
            Divider()
            storageRow
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        switch core.account {
        case .unknown:
            Row(title: "Google account", systemImage: "person.crop.circle", tint: .secondary,
                detail: "Checking the stored credential…") { EmptyView() }
        case .busy:
            Row(title: "Google account", systemImage: "person.crop.circle", tint: .secondary,
                detail: "Waiting for Google to finish sign-in…") {
                ProgressView().controlSize(.small)
            }
        case .signedOut:
            Row(title: "Google account", systemImage: "person.crop.circle.badge.xmark", tint: .orange,
                detail: "Not connected. CloudDisk needs full Drive access to read and write files.") {
                Button("Connect…") {
                    Task { await core.signIn() }
                }
            }
        case .connected(let email, let name):
            Row(title: "Google account", systemImage: "checkmark.circle.fill", tint: .green,
                detail: email ?? name ?? "Connected") {
                Button("Sign out") {
                    Task { await core.signOut() }
                }
            }
        case .problem(let message):
            Row(title: "Google account", systemImage: "exclamationmark.circle.fill", tint: .red,
                detail: message) {
                Button("Try again") {
                    Task { await core.signIn() }
                }
            }
        }
    }

    @ViewBuilder
    private var locationRow: some View {
        switch core.location {
        case .unknown:
            Row(title: "Finder location", systemImage: "menubar.dock.rectangle", tint: .secondary,
                detail: "Not checked yet.") { EmptyView() }
        case .registering:
            Row(title: "Finder location", systemImage: "menubar.dock.rectangle", tint: .secondary,
                detail: "Registering the CloudDisk domain…") { ProgressView().controlSize(.small) }
        case .registered(let url):
            Row(title: "Finder location",
                systemImage: url == nil ? "clock" : "checkmark.circle.fill",
                tint: url == nil ? .secondary : .green,
                detail: url.map(\.path)
                    ?? "Registered. Finder has not mounted the volume yet — it usually appears within a few seconds.") {
                if url != nil {
                    Button("Open in Finder") { core.revealLocation() }
                } else {
                    Button("Check again") {
                        Task { await core.refreshLocation() }
                    }
                }
            }
        case .absent:
            Row(title: "Finder location", systemImage: "xmark.circle", tint: .orange,
                detail: "Not registered. Connecting an account registers it.") { EmptyView() }
        case .blocked(let message):
            Row(title: "Finder location", systemImage: "exclamationmark.circle.fill", tint: .red,
                detail: message) {
                Button("Register again") {
                    Task { await core.prepare() }
                }
            }
        }
    }

    @ViewBuilder
    private var extensionRow: some View {
        switch core.extensionStatus {
        case .unknown:
            Row(title: "File Provider extension", systemImage: "puzzlepiece.extension", tint: .secondary,
                detail: "Not checked yet.") { EmptyView() }
        case .checking:
            Row(title: "File Provider extension", systemImage: "puzzlepiece.extension", tint: .secondary,
                detail: "Asking Finder which CloudDisk extension is serving the location…") {
                ProgressView().controlSize(.small)
            }
        case .live(let at):
            Row(title: "File Provider extension", systemImage: "checkmark.circle.fill", tint: .green,
                detail: "Serving this build — last answer \(at.formatted(.relative(presentation: .named))).") {
                EmptyView()
            }
        case .servedByOtherBuild(let path):
            Row(title: "File Provider extension", systemImage: "exclamationmark.circle.fill", tint: .red,
                detail: "Re-registering the location did not move it off this older copy: \(path). "
                      + "Quit CloudDisk and delete that copy, then reopen CloudDisk.") {
                Button("Check again") {
                    Task { await core.refreshLocation() }
                }
            }
        case .notAnswering:
            Row(title: "File Provider extension", systemImage: "exclamationmark.triangle.fill", tint: .orange,
                detail: "The location is registered but no CloudDisk extension answered, so Finder will "
                      + "show it empty. This usually means the extension failed its launch checks — "
                      + "check that this copy of CloudDisk is signed with the same team as its extension.") {
                Button("Check again") {
                    Task { await core.refreshLocation() }
                }
            }
        case .unavailable(let message):
            Row(title: "File Provider extension", systemImage: "exclamationmark.circle.fill", tint: .red,
                detail: message) {
                Button("Check again") {
                    Task { await core.refreshLocation() }
                }
            }
        }
    }

    @ViewBuilder
    private var keychainRow: some View {
        switch core.credentialStorage {
        case .unknown:
            Row(title: "Credential sharing", systemImage: "key.horizontal", tint: .secondary,
                detail: "Not checked yet.") { EmptyView() }
        case .usable:
            Row(title: "Credential sharing", systemImage: "checkmark.circle.fill", tint: .green,
                detail: "The app and the File Provider extension read one keychain item.") { EmptyView() }
        case .unusable(let message):
            Row(title: "Credential sharing", systemImage: "exclamationmark.circle.fill", tint: .red,
                detail: message) {
                Button("Re-check") {
                    Task { await core.prepare() }
                }
            }
        }
    }

    @ViewBuilder
    private var storageRow: some View {
        switch core.storage {
        case .unknown:
            Row(title: "Google Drive storage", systemImage: "internaldrive", tint: .secondary,
                detail: "Not loaded yet.") { EmptyView() }
        case .loading:
            Row(title: "Google Drive storage", systemImage: "internaldrive", tint: .secondary,
                detail: "Reading the quota from Drive…") { ProgressView().controlSize(.small) }
        case .loaded(let used, let limit, let accountName):
            Row(title: "Google Drive storage", systemImage: "internaldrive", tint: .accentColor,
                detail: usageText(used: used, limit: limit, accountName: accountName)) {
                Button("Refresh") {
                    Task { await core.refreshStorage() }
                }
            }
        case .unavailable(let message):
            Row(title: "Google Drive storage", systemImage: "questionmark.circle", tint: .secondary,
                detail: message) {
                Button("Retry") {
                    Task { await core.refreshStorage() }
                }
            }
        }
    }

    private func usageText(used: Int64?, limit: Int64?, accountName: String?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var text: String
        if let used, let limit, limit > 0 {
            text = "\(formatter.string(fromByteCount: used)) of \(formatter.string(fromByteCount: limit)) used"
        } else if let used {
            text = "\(formatter.string(fromByteCount: used)) used"
        } else {
            text = "Drive did not report a usage figure."
        }
        if let accountName, !accountName.isEmpty { text += " — \(accountName)" }
        return text
    }

    // MARK: Activity

    private var activityCard: some View {
        Card(title: "Recent activity") {
            if core.activity.isEmpty {
                Text("No downloads, uploads or syncs recorded yet. Actions appear here as you use CloudDisk in Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(core.activity) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: event.outcome.systemImage)
                            .foregroundStyle(event.outcome.tint)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.kind.phrase) — \(event.subject)")
                                .lineLimit(2)
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(event.date.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }
}

private struct Row<Trailing: View>: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let detail: String?
    private let trailing: Trailing

    init(title: String, systemImage: String, tint: Color, detail: String?,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 8)
    }
}

private extension ProviderState.ActivityEvent.Kind {
    var phrase: String {
        switch self {
        case .download: return "Downloaded"
        case .upload: return "Uploaded"
        case .create: return "Created"
        case .rename: return "Renamed"
        case .move: return "Moved"
        case .copy: return "Copied"
        case .delete: return "Deleted"
        case .synchronize: return "Synced"
        case .signIn: return "Connected"
        case .signOut: return "Signed out of"
        case .other: return "Recorded"
        }
    }
}

private extension ProviderState.ActivityEvent.Outcome {
    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .secondary
        }
    }
}
