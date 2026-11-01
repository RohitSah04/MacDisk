import AppKit
import CloudDiskKit
import Combine
import Quartz
import SwiftUI

/// Quick Look inside the app, pointed at the File Provider path for one object.
///
/// The URL is the replica's own path, so the preview reads from the same place Finder's space-bar does.
/// The bytes are fetched before that path is handed over, because Quick Look's helper asks the
/// thumbnailing daemon for a copy of the file rather than reading the replica itself, and the daemon
/// gives up on a dataless item instead of waiting for File Provider to download it — which leaves a
/// document icon where the file should be. Finder waits; CloudDisk waits too.
struct PreviewView: View {
    let file: DriveFile
    let url: URL

    @StateObject private var fetch: PreviewFetch

    init(file: DriveFile, url: URL, offline: OfflineStore) {
        self.file = file
        self.url = url
        _fetch = StateObject(wrappedValue: PreviewFetch(file: file, offline: offline))
    }

    var body: some View {
        Group {
            switch fetch.stage {
            case .fetching:
                ProgressView("Getting “\(file.name)” ready to preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                QuickLookView(url: url)
            case .refused(let problem):
                ContentUnavailableView {
                    Label("Nothing to preview yet", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await fetch.run() }
    }
}

@MainActor
final class PreviewFetch: ObservableObject {
    enum Stage: Equatable {
        case fetching
        case ready
        case refused(String)
    }

    @Published private(set) var stage: Stage = .fetching

    private let file: DriveFile
    private let offline: OfflineStore

    init(file: DriveFile, offline: OfflineStore) {
        self.file = file
        self.offline = offline
    }

    func run() async {
        guard case .fetching = stage else { return }
        if let problem = await offline.downloadForPreview(driveID: file.id,
                                                         declaredBytes: file.byteCount) {
            stage = .refused(problem)
        } else {
            stage = .ready
        }
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    /// The preview view is a subview of a plain container because its initializer is failable: a Quick
    /// Look service that will not start has to leave an explained box, not a crash in the middle of a
    /// sheet the user asked for.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            let note = NSTextField(wrappingLabelWithString: "macOS would not start a Quick Look view, "
                                 + "so \(url.lastPathComponent) cannot be previewed here. Opening it "
                                 + "in its own app still works.")
            note.alignment = .center
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(note)
            NSLayoutConstraint.activate([
                note.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                note.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                note.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            ])
            return container
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        // The default, stated because the alternative is a documented leak: a preview view that is
        // never closed keeps its generator alive after the window goes away.
        preview.shouldCloseWithWindow = true
        preview.autostarts = true
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.preview = preview
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = context.coordinator.preview, context.coordinator.url != url else { return }
        let item = Item(url: url)
        context.coordinator.item = item
        context.coordinator.url = url
        preview.previewItem = item
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The view retains its item and the coordinator retains the same one: a preview whose item is
    /// released while it is still loading shows nothing at all, with no error to report.
    final class Coordinator {
        var preview: QLPreviewView?
        var item: Item?
        var url: URL?
    }

    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        var previewItemTitle: String? { previewItemURL?.lastPathComponent }
        init(url: URL) { previewItemURL = url }
    }
}
