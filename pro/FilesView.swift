import CloudDiskKit
import SwiftUI
import UniformTypeIdentifiers

/// CloudDisk's file browser: Drive's own listing, with CloudDisk's keep-offline marks next to it.
///
/// It is a window onto Drive, not a second file system. Opening a file hands its identifier to File
/// Provider and lets the system fetch the bytes, which is why there is no download button and no
/// progress bar for a whole object here — the copy that matters is the one Finder keeps.
struct FilesView: View {
    @ObservedObject var core: AppCore
    /// Owned by `RootView`, so going to the status screen and back does not drop the folder the user
    /// was standing in.
    @ObservedObject var browser: FileBrowser

    @State private var selection: String?
    @State private var renaming: DriveFile?
    @State private var renameText = ""
    @State private var playing: DriveFile?
    @State private var previewing: PreviewTarget?

    private struct PreviewTarget: Identifiable {
        let file: DriveFile
        let url: URL
        var id: String { file.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            listingArea
                // The listing takes the slack. Without this an empty folder or a signed-out browser
                // kept its intrinsic height and the whole stack floated in the middle of the window.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .searchable(text: $browser.query, placement: .toolbar, prompt: "Search Drive")
        .onSubmit(of: .search) { Task { await browser.search() } }
        .task { await browser.reload() }
        .refreshable { await browser.refresh() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await browser.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(browser.isAtRoot || browser.searchedFor != nil)
                .help("Up one folder")
            }
            ToolbarItem {
                Button {
                    Task { await browser.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!core.isConnected)
                .help("Re-read this folder from Drive")
            }
        }
        .sheet(item: $renaming) { file in
            renameSheet(file)
        }
        .sheet(item: $playing) { file in
            if let drive = core.services?.drive {
                PlayerView(file: file, drive: drive)
            }
        }
        .sheet(item: $previewing) { target in
            if let offline = core.services?.offline {
                VStack(spacing: 0) {
                    HStack {
                        Text(target.file.name).font(.headline).lineLimit(1)
                        Spacer()
                        Button("Done") { previewing = nil }
                    }
                    .padding(12)
                    Divider()
                    PreviewView(file: target.file, url: target.url, offline: offline)
                }
            }
        }
    }

    // MARK: Listing

    @ViewBuilder
    private var listingArea: some View {
        switch browser.listing {
        case .signedOut:
            ContentUnavailableView {
                Label("No Google account", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("CloudDisk lists this folder straight from Drive, so it needs the same "
                   + "connection the Finder location uses.")
            } actions: {
                Button("Connect…") { Task { await core.signIn() } }
            }
        case .loading where browser.items.isEmpty:
            ProgressView(browser.searchedFor == nil
                         ? "Reading \(browser.currentFolder.name) from Drive…"
                         : "Searching Drive for “\(browser.searchedFor ?? "")”…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where browser.items.isEmpty:
            ContentUnavailableView {
                Label("Drive did not answer", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await browser.refresh() } }
            }
        default:
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(browser.items) { file in
                FileRow(file: file, isPinned: browser.isPinned(file))
                    .tag(file.id)
                    .onTapGesture(count: 2) { Task { await activate(file) } }
                    .contextMenu { menu(for: file) }
            }
            if browser.hasMorePages {
                Button {
                    Task { await browser.loadMore() }
                } label: {
                    Text("Load more from \(browser.currentFolder.name)")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            }
        }
        .overlay {
            if browser.items.isEmpty {
                ContentUnavailableView("This folder is empty",
                                       systemImage: "folder",
                                       description: Text("Files added in Finder's CloudDisk location "
                                                        + "are uploaded to Drive and appear here."))
            }
        }
    }

    @ViewBuilder
    private func menu(for file: DriveFile) -> some View {
        Button(file.isFolder ? "Open" : "Open with default app") {
            Task { await activate(file) }
        }
        if file.isFolder {
            Button("Open in Finder") { Task { await browser.revealInFinder(file) } }
        } else {
            Button("Preview") { Task { await beginPreview(file) } }
            if FileIcon.isPlayable(file) {
                Button("Play") { playing = file }
            }
            Button("Show in Finder") { Task { await browser.revealInFinder(file) } }
        }
        Divider()
        Button(browser.isPinned(file) ? "Release from this Mac" : "Keep offline") {
            Task { await browser.toggleKeepOffline(file) }
        }
        Divider()
        Button("Rename…") {
            renameText = file.name
            renaming = file
        }
        Button("Move to Trash", role: .destructive) {
            Task { await browser.moveToTrash(file) }
        }
    }

    private func activate(_ file: DriveFile) async {
        if file.isFolder {
            await browser.open(file)
        } else {
            await browser.openWithDefaultApp(file)
        }
    }

    private func beginPreview(_ file: DriveFile) async {
        guard let url = await browser.localURL(for: file) else {
            browser.report(.refused("CloudDisk's Finder location is not mounted, so this file "
                                         + "has no path to preview."))
            return
        }
        previewing = PreviewTarget(file: file, url: url)
    }

    // MARK: Chrome

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.trail.enumerated()), id: \.element.id) { index, folder in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Button(folder.name) {
                    Task { await browser.goTo(trailIndex: index) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == browser.trail.count - 1 ? Color.primary : Color.accentColor)
            }
            if let searched = browser.searchedFor {
                Text("· search results for “\(searched)”")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: statusImage)
                .foregroundStyle(statusTint)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
    }

