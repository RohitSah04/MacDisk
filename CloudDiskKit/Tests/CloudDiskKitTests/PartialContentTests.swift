import XCTest
@testable import CloudDiskKit

/// The arithmetic behind partial materialization and range streaming.
///
/// These are the parts that can be wrong in silence: an extent that does not cover what the system
/// asked for, fetched bytes landed at the wrong offset, or a read plan that hands a player the same
/// bytes forever. File Provider itself is not involved, so every case here is exact.
final class PartialContentTests: XCTestCase {

    private let pageSize = Int64(1 << 20)

    // MARK: - Extent math

    func testAMinimalRangeIsWidenedToTheAlignmentTheSystemAskedFor() {
        let window = PartialExtent.aligned(requesting: NSRange(location: 4_196, length: 500),
                                           alignment: 4_096, itemSize: pageSize)
        XCTAssertEqual(window.start, 4_096, "the start must be a multiple of the alignment")
        XCTAssertEqual(window.end, 8_192, "so must the end, unless it is the end of the file")
        XCTAssertFalse(window.coversWholeItem)
    }

    func testARangeThatRunsPastTheEndIsClampedToTheFileInsteadOfTheAlignment() {
        let window = PartialExtent.aligned(requesting: NSRange(location: Int(pageSize - 100), length: 10_000),
                                           alignment: 4_096, itemSize: pageSize)
        XCTAssertEqual(window.start, pageSize - 4_096)
        XCTAssertEqual(window.end, pageSize, "an extent may only break alignment at the end of the object")
    }

