import CloudDiskKit
import SwiftUI

/// The app's window: three screens over one set of facts.
///
/// `FileBrowser` is created here rather than inside `FilesView` on purpose — the folder the user was
/// standing in belongs to the window, not to whichever sidebar row is selected.
struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case status = "Status"
        case files = "Files"
        case activity = "Activity"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .status: return "checklist"
            case .files: return "folder"
            case .activity: return "clock.arrow.circlepath"
            }
        }

        var caption: String {
            switch self {
            case .status: return "What is set up and what is not"
            case .files: return "Drive, as Drive lists it"
            case .activity: return "What the extension has done"
            }
        }
    }

    @ObservedObject var core: AppCore
    @StateObject private var browser: FileBrowser
    @State private var section: Section = .status

    init(core: AppCore) {
        self.core = core
        _browser = StateObject(wrappedValue: FileBrowser(core: core))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.rawValue, systemImage: item.systemImage)
                        Text(item.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(section.rawValue)
        }
        .task(id: core.isConnected) {
            // Signing in from the status screen is what makes the browser worth listing at all, so the
            // listing follows the account rather than waiting for the user to find Files.
            await browser.reload()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .status: StatusView(core: core)
        case .files: FilesView(core: core, browser: browser)
        case .activity: ActivityView(core: core)
        }
    }
}
