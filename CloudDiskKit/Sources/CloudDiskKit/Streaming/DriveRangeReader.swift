import Foundation

/// Reads extents of a Drive object for a player that is not willing to wait for the whole file.
///
/// This is deliberately *not* a cache of file contents. The File Provider layer already owns
/// materialized bytes on the volume, and a second store of the same data would double disk use and
/// fight the system's eviction. What lives here is one in-memory read-ahead window, because a media
/// reader issues many small sequential requests and one HTTP round trip per 32 KB read would burn the
/// project's Drive quota for the sake of nothing.
public actor DriveRangeReader {

    /// The extent a media reader asked for, after clamping to the object.
    public struct MediaRead: Equatable, Sendable {
        public let offset: Int64
        public let length: Int

        public init(offset: Int64, length: Int) {
            self.offset = offset
            self.length = length
        }

        public var endOffset: Int64 { offset + Int64(length) }
    }

    private let drive: DriveService
    public let fileID: String
    public let size: Int64
    private let readAhead: Int

    /// One window held in memory. `bytes` always starts at `offset` in the object.
    private var windowOffset: Int64 = -1
    private var windowBytes: Data = Data()

    public init(drive: DriveService, fileID: String, size: Int64,
                readAhead: Int = 4 * 1024 * 1024) {
        self.drive = drive
        self.fileID = fileID
        self.size = size
        self.readAhead = max(1, readAhead)
    }

    /// Returns the bytes `[offset, offset+length)`, reading ahead past `length` so the next
    /// sequential request is free.
    public func data(for read: MediaRead) async throws -> Data {
        try await data(offset: read.offset, length: read.length)
    }

    public func data(offset: Int64, length: Int) async throws -> Data {
        guard size > 0 else { return Data() }
        guard offset < size else {
            throw DriveError.invalidResponse(detail: "read at \(offset) past the end of \(fileID)")
        }
        let wanted = min(Int64(max(0, length)), size - offset)
        guard wanted > 0 else { return Data() }

        if windowOffset >= 0, offset >= windowOffset,
           offset + wanted <= windowOffset + Int64(windowBytes.count) {
            let start = Int(offset - windowOffset)
            return windowBytes.subdata(in: start..<(start + Int(wanted)))
        }

        // Start the window on its own boundary so consecutive reads land on the same requests, and
        // make it at least `readAhead` long — never shorter than what the caller asked for.
        let windowStart = alignDown(offset, to: readAhead)
        let windowEnd = min(max(offset + wanted, windowStart + Int64(readAhead)), size)
        let served = try await drive.downloadRange(fileID: fileID, offset: windowStart,
                                                  length: Int(windowEnd - windowStart))

        // A server that ignored `Range` answers 200 with the whole object; the bytes are still usable,
        // but only from where the server says they begin.
        // A `Data` slice keeps its parent's index space, so its `startIndex` is not where its bytes
        // begin; every offset arithmetic below assumes a window that starts at zero.
        windowOffset = served.offset
        windowBytes = Data(served.data)

        guard offset >= windowOffset, offset + wanted <= windowOffset + Int64(windowBytes.count) else {
            windowOffset = -1
            windowBytes = Data()
            throw DriveError.invalidResponse(detail: "Drive did not serve \(offset)+\(wanted) for \(fileID)")
        }
        let from = Int(offset - windowOffset)
        return windowBytes.subdata(in: from..<(from + Int(wanted)))
    }

    /// Drops the in-memory window, for example when the player is torn down.
    public func releaseWindow() {
        windowOffset = -1
        windowBytes = Data()
    }

    private func alignDown(_ value: Int64, to block: Int) -> Int64 {
        let size = Int64(block)
        return value / size * size
    }
}