    private var statusImage: String {
        switch browser.action {
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle"
        case .refused: return "exclamationmark.circle"
        case .none: return "folder"
        }
    }

    private var statusTint: Color {
        switch browser.action {
        case .done: return .green
        case .refused: return .orange
        default: return .secondary
        }
    }

    private var statusText: String {
        if case .working(let text) = browser.action { return text }
        if case .done(let text) = browser.action { return text }
        if case .refused(let text) = browser.action { return text }
        let kept = browser.items.filter { browser.isPinned($0) }.count
        var text = browser.items.isEmpty
            ? "Nothing listed yet."
            : "\(browser.items.count) item\(browser.items.count == 1 ? "" : "s") in \(browser.currentFolder.name)"
                + (kept > 0 ? " — \(kept) kept offline" : "")
        if case .failed(let message) = browser.listing {
            text += " · showing the last listing that arrived: \(message)"
        }
        return text
    }

    @ViewBuilder
    private func renameSheet(_ file: DriveFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(file.name)”")
                .font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit { Task { await commitRename(file) } }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await commitRename(file) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ file: DriveFile) async {
        await browser.rename(file, to: renameText)
        renaming = nil
    }
}

// MARK: - Rows

private struct FileRow: View {
    let file: DriveFile
    let isPinned: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: FileIcon.systemImage(for: file))
                .foregroundStyle(FileIcon.tint(for: file))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                if let note = FileIcon.note(for: file) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Image(systemName: isPinned ? "pin.fill" : "icloud")
                .foregroundStyle(isPinned ? Color.orange : Color.secondary.opacity(0.6))
                .help(isPinned ? "Kept offline on this Mac"
                               : "Online — downloads when opened")
            Text(SizeText.bytes(file.byteCount))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Text(DateText.modified(file.fileProviderModificationDate))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

enum FileIcon {
    static func systemImage(for file: DriveFile) -> String {
        if file.isFolder { return "folder.fill" }
        if file.isShortcut { return "arrow.turn.down.right" }
        switch file.mimeType {
        case "application/vnd.google-apps.document": return "doc.text.fill"
        case "application/vnd.google-apps.spreadsheet": return "tablecells.fill"
        case "application/vnd.google-apps.presentation": return "rectangle.on.rectangle.angled"
        case "application/vnd.google-apps.drawing": return "pencil.and.outline"
        case "application/vnd.google-apps.form": return "list.bullet.rectangle"
        case "application/vnd.google-apps.map": return "map.fill"
        case "application/vnd.google-apps.photo": return "photo.fill"
        case "application/vnd.google-apps.folder": return "folder.fill"
        default: break
        }
        let type = UTType(mimeType: file.mimeType)
        if type?.conforms(to: .movie) == true { return "film.fill" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .image) == true { return "photo.fill" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext.fill" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc.fill"
    }

    static func tint(for file: DriveFile) -> Color {
        if file.isFolder { return .blue }
        if file.isGoogleNative { return .accentColor }
        return .secondary
    }

    /// The one thing about a row that the name cannot say, and only when it is true.
    static func note(for file: DriveFile) -> String? {
        if file.isGoogleNative {
            return file.exportLinks?.isEmpty == false
                ? "Google document — converted to a real file when opened"
                : "Google document — has no downloadable content"
        }
        if file.isShortcut { return "Shortcut to another Drive item" }
        if file.shared == true, !file.isFolder { return "Shared with others" }
        return nil
    }

    static func isPlayable(_ file: DriveFile) -> Bool {
        guard file.hasMediaContent, file.byteCount ?? 0 > 0 else { return false }
        let type = UTType(mimeType: file.mimeType)
        return type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true
    }
}
