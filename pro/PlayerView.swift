import AVFoundation
import AVKit
import CloudDiskKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Streams one Drive object into the system's player without downloading it first.
///
/// The bytes arrive through `DriveAssetResourceLoader`, which answers AVFoundation's range requests
/// with ranged Drive reads, so playback starts while the object is still mostly on the server and a
/// seek costs one request for the extent asked for. Nothing is written to disk here: the File Provider
/// volume owns cached bytes, and a second copy of the same media would only fight its eviction.
struct PlayerView: View {
    @StateObject private var model: PlayerModel

    init(file: DriveFile, drive: DriveService) {
        _model = StateObject(wrappedValue: PlayerModel(file: file, drive: drive))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                ContentUnavailableView {
                    Label("This file will not play", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = model.player {
                VideoPlayer(player: player)
                    .disabled(!model.isReady)
            } else {
                ProgressView("Asking AVFoundation for the file's first bytes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .task { await model.prepare() }
        .onDisappear { model.tearDown() }
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isReady = false
    @Published private(set) var problem: String?

    /// The asset holds its resource-loader delegate weakly, so whoever builds the asset has to keep the
    /// loader alive for as long as the player can still read from it.
    private let loader: DriveAssetResourceLoader
    private let item: AVPlayerItem
    private var statusCancellable: AnyCancellable?

    init(file: DriveFile, drive: DriveService) {
        let size = file.byteCount ?? 0
        let reader = DriveRangeReader(drive: drive, fileID: file.id, size: size)
        loader = DriveAssetResourceLoader(fileID: file.id,
                                          contentLength: size,
                                          contentType: UTType(mimeType: file.mimeType),
                                          reader: reader)
        item = AVPlayerItem(asset: loader.makeAsset())
        if size <= 0 {
            problem = "Drive reported no size for “\(file.name)”, so there is nothing to seek "
                    + "through. Google-native documents have no downloadable media at all."
        }
    }

    /// Builds the player and follows the item's status until AVFoundation says whether the object can
    /// be read.
    ///
    /// A KVO publisher rather than `await item.status`: `status` on a player item is not an async
    /// property, so an `await` on it returns immediately and the sheet would show an empty player that
    /// has been told nothing. The publisher also keeps reporting after the first answer, which is what
    /// catches an item that fails partway through a seek.
    func prepare() async {
        guard problem == nil, player == nil else { return }
        let item = self.item
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusCancellable = item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.read(status, error: item.error, player: player)
            }
    }

    private func read(_ status: AVPlayerItem.Status, error: Error?, player: AVPlayer) {
        switch status {
        case .readyToPlay:
            isReady = true
            player.play()
        case .failed:
            isReady = false
            problem = "AVFoundation could not play this object: "
                    + (error?.localizedDescription ?? "it stopped without a reason.")
                    + " Playing costs ranged reads of the object itself, so a file Finder can open may "
                    + "simply be a format this Mac does not decode."
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func tearDown() {
        statusCancellable?.cancel()
        statusCancellable = nil
        player?.pause()
    }
}
