import AppKit
import CloudDiskKit
import Combine
import Foundation
import SwiftUI

/// The app's own listing of one Drive folder.
///
/// Separate from `AppCore` because its whole life is a sequence of requests that overtake each other:
/// the user goes into a folder, then up, then types a search, and a page that arrives after any of
/// those has to be thrown away rather than painted over the folder now on screen. Every request takes
/// a ticket and checks it before publishing.
///
/// The rows come from `files.list` and nothing else. The bytes are not here: a file's content belongs
/// to File Provider, which is why "open" and "preview" hand the item's own identifier to the system
/// instead of downloading anything in this process.
@MainActor
final class FileBrowser: ObservableObject {

    enum Listing: Equatable {
        case signedOut
        case loading
        case loaded
        /// The last request failed. Rows already on screen stay on screen — a listing that blanks
        /// because one page did not arrive reads as though the files had.
        case failed(String)
    }

    /// One line under the toolbar: what the browser is doing now, and what the last action achieved.
    enum Action: Equatable {
        case none
        case working(String)
        case done(String)
        case refused(String)
    }

    @Published private(set) var listing: Listing = .loading
    @Published private(set) var items: [DriveFile] = []
    /// My Drive first, the folder being listed last.
    @Published private(set) var trail: [DriveFile] = []
    @Published private(set) var pins: Set<String> = []
    @Published private(set) var hasMorePages = false
    @Published private(set) var action: Action = .none
    /// Non-empty while the rows are search results rather than a folder's children.
    @Published private(set) var searchedFor: String?

    @Published var query: String = "" {
        didSet { if query.isEmpty, searchedFor != nil { Task { await clearSearch() } } }
    }

    /// Rows are keyed by Drive's own object id, which is stable for the life of the file — including
    /// across a rename, which is why the trail can hold the same value as the listing.
    let root = DriveFile(id: DriveFile.rootFolderID, name: "My Drive",
                         mimeType: DriveFile.folderMimeType)

    private let core: AppCore
    private var pageToken: String?
    private var ticket = 0

    init(core: AppCore) {
        self.core = core
        trail = [root]
    }

    private var drive: DriveService? { core.services?.drive }

    var currentFolder: DriveFile { trail.last ?? root }
    var isAtRoot: Bool { trail.count <= 1 }

    // MARK: Navigation

    /// Called whenever the screen appears, so a sign-in that happened in the browser sheet while this
    /// window was hidden still produces a listing without another click.
    func reload() async {
        guard core.isConnected else {
            listing = .signedOut
            items = []
            return
        }
        if items.isEmpty { await list(parentID: currentFolder.id, token: nil, keepsRows: false) }
        await refreshPins()
    }

    func open(_ file: DriveFile) async {
        guard file.isFolder else { return }
        trail.append(file)
        query = ""
        searchedFor = nil
        await list(parentID: file.id, token: nil, keepsRows: false)
    }

    /// Jumps to a breadcrumb; everything deeper than it is dropped, so the trail cannot disagree with
    /// the rows on screen.
    func goTo(trailIndex: Int) async {
        guard trail.indices.contains(trailIndex), trailIndex < trail.count - 1 else { return }
        trail.removeSubrange((trailIndex + 1)...)
        query = ""
        searchedFor = nil
        await list(parentID: trail[trailIndex].id, token: nil, keepsRows: false)
    }

    func goUp() async {
        await goTo(trailIndex: max(0, trail.count - 2))
    }

    func refresh() async {
        guard core.isConnected else { listing = .signedOut; return }
        if let searchedFor {
            await search(text: searchedFor)
        } else {
            await list(parentID: currentFolder.id, token: nil, keepsRows: true)
        }
        await refreshPins()
    }

    func loadMore() async {
        guard let pageToken, core.isConnected, searchedFor == nil else { return }
        await list(parentID: currentFolder.id, token: pageToken, keepsRows: true)
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { await clearSearch(); return }
        await search(text: text)
    }

    func clearSearch() async {
        searchedFor = nil
        query = ""
        await list(parentID: currentFolder.id, token: nil, keepsRows: false)
    }

    private func search(text: String) async {
        guard let drive else { listing = .signedOut; return }
        let me = beginTicket()
        listing = .loading
        do {
            let found = try await drive.search(query: text, parentID: nil)
            guard isCurrent(me) else { return }
            items = found
            pageToken = nil
            hasMorePages = false
            searchedFor = text
            listing = .loaded
        } catch {
            guard isCurrent(me) else { return }
            listing = .failed(error.localizedDescription)
        }
    }

