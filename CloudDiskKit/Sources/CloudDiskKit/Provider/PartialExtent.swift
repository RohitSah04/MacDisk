import Foundation

/// The extent a partial materialization request turns into.
///
/// File Provider asks for `[location, length]` and accepts any *aligned* range that covers it: the
/// start must be a multiple of the alignment the system supplies and so must the length, except where
/// the extent stops at the end of the file. Whatever lies outside the returned extent is ignored — the
/// system copies only the extent into the user-visible file and leaves the rest dataless, asking again
/// when a reader touches it. That is the whole point of partial materialization.
struct PartialExtent: Equatable {
    let start: Int64
    let end: Int64
    let itemSize: Int64

    var length: Int64 { end - start }

    /// True when the extent is the object in full, which a plain whole-file download answers.
    var coversWholeItem: Bool { start == 0 && end >= itemSize }

    func covers(_ requested: NSRange) -> Bool {
        let from = Int64(max(0, requested.location))
        let to = requested.length <= 0 ? from : from + Int64(requested.length)
        return start <= from && end >= min(to, itemSize)
    }

    /// Whether this extent is one the system may be handed as the answer to an aligned request.
    ///
    /// Both the start and the length have to sit on the alignment; only an extent that stops at the end
    /// of the object may end mid-block. A shorter answer would mark bytes materialized that were never
    /// fetched, and the next read would be served garbage instead of a download.
    func isAligned(to alignment: Int) -> Bool {
        let block = Int64(max(1, alignment))
        return start % block == 0 && (end >= itemSize || length % block == 0)
    }

    /// Widens the system's minimal range to a legal aligned window inside the object.
    static func aligned(requesting requested: NSRange, alignment: Int, itemSize: Int64) -> PartialExtent {
        guard itemSize > 0 else { return PartialExtent(start: 0, end: 0, itemSize: 0) }
        let block = Int64(max(1, alignment))
        let from = Int64(max(0, requested.location))

        // A range that starts past the end means the object shrank since the system last enumerated
        // it. Full materialization is always a legal answer and the only one that covers such a range.
        if from >= itemSize { return PartialExtent(start: 0, end: itemSize, itemSize: itemSize) }

        let start = from / block * block
        let span = max(0, Int64(requested.length))
        // Bounded this way because `location + length` overflows on the sentinel ranges callers use.
        let requestedEnd = span >= itemSize - from ? itemSize : from + span
        let alignedEnd = (requestedEnd + block - 1) / block * block

        var end = min(alignedEnd, itemSize)
        // An empty request still has to produce something the system can materialize.
        if end <= start { end = min(start + block, itemSize) }
        return PartialExtent(start: start, end: end, itemSize: itemSize)
    }
}

/// Writes the bytes of one extent into the file handed to the system.
enum ExtentFile {

    /// Assembles `destination` so that the extent's bytes sit at the offset the extent names.
    ///
    /// The scratch file from a ranged request already starts at the object's first byte when the
    /// extent begins at 0, so it can be moved into place. Anywhere else the file has to be long
    /// enough to reach the extent's end — the system only ever reads up to that point and ignores
    /// whatever lies outside the reported extent — and the fetched bytes are copied in at their
    /// offset, a megabyte at a time, because an extent is as large as the system asks for.
    static func install(_ extent: PartialExtent, from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)

        let served = Self.byteCount(of: source)
        guard served == extent.length else {
            throw DriveError.invalidResponse(
                detail: "extent asked for \(extent.length) bytes and received \(served)")
        }

        if extent.start == 0 {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DriveError.invalidResponse(detail: "could not create \(destination.lastPathComponent)")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }

            // Extending to `extent.end` is all the skipped region needs. The system copies only the
            // extent it asked for and ignores the rest, so nothing here is ever read back as content —
            // whether APFS keeps the gap an actual hole is an allocation detail, not a correctness one.
            try output.truncate(atOffset: UInt64(extent.end))
            try output.seek(toOffset: UInt64(extent.start))
            var remaining = extent.length
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: Int(min(remaining, Self.chunkSize))),
                      !chunk.isEmpty else {
                    throw DriveError.invalidResponse(detail: "extent ended early")
                }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try output.synchronize()
        } catch let error as DriveError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw DriveError.invalidResponse(detail: "could not place the fetched extent: \(error)")
        }
    }

    private static func byteCount(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return -1 }
        return number.int64Value
    }

    private static let chunkSize: Int64 = 1 << 20
}
