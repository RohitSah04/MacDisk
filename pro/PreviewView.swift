import AppKit
import Quartz
import SwiftUI

/// Quick Look inside the app, pointed at the File Provider path for one object.
///
/// The URL handed to the preview view is the replica's own path, so a dataless file is materialized by
/// the system as part of the preview — the same route Finder's space-bar takes. Whether a given preview
/// gets partial or full materialization is the system's decision, not CloudDisk's, and that is recorded
/// as a limitation rather than claimed as a feature.
struct PreviewView: View {
    let url: URL

    var body: some View {
        QuickLookView(url: url)
            .frame(minWidth: 520, minHeight: 420)
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