    /// - Parameter keepsRows: false when the rows on screen belong to something else, true when this
    ///   is the same listing being re-read.
    private func list(parentID: String, token: String?, keepsRows: Bool) async {
        guard let drive else {
            listing = .signedOut
            items = []
            return
        }
        let me = beginTicket()
        if !keepsRows { items = [] }
        listing = .loading
        do {
            let page = try await drive.childrenPage(parentID: parentID, pageToken: token)
            guard isCurrent(me) else { return }
            items = token == nil ? page.fileList : items + page.fileList
            pageToken = page.nextPageToken
            hasMorePages = !(page.nextPageToken ?? "").isEmpty
            searchedFor = nil
            listing = .loaded
        } catch {
            guard isCurrent(me) else { return }
            listing = .failed(error.localizedDescription)
        }
        await refreshPins()
    }

    /// Lets the view report something only the view knows — a preview that had nowhere to come from,
    /// for example — without handing out write access to the rest of the browser's state.
    func report(_ newAction: Action) { action = newAction }

    func refreshPins() async {
        pins = await core.pinnedDriveIDs()
    }

    func isPinned(_ file: DriveFile) -> Bool { pins.contains(file.id) }

    // MARK: Actions on one row

    /// Sets or clears CloudDisk's keep-offline mark, and says which of the three answers came back:
    /// the bytes are on their way, the promise is held until Finder lists the file, or the system
    /// refused and the mark is not real yet.
    func toggleKeepOffline(_ file: DriveFile) async {
        let want = !isPinned(file)
        action = .working("\(want ? "Keeping" : "Releasing") “\(file.name)”…")
        guard let outcome = await core.setKeepOffline(file, pinned: want) else {
            action = .refused("CloudDisk has no connection to its Finder location yet, so nothing "
                            + "could be marked.")
            return
        }
        await refreshPins()
        action = outcome.succeeded ? .done(Self.sentence(for: outcome, name: file.name))
                                   : .refused(Self.sentence(for: outcome, name: file.name))
    }

    static func sentence(for outcome: PinOutcome, name: String) -> String {
        switch outcome.effect {
        case .downloadScheduled:
            return "“\(name)” is downloading now and will stay on this Mac."
        case .downloadDeferred:
            return "“\(name)” is marked. Finder will keep it offline as soon as it lists the file."
        case .policyPublished:
            return "“\(name)” can be freed again when the disk needs the space."
        case .refused(let reason):
            return "Finder would not keep “\(name)” offline: \(reason)"
        case .systemUnavailable(let reason):
            return "“\(name)” is marked, but its bytes are not on their way — \(reason)"
        }
    }

    func rename(_ file: DriveFile, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        guard let drive else {
            action = .refused("CloudDisk is not connected to Drive.")
            return
        }
        action = .working("Renaming “\(file.name)”…")
        do {
            let updated = try await drive.rename(fileID: file.id, to: trimmed)
            guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
            items[index] = updated
            if let folderAt = trail.firstIndex(where: { $0.id == file.id }) { trail[folderAt] = updated }
            action = .done("Renamed to “\(trimmed)”.")
        } catch {
            action = .refused("The rename failed: \(error.localizedDescription)")
        }
    }

    func moveToTrash(_ file: DriveFile) async {
        guard let drive else {
            action = .refused("CloudDisk is not connected to Drive.")
            return
        }
        action = .working("Moving “\(file.name)” to trash…")
        do {
            _ = try await drive.setTrashed(true, fileID: file.id)
            items.removeAll { $0.id == file.id }
            action = .done("“\(file.name)” is in Drive's trash — empty it there to delete for good.")
        } catch {
            action = .refused("The delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: Handing a file to the rest of the system

    /// Where File Provider keeps this object on the replica volume, or nil when the location is not
    /// mounted. Asked of the system rather than guessed from the folder name.
    func localURL(for file: DriveFile) async -> URL? {
        guard let system = core.services?.cacheSystem else { return nil }
        return await system.userVisibleURL(
            for: ProviderIdentity.identifier(forDriveID: file.id))
    }

    func revealInFinder(_ file: DriveFile) async {
        action = .working("Finding “\(file.name)” in Finder…")
        guard let url = await localURL(for: file) else {
            action = .refused("CloudDisk's Finder location is not mounted, so there is no copy to "
                            + "reveal. Open the location once and try again.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        action = .done("Revealed \(url.lastPathComponent) in Finder.")
    }

    /// Opens with the default app, which is the path that makes File Provider fetch the bytes.
    func openWithDefaultApp(_ file: DriveFile) async {
        action = .working("Opening “\(file.name)”…")
        guard let url = await localURL(for: file) else {
            action = .refused("CloudDisk's Finder location is not mounted, so this file has no path "
                            + "to open. Open the location once and try again.")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            action = .refused("macOS did not open \(url.lastPathComponent). Check that an app is "
                            + "registered for that type.")
            return
        }
        action = .done("Opened \(url.lastPathComponent) — File Provider downloads the bytes as the "
                     + "app reads them.")
    }

    // MARK: Stale-request guard

    private func beginTicket() -> Int {
        ticket += 1
        return ticket
    }

    private func isCurrent(_ me: Int) -> Bool { me == ticket }
}
