import CloudDiskKit
import SwiftUI

/// Everything the File Provider extension has recorded, not only the last dozen lines.
///
/// The log is written by the extension into the shared container, so this screen reads the same file
/// the provider writes and adds nothing of its own: a download that is not in here did not happen.
struct ActivityView: View {
    @ObservedObject var core: AppCore

    @State private var events: [ProviderState.ActivityEvent] = []
    @State private var problem: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(events) { event in
                ActivityRow(event: event)
            }
        }
        .overlay {
            // An overlay, not a row: as a row the empty state sat at the top of an otherwise blank
            // list, which reads as one more entry rather than as the absence of entries.
            if events.isEmpty && problem == nil {
                ContentUnavailableView("Nothing recorded yet",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Downloads, uploads, renames and deletes run "
                                                        + "through the File Provider extension, and it "
                                                        + "writes a line here as it works."))
            }
        }
        .overlay {
            if isLoading { ProgressView().controlSize(.small) }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Read the extension's log again")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let state = core.services?.state else {
            events = []
            problem = "CloudDisk has no shared state to read yet — its configuration is incomplete."
            return
        }
        isLoading = true
        defer { isLoading = false }
        events = await state.recentActivity(limit: 200)
        problem = nil
    }
}

private struct ActivityRow: View {
    let event: ProviderState.ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.outcome.systemImage)
                .foregroundStyle(event.outcome.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.kind.phrase) — \(event.subject)")
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(DateText.relative(event.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