    func testARequestPastTheEndOfTheObjectAnswersWithTheWholeItem() {
        // The file shrank after the system enumerated it; a whole-item answer is the only legal one
        // that still covers the request.
        let window = PartialExtent.aligned(requesting: NSRange(location: 5_000_000, length: 1_024),
                                           alignment: 4_096, itemSize: pageSize)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.end, pageSize)
        XCTAssertTrue(window.coversWholeItem)
    }

    func testAnEmptyOrZeroLengthRequestStillProducesAnExtent() {
        let empty = PartialExtent.aligned(requesting: NSRange(location: 8_192, length: 0),
                                          alignment: 4_096, itemSize: pageSize)
        XCTAssertEqual(empty.start, 8_192)
        XCTAssertEqual(empty.length, 4_096, "no bytes at all would leave the reader stuck")

        let zeroSized = PartialExtent.aligned(requesting: NSRange(location: 0, length: 4_096),
                                              alignment: 4_096, itemSize: 0)
        XCTAssertEqual(zeroSized.start, 0)
        XCTAssertEqual(zeroSized.end, 0)
    }

    func testAnAbsurdAlignmentIsClampedInsteadOfDividingByZero() {
        let window = PartialExtent.aligned(requesting: NSRange(location: 10, length: 10),
                                           alignment: 0, itemSize: pageSize)
        XCTAssertEqual(window.start, 10, "an alignment of nothing means every offset is aligned")
        XCTAssertTrue(window.covers(NSRange(location: 10, length: 10)))
        XCTAssertGreaterThan(window.length, 0)
    }

    func testAnExtentOnlyCountsAsCoveringWhenItHoldsTheWholeRequest() {
        let window = PartialExtent(start: 4_096, end: 8_192, itemSize: pageSize)
        XCTAssertTrue(window.covers(NSRange(location: 4_196, length: 500)))
        XCTAssertFalse(window.covers(NSRange(location: 4_000, length: 100)))
        XCTAssertFalse(window.covers(NSRange(location: 8_000, length: 400)))
        XCTAssertTrue(PartialExtent(start: 4_096, end: 8_192, itemSize: 8_192)
                        .covers(NSRange(location: 8_000, length: 4_000)),
                      "a request running past the end is covered by the end of the file")
    }

    func testAnAnswerThatStopsMidBlockIsNotAnExtentTheSystemMayAccept() {
        XCTAssertTrue(PartialExtent(start: 4_096, end: 8_192, itemSize: pageSize).isAligned(to: 4_096))
        XCTAssertFalse(PartialExtent(start: 4_096, end: 4_196, itemSize: pageSize).isAligned(to: 4_096),
                       "a short answer would mark bytes materialized that were never fetched")
        XCTAssertFalse(PartialExtent(start: 4_000, end: 8_096, itemSize: pageSize).isAligned(to: 4_096),
                       "the start has to sit on the alignment whatever the length does")
        XCTAssertTrue(PartialExtent(start: 4_096, end: 4_196, itemSize: 4_196).isAligned(to: 4_096),
                      "the end of the object is allowed to fall mid-block")
        XCTAssertTrue(PartialExtent(start: 10, end: 20, itemSize: pageSize).isAligned(to: 0),
                      "an alignment of nothing means every offset is legal")
    }

    // MARK: - Extent placement

    private func scratchPair() -> (directory: URL, source: URL, destination: URL) {
        let directory = DriveTestEnvironment.scratchDirectory()
        return (directory,
                directory.appendingPathComponent("extent-source"),
                directory.appendingPathComponent("extent-destination"))
    }

    func testAnExtentPlacedMidFileStopsAtTheExtentEnd() throws {
        let scratch = scratchPair()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let payload = DriveTestEnvironment.deterministicBytes(8_192)
        try payload.write(to: scratch.source)

        // The window the system would hand back: 8_192 bytes that belong at offset 4_096.
        let extent = PartialExtent(start: 4_096, end: 4_096 + Int64(payload.count), itemSize: pageSize)
        try ExtentFile.install(extent, from: scratch.source, to: scratch.destination)

        let written = try Data(contentsOf: scratch.destination)
        XCTAssertEqual(written.count, 12_288,
                       "the file must reach the extent's end and no further — the item is larger")
        XCTAssertEqual(written.subdata(in: 4_096..<12_288), payload,
                       "the fetched bytes belong at the offset the extent names")
    }

    func testAnExtentFromTheFirstByteIsTheFileItself() throws {
        let scratch = scratchPair()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let payload = DriveTestEnvironment.deterministicBytes(4_096)
        try payload.write(to: scratch.source)

        try ExtentFile.install(PartialExtent(start: 0, end: 4_096, itemSize: 4_096),
                               from: scratch.source, to: scratch.destination)
        XCTAssertEqual(try Data(contentsOf: scratch.destination), payload)
    }

    func testAShortExtentIsRefusedAndLeavesNoFileBehind() throws {
        let scratch = scratchPair()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        try DriveTestEnvironment.deterministicBytes(1_000).write(to: scratch.source)

        do {
            try ExtentFile.install(PartialExtent(start: 4_096, end: 8_192, itemSize: pageSize),
                                   from: scratch.source, to: scratch.destination)
            XCTFail("claiming 4_096 bytes that never arrived would materialize garbage")
        } catch let error as DriveError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.destination.path))
    }

    // MARK: Player read planning

    func testARequestForEverythingToEndIsServedInChunksFromWhereThePlayerIs() {
        let plan = MediaExtent.plan(requestedOffset: 512 * 1_024, requestedLength: Int.max,
                                    asksForAllDataToEnd: true, provided: 600 * 1_024,
                                    contentLength: pageSize, chunkLength: 256 * 1_024)
        XCTAssertEqual(plan?.offset, 600 * 1_024, "AVFoundation keeps its own position; re-asking from "
                                                   + "the original offset would stream the same bytes forever")
        XCTAssertEqual(plan?.length, 256 * 1_024)
    }

    func testARequestForTheEndIsClampedToWhatTheObjectHasLeft() {
        let plan = MediaExtent.plan(requestedOffset: pageSize - 10, requestedLength: Int.max,
                                    asksForAllDataToEnd: true, provided: pageSize - 10,
                                    contentLength: pageSize, chunkLength: 256 * 1_024)
        XCTAssertEqual(plan?.length, 10)
    }

    func testACompletedRequestAsksForNothingMore() {
        XCTAssertNil(MediaExtent.plan(requestedOffset: pageSize, requestedLength: 100,
                                      asksForAllDataToEnd: false, provided: 0,
                                      contentLength: pageSize, chunkLength: 100))
        XCTAssertNil(MediaExtent.plan(requestedOffset: 0, requestedLength: 100,
                                      asksForAllDataToEnd: false, provided: 0,
                                      contentLength: 0, chunkLength: 100))
    }

    func testAnUnspecifiedLengthStillFetchesAChunk() {
        let plan = MediaExtent.plan(requestedOffset: 0, requestedLength: 0,
                                    asksForAllDataToEnd: false, provided: 0,
                                    contentLength: pageSize, chunkLength: 64 * 1_024)
        XCTAssertEqual(plan?.length, 64 * 1_024)
    }

    func testABoundedRequestForTheWholeObjectIsStillCutIntoChunks() {
        let plan = MediaExtent.plan(requestedOffset: 0, requestedLength: 100 * 1_024 * 1_024,
                                    asksForAllDataToEnd: false, provided: 0,
                                    contentLength: 200 * 1_024 * 1_024, chunkLength: 256 * 1_024)
        XCTAssertEqual(plan?.length, 256 * 1_024,
                       "a player that asks for the whole 100 MB gets one chunk per request; the "
                     + "delegate loop keeps serving until the request is satisfied")
    }
}

/// Range reads for the player: one request per window, not one per read.
final class RangeReaderTests: XCTestCase {

    private static let fileID = "file000000000000000000000000000001"

