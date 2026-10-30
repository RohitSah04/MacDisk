import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns one `AVAssetResourceLoadingDataRequest` into the extent to read from Drive.
///
/// Kept free of AVFoundation types so the arithmetic — the part that can silently play the wrong
/// bytes — is testable on its own.
enum MediaExtent {

    /// The bytes to serve next.
    ///
    /// `provided` is how much of this request AVFoundation already has, which matters because a
    /// request for the end of the resource is answered incrementally and re-asking from
    /// `requestedOffset` would hand the same bytes back forever.
    static func plan(requestedOffset: Int64,
                     requestedLength: Int,
                     asksForAllDataToEnd: Bool,
                     provided: Int64,
                     contentLength: Int64,
                     chunkLength: Int) -> DriveRangeReader.MediaRead? {
        guard contentLength > 0 else { return nil }
        let offset = provided > 0 ? provided : requestedOffset
        guard offset < contentLength else { return nil }
        let available = contentLength - offset

        if asksForAllDataToEnd {
            // `requestedLength` is meaningless here — AVFoundation sets it to NSIntegerMax until the
            // length is known — so serve the remainder in chunks and let the caller loop.
            return DriveRangeReader.MediaRead(offset: offset, length: Int(min(Int64(chunkLength), available)))
        }

        // A zero requested length means "give me something", not "give me nothing". A bounded request
        // is clamped to the same chunk because a player may ask for the whole object at once, and one
        // HTTP range covering 40 GB is neither streamable nor safe to hold in memory.
        let wanted = requestedLength <= 0 ? Int64(chunkLength) : Int64(requestedLength)
        return DriveRangeReader.MediaRead(offset: offset,
                                          length: Int(min(min(wanted, Int64(chunkLength)), available)))
    }

    /// True when AVFoundation has everything it asked for in this request.
    static func isComplete(for request: AVAssetResourceLoadingDataRequest, contentLength: Int64) -> Bool {
        if request.requestsAllDataToEndOfResource { return request.currentOffset >= contentLength }
        return request.currentOffset >= request.requestedOffset + Int64(request.requestedLength)
    }
}

/// Serves a Drive object to `AVPlayer` by byte range, so playback starts before the file exists.
///
/// The asset is addressed through a scheme only this loader answers (`clouddisk-drive://`), which is
/// how AVFoundation is kept away from the network stack it would otherwise use. The caller must retain
/// the loader: `AVAssetResourceLoader` holds its delegate weakly.
public final class DriveAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    private let fileID: String
    /// AVFoundation is told the type as a UTI. A MIME string that is not in its table — and a WAV's
    /// registered one is not — makes it fail with "Cannot Open" before it reads a single byte, so the
    /// identifier `UTType` is what the content information request has to carry.
    private let contentUTI: String?
    private let contentLength: Int64
    private let reader: DriveRangeReader
    private let chunkLength: Int

    private let gate = NSLock()
    private var requests: [ObjectIdentifier: (request: AVAssetResourceLoadingRequest,
                                             task: Task<Void, Never>)] = [:]

    public init(fileID: String, contentLength: Int64, contentType: UTType?,
                reader: DriveRangeReader, chunkLength: Int = 1 << 20) {
        self.fileID = fileID
        self.contentLength = contentLength
        self.contentUTI = contentType?.identifier
        self.reader = reader
        self.chunkLength = max(1 << 14, chunkLength)
    }

    /// A URL that only this loader can resolve. Nothing parses it back into an id — the delegate is
    /// bound to the asset it serves — so the path carries the id for logs and the character set is
    /// filtered instead of escaped.
    public static func streamingURL(for fileID: String) -> URL {
        let safe = String(fileID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return URL(string: "clouddisk-drive://media/" + safe) ?? URL(string: "clouddisk-drive://media")!
    }

    /// Builds the asset and registers the delegate. Both the returned asset and `self` must be kept
    /// alive by the caller.
    public func makeAsset(queue: DispatchQueue = DispatchQueue(
        label: "dev.rohitsah.clouddisk.resource-loader")) -> AVURLAsset {
        let asset = AVURLAsset(url: Self.streamingURL(for: fileID))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest)
        -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentUTI
            information.contentLength = contentLength
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            // A query for metadata only; the byte request follows if the player still wants the media.
            loadingRequest.finishLoading()
            return true
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self, reader] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    guard let plan = MediaExtent.plan(requestedOffset: dataRequest.requestedOffset,
                                                      requestedLength: dataRequest.requestedLength,
                                                      asksForAllDataToEnd: dataRequest.requestsAllDataToEndOfResource,
                                                      provided: dataRequest.currentOffset,
                                                      contentLength: self.contentLength,
                                                      chunkLength: self.chunkLength) else { break }
                    let bytes = try await reader.data(for: plan)
                    if bytes.isEmpty { break }
                    dataRequest.respond(with: bytes)
                    if MediaExtent.isComplete(for: dataRequest, contentLength: self.contentLength) { break }
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: ProviderErrorMapper.bridge(error))
            }
            self.forget(key)
        }

        gate.lock()
        requests[key] = (loadingRequest, task)
        gate.unlock()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        gate.lock()
        let running = requests[ObjectIdentifier(loadingRequest)]?.task
        gate.unlock()
        running?.cancel()
    }

    private func forget(_ key: ObjectIdentifier) {
        gate.lock()
        requests.removeValue(forKey: key)
        gate.unlock()
    }
}
