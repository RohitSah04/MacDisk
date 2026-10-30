import CloudDiskKit
import Foundation
import SwiftUI

// The building blocks every CloudDisk screen is assembled from.
//
// They live here rather than inside one view file because the status window, the browser and the
// activity list all need the same card and the same row, and a row whose trailing view is generic is
// the only way the status rows and the file rows keep the same alignment.

struct Card<Content: View>: View {
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

struct Row<Trailing: View>: View {
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

/// Byte counts the way the rest of the system shows them.
///
/// One place, because a cache figure and a file's own size must not be rounded differently: `.file`
/// is the 1000-based style Finder uses, and the inventory's totals are meant to be comparable with
/// what "Get Info" says about the same folder.
enum SizeText {
    static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func bytes(_ count: Int64) -> String { bytes(Optional(count)) }
}

enum DateText {
    /// Absolute, because "2 hours ago" is wrong the moment the window has been open for a day, and a
    /// file listing that lies about when something changed is worse than one that is merely stale.
    static func modified(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension ProviderState.ActivityEvent.Kind {
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
        case .pin: return "Kept offline"
        case .unpin: return "Released offline"
        case .other: return "Recorded"
        }
    }
}

extension ProviderState.ActivityEvent.Outcome {
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
