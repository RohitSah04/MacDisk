
import SwiftUI
import AppKit
import GoogleSignIn

struct DriveFile: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let size: String
    let modified: String
    let icon: String
    let color: Color
}

struct ContentView: View {
    @State private var selectedSection = "All Files"
    @State private var searchText = ""
    @State private var showingAccountAlert = false
    @State private var authErrorMessage = ""
    @State private var accountEmail: String?
    @State private var isConnecting = false

    private let driveScope =
        "https://www.googleapis.com/auth/drive.readonly"

    // Demo data only. Real Google Drive files will be added next.
    private let files: [DriveFile] = [
        DriveFile(
            name: "Project Proposal.pdf",
            type: "PDF Document",
            size: "2.4 MB",
            modified: "Today",
            icon: "doc.richtext.fill",
            color: .red
        ),
        DriveFile(
            name: "Budget 2026.xlsx",
            type: "Spreadsheet",
            size: "840 KB",
            modified: "Yesterday",
            icon: "tablecells.fill",
            color: .green
        ),
        DriveFile(
            name: "Presentation.pptx",
            type: "Presentation",
            size: "5.2 MB",
            modified: "Oct 27, 2026",
            icon: "rectangle.on.rectangle",
            color: .orange
        ),
        DriveFile(
            name: "Profile Photo.png",
            type: "Image",
            size: "1.1 MB",
            modified: "Oct 25, 2026",
            icon: "photo.fill",
            color: .purple
        ),
        DriveFile(
            name: "Meeting Notes.docx",
            type: "Word Document",
            size: "320 KB",
            modified: "Oct 24, 2026",
            icon: "doc.text.fill",
            color: .blue
        )
    ]