    private func make(size: Int, readAhead: Int,
                      script: [StubTransport.Reply]) -> (DriveRangeReader, StubTransport) {
        let transport = StubTransport(script: script)
        let env = DriveTestEnvironment.make(transport: transport)
        let reader = DriveRangeReader(drive: env.service, fileID: Self.fileID, size: Int64(size),
                                      readAhead: readAhead)
        return (reader, transport)
    }

    private func rangeReply(_ bytes: Data, from offset: Int, total: Int) -> StubTransport.Reply {
        StubTransport.Reply(statusCode: 206,
                            headers: ["Content-Type": "application/octet-stream",
                                      "Content-Range": "bytes \(offset)-\(offset + bytes.count - 1)/\(total)"],
                            body: bytes)
    }

    func testSequentialReadsInsideTheWindowCostOneRequest() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(1_048_576)
        let (reader, transport) = make(size: payload.count, readAhead: 65_536, script: [
            rangeReply(payload[0..<65_536], from: 0, total: payload.count),
            rangeReply(payload[65_536..<131_072], from: 65_536, total: payload.count)
        ])

        let first = try await reader.data(offset: 1_000, length: 500)
        let second = try await reader.data(offset: 2_000, length: 500)

        XCTAssertEqual(Array(first), Array(payload[1_000..<1_500]))
        XCTAssertEqual(Array(second), Array(payload[2_000..<2_500]))
        XCTAssertEqual(transport.requestCount, 1, "the read-ahead exists so a player does not pay "
                                                  + "a request per frame")
        XCTAssertEqual(transport.header("Range", at: 0), "bytes 0-65535")
    }

    func testASeekPastTheWindowFetchesTheWindowThatContainsIt() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(1_048_576)
        // The second body is deliberately a slice of the payload, because a slice keeps the parent's
        // index space and a window built from one must still read from its own first byte.
        let (reader, transport) = make(size: payload.count, readAhead: 65_536, script: [
            rangeReply(payload[0..<65_536], from: 0, total: payload.count),
            rangeReply(payload[524_288..<589_824], from: 524_288, total: payload.count)
        ])

        _ = try await reader.data(offset: 0, length: 100)
        let seeked = try await reader.data(offset: 530_000, length: 1_000)

        XCTAssertEqual(Array(seeked), Array(payload[530_000..<531_000]))
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(transport.header("Range", at: 1), "bytes 524288-589823",
                       "a window starts on its own boundary so repeated reads reuse it")
    }

    func testAWindowAtTheEndOfTheFileIsClampedToWhatRemains() async throws {
        let size = 300_000
        let payload = DriveTestEnvironment.deterministicBytes(size)
        let (reader, transport) = make(size: size, readAhead: 65_536, script: [
            rangeReply(payload[262_144..<300_000], from: 262_144, total: size)
        ])

        let tail = try await reader.data(offset: 299_000, length: 5_000)

        XCTAssertEqual(Array(tail), Array(payload[299_000..<300_000]))
        XCTAssertEqual(transport.header("Range", at: 0), "bytes 262144-299999",
                       "asking Drive past the end is a 416, not a shorter answer")
    }

    func testAWholeObjectAnsweredToARangeRequestIsStillReadFromTheRightPlace() async throws {
        let payload = DriveTestEnvironment.deterministicBytes(100_000)
        let transport = StubTransport(script: [
            StubTransport.Reply(statusCode: 200,
                                headers: ["Content-Type": "application/octet-stream"],
                                body: payload)
        ])
        let env = DriveTestEnvironment.make(transport: transport)
        let reader = DriveRangeReader(drive: env.service, fileID: Self.fileID,
                                      size: Int64(payload.count), readAhead: 65_536)

        let bytes = try await reader.data(offset: 50_000, length: 100)
        XCTAssertEqual(Array(bytes), Array(payload[50_000..<50_100]))
    }

    func testAReadPastTheEndIsAnErrorRatherThanEmptyBytes() async throws {
        let (reader, _) = make(size: 1_000, readAhead: 512, script: [])
        do {
            _ = try await reader.data(offset: 5_000, length: 10)
            XCTFail("a silent empty answer would end the stream without saying why")
        } catch let error as DriveError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testARefusedRangeIsReportedAndLeavesNoPartialWindow() async throws {
        let (reader, transport) = make(size: 1_000_000, readAhead: 512, script: [
            .googleError(status: 404, reason: "notFound", message: "Gone")
        ])
        do {
            _ = try await reader.data(offset: 0, length: 100)
            XCTFail("the failure must reach the player")
        } catch let error as DriveError {
            guard case .itemNotFound = error else {
                return XCTFail("expected itemNotFound, got \(error)")
            }
        }
        XCTAssertEqual(transport.requestCount, 1)
    }
}