    private var filteredFiles: [DriveFile] {
        let sectionFiles: [DriveFile]

        switch selectedSection {
        case "Recent":
            sectionFiles = Array(files.prefix(3))
        case "Starred", "Trash":
            sectionFiles = []
        default:
            sectionFiles = files
        }

        guard !searchText.isEmpty else {
            return sectionFiles
        }

        return sectionFiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
        }
        .navigationSplitViewStyle(.balanced)
        .alert(
            "Google Drive connection",
            isPresented: $showingAccountAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("CloudDisk")
                        .font(.title2.bold())

                    Text("Your cloud, together")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            List(selection: $selectedSection) {
                Section("LIBRARY") {
                    Label("All Files", systemImage: "folder.fill")
                        .tag("All Files")

                    Label("Recent", systemImage: "clock")
                        .tag("Recent")

                    Label("Starred", systemImage: "star")
                        .tag("Starred")

                    Label("Trash", systemImage: "trash")
                        .tag("Trash")
                }

                Section("ACCOUNTS") {
                    Label(
                        accountEmail ?? "Google Drive",
                        systemImage: "cloud"
                    )
                    .lineLimit(1)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 10) {
                Divider()

                HStack(spacing: 10) {
                    Image(
                        systemName: accountEmail == nil
                            ? "cloud"
                            : "checkmark.icloud.fill"
                    )
                    .font(.title2)
                    .foregroundStyle(
                        accountEmail == nil ? Color.secondary : Color.green
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            accountEmail == nil
                                ? "No accounts connected"
                                : "Google connected"
                        )
                        .font(.subheadline.weight(.medium))

                        Text(accountEmail ?? "Connect your Google Drive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Button {
                    Task {
                        await connectGoogleAccount()
                    }
                } label: {
                    Label(
                        isConnecting ? "Connecting..." : "Connect Account",
                        systemImage: "plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }
            .padding(14)
        }
        .frame(minWidth: 220)
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedSection)
                        .font(.largeTitle.bold())

                    Text("Manage your files in one place.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await connectGoogleAccount()
                    }
                } label: {
                    Label(
                        isConnecting ? "Connecting..." : "Add Account",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }

            HStack(spacing: 16) {
                statCard(
                    title: "Connected accounts",
                    value: accountEmail == nil ? "0" : "1",
                    icon: "person.crop.circle",
                    color: .blue
                )

                statCard(
                    title: "Files shown",
                    value: "\(filteredFiles.count)",
                    icon: "doc.on.doc",
                    color: .purple
                )

                statCard(
                    title: "Cloud storage",
                    value: accountEmail == nil
                        ? "Not connected"
                        : "Connected",
                    icon: "externaldrive",
                    color: .green
                )
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search files...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            fileTable

            Spacer(minLength: 0)

            HStack {
                Image(systemName: "info.circle")
                Text("Preview mode · Sample files only")
                Spacer()
                Text("CloudDisk for macOS")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 650, minHeight: 480)
    }

    // MARK: - File table

    private var fileTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NAME")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("TYPE")
                    .frame(width: 145, alignment: .leading)

                Text("SIZE")
                    .frame(width: 85, alignment: .trailing)

                Text("MODIFIED")
                    .frame(width: 115, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(12)

            Divider()

            if filteredFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)

                    Text(
                        searchText.isEmpty
                            ? "No files here yet"
                            : "No matching files"
                    )
                    .font(.headline)

                    Text(
                        searchText.isEmpty
                            ? "Connect Google Drive to see your files."
                            : "Try another search."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredFiles) { file in
                            HStack(spacing: 12) {
                                Image(systemName: file.icon)
                                    .font(.title2)
                                    .foregroundStyle(file.color)
                                    .frame(width: 28)

                                Text(file.name)
                                    .lineLimit(1)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )

                                Text(file.type)
                                    .foregroundStyle(.secondary)
                                    .frame(
                                        width: 145,
                                        alignment: .leading
                                    )

                                Text(file.size)
                                    .foregroundStyle(.secondary)
                                    .frame(
                                        width: 85,
                                        alignment: .trailing
                                    )

                                Text(file.modified)
                                    .foregroundStyle(.secondary)
                                    .frame(
                                        width: 115,
                                        alignment: .trailing
                                    )
                            }
                            .font(.subheadline)
                            .padding(12)

                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        }
    }

    // MARK: - Google Sign-In and token sharing

    @MainActor
    private func connectGoogleAccount() async {
        guard let clientID = Bundle.main.object(
            forInfoDictionaryKey: "GIDClientID"
        ) as? String, !clientID.isEmpty else {
            showAuthError(
                "Google Client ID is missing. Check GIDClientID in your target's Info settings."
            )
            return
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            showAuthError(
                "CloudDisk could not find its window. Close and reopen the app, then try again."
            )
            return
        }

        isConnecting = true
        defer {
            isConnecting = false
        }

        GIDSignIn.sharedInstance.configuration =
            GIDConfiguration(clientID: clientID)

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: window,
                hint: nil,
                additionalScopes: [driveScope]
            )

            // Refresh the Google access token if needed.
            let refreshedUser =
                try await result.user.refreshTokensIfNeeded()

            accountEmail = refreshedUser.profile?.email
                ?? "Google account connected"

            // TEMPORARY DEVELOPMENT BRIDGE:
            // Share the access token with the File Provider extension
            // through the shared App Group UserDefaults.
            guard let sharedDefaults = UserDefaults(
                suiteName: "group.dev.rohitsah.clouddisk"
            ) else {
                throw NSError(
                    domain: "CloudDisk",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not access the shared App Group."
                    ]
                )
            }

            // Save the Google access token.
            sharedDefaults.set(
                refreshedUser.accessToken.tokenString,
                forKey: "GoogleDriveAccessToken"
            )

            // Save the token expiry time.
            sharedDefaults.set(
                refreshedUser.accessToken.expirationDate?
                    .timeIntervalSince1970 ?? 0,
                forKey: "GoogleDriveAccessTokenExpiry"
            )

            authErrorMessage = ""

            print(
                "Google Sign-In succeeded: \(accountEmail ?? "")"
            )

            print(
                "Google Drive access token shared with File Provider."
            )

        } catch {
            showAuthError(
                "Google Sign-In failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func showAuthError(_ message: String) {
        authErrorMessage = message
        showingAccountAlert = true
    }

    // MARK: - Stat card

    private func statCard(
        title: String,
        value: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}

