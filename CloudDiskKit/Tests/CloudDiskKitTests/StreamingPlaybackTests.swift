import AVFoundation
import Foundation
import UniformTypeIdentifiers
@testable import CloudDiskKit
import XCTest

/// Streams a Drive object to AVFoundation and checks that a real player can use it.
///
/// The object here is an actual WAV file written by this test, and the only way AVFoundation gets its
/// bytes is through `DriveAssetResourceLoader` answering ranged requests. That makes this the playback
/// proof the rest of the suite cannot offer: parsed duration, decoded samples from a seek position, and
/// a failure that reaches the player instead of hanging it. Drive itself is replaced by a transport that
/// answers `Range` the way its media endpoint does — `LiveDriveSmokeTests` covers the real endpoint.
final class StreamingPlaybackTests: XCTestCase {

    private static let fileID = "file00000000000000000000000000009"
    private static let sampleRate: Double = 8_000
    private static let seconds: Double = 10
    /// The loader floors its chunk at 16 KiB, so that is the biggest window one Drive request may carry.
    private static let chunkLength = 1 << 14

    // MARK: The object

    /// The sample at a frame, chosen so a decoded buffer says which part of the object it came from.
    private static func sample(at frame: Int) -> Int16 { Int16(frame % 20_000) }

    /// 16-bit mono PCM in a WAV container, sizes filled in so the parser never has to guess the length.
    private static func wavObject(frames: Int) -> Data {
        var out = Data()
        func ascii(_ text: String) { out.append(contentsOf: text.utf8) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                out.append(UInt8((value >> shift) & 0xFF))
            }
        }
        func u16(_ value: UInt16) {
            for shift in [0, 8] { out.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        }

        let dataSize = frames * 2
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        for frame in 0..<frames { u16(UInt16(bitPattern: sample(at: frame))) }
        return out
    }

    // MARK: Transport that behaves like the media endpoint

    /// Answers `Range` with 206 + `Content-Range`, or refuses everything with one status.
    private final class MediaEndpoint: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let object: Data
        private let refusal: Int?
        private var _ranges: [String] = []

        init(object: Data, refusal: Int? = nil) {
            self.object = object
            self.refusal = refusal
        }

        var ranges: [String] { lock.withLock { _ranges } }

        /// The size of each window served, in request order.
        var windowLengths: [Int] {
            ranges.map { header in
                let window = Self.parse(header)
                let through = min(window.upperBound, object.count - 1)
                return through - min(window.lowerBound, object.count - 1) + 1
            }
        }

        /// Where each served window starts, so a test can see whether a seek reached the object at its
        /// own offset instead of only walking from the front.
        var windowStarts: [Int] { ranges.map { Self.parse($0).lowerBound } }

        func send(_ request: URLRequest, uploadingFile: URL?,
                  writingResponseTo destination: URL?) async throws -> HTTPResponse {
            guard refusal == nil else {
                return HTTPResponse(statusCode: refusal ?? 404,
                                    headers: ["Content-Type": "application/json"],
                                    data: Data(#"{"error":{"code":404,"message":"gone"}}"#.utf8))
            }
            let header = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-\(object.count - 1)"
            let window = Self.parse(header)
            let from = min(window.lowerBound, object.count - 1)
            let through = min(window.upperBound, object.count - 1)
            let body = Data(object[from...through])
            lock.withLock { _ranges.append(header) }
            let headers = ["Content-Type": "audio/wav",
                           "Content-Range": "bytes \(from)-\(through)/\(object.count)"]
            if let destination {
                try? FileManager.default.removeItem(at: destination)
                try body.write(to: destination, options: .atomic)
                return HTTPResponse(statusCode: 206, headers: headers, fileURL: destination)
            }
            return HTTPResponse(statusCode: 206, headers: headers, data: body)
        }

        /// `bytes 100-199`, the only form `DriveAssetResourceLoader` produces.
        private static func parse(_ header: String) -> (lowerBound: Int, upperBound: Int) {
            let body = header.replacingOccurrences(of: "bytes=", with: "")
                              .replacingOccurrences(of: "bytes ", with: "")
            let parts = body.split(separator: "-")
            guard parts.count == 2, let lower = Int(parts[0]) else { return (0, 0) }
            return (lower, Int(parts[1]) ?? Int.max)
        }
    }

    // MARK: Harness

    /// The type handed to AVFoundation. It has to be a UTI: a MIME string outside Apple's table makes
    /// the asset fail as "Cannot Open" before a single byte is read.
    private static let wavType = UTType(filenameExtension: "wav")

    private func makeLoader(object: Data, endpoint: HTTPTransport,
                            chunkLength: Int = StreamingPlaybackTests.chunkLength) -> DriveAssetResourceLoader {
        XCTAssertNotNil(Self.wavType, "this machine does not know what a WAV file is")
        let config = CloudDiskConfig(clientID: "1234567890-test.apps.googleusercontent.com",
                                     keychainAccessGroup: nil)
        let tokens = TokenProvider(config: config,
                                   store: InMemoryCredentialStore(credential: DriveTestEnvironment.credential()),
                                   exchanger: StubTokenExchange(), transport: endpoint)
        let drive = DriveService(config: config, tokens: tokens, transport: endpoint,
                                 pageSize: 1_000, retryPolicy: DriveTestEnvironment.fastRetry)
        let reader = DriveRangeReader(drive: drive, fileID: Self.fileID,
                                      size: Int64(object.count), readAhead: chunkLength)
        return DriveAssetResourceLoader(fileID: Self.fileID, contentLength: Int64(object.count),
                                        contentType: Self.wavType, reader: reader,
                                        chunkLength: chunkLength)
    }

    /// Waits for AVFoundation to finish what it asked the loader for.
    private func settle(_ item: AVPlayerItem, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Tests

    func testAPlayerBecomesReadyToPlayFromRangeReadsAlone() async throws {
        let object = Self.wavObject(frames: Int(Self.sampleRate * Self.seconds))
        let endpoint = MediaEndpoint(object: object)
        let loader = makeLoader(object: object, endpoint: endpoint)
        let item = AVPlayerItem(asset: loader.makeAsset())
        let player = AVPlayer(playerItem: item)
        defer { player.pause() }

        await settle(item)

        XCTAssertEqual(item.status, .readyToPlay,
                       "the loader never satisfied AVFoundation: \(item.error?.localizedDescription ?? "no error")")
        XCTAssertEqual(CMTimeGetSeconds(item.duration), Self.seconds, accuracy: 0.05,
                       "the duration comes from the bytes served, not from a metadata call")
        XCTAssertFalse(endpoint.ranges.isEmpty)
        XCTAssertTrue(endpoint.ranges.allSatisfy { $0.hasPrefix("bytes ") },
                      "every media read CloudDisk makes is ranged, so a stream never downloads the file")
        // A window is the chunk plus whatever the read-ahead rounded its start down by, so two chunks
        // is the most that any single media request can carry.
        XCTAssertLessThanOrEqual(endpoint.windowLengths.max() ?? 0, 2 * Self.chunkLength,
                      "one request never transfers more than a window, which is what keeps a 40 GB "
                    + "video from being pulled whole by a single read")
    }

    func testASampleAtPlaytimeCarriesTheBytesFromThatPosition() async throws {
        let object = Self.wavObject(frames: Int(Self.sampleRate * Self.seconds))
        let endpoint = MediaEndpoint(object: object)
        let loader = makeLoader(object: object, endpoint: endpoint)
        let asset = loader.makeAsset()
        let reader = try AVAssetReader(asset: asset)
        let timescale = Int32(Self.sampleRate)
        let start = CMTime(seconds: 4, preferredTimescale: timescale)
        reader.timeRange = CMTimeRange(start: start,
                                       duration: CMTime(seconds: 0.25, preferredTimescale: timescale))

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first,
                                  "AVFoundation did not find the audio track in the streamed bytes")
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                             AVLinearPCMBitDepthKey: 16,
                             AVLinearPCMIsFloatKey: false,
                             AVLinearPCMIsBigEndianKey: false,
                             AVLinearPCMIsNonInterleaved: false,
                             AVNumberOfChannelsKey: 1])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "reader failed: \(reader.error?.localizedDescription ?? "none")")

        var firstFrame: Int16?
        var framesRead = 0
        while let buffer = output.copyNextSampleBuffer(), buffer.numSamples > 0 {
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Int16](repeating: 0, count: length / 2)
            let copied = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count,
                                           destination: raw.baseAddress!)
            }
            guard copied == noErr else { continue }
            if firstFrame == nil { firstFrame = bytes.first }
            framesRead += bytes.count
        }
        XCTAssertNotNil(firstFrame)
        XCTAssertEqual(framesRead, Int(0.25 * Self.sampleRate), accuracy: 8,
                       "a quarter second of audio is a quarter second of samples")
        XCTAssertEqual(firstFrame, Self.sample(at: Int(4 * Self.sampleRate)),
                       "decoding from 4 s must read the bytes at 4 s, not from the start")
        // 44 bytes of WAV header, then two bytes per frame: the frame at 4 s sits at this offset.
        let seekByte = 44 + Int(4 * Self.sampleRate) * 2
        XCTAssertTrue(endpoint.windowStarts.contains { $0 <= seekByte && seekByte < $0 + Self.chunkLength },
                      "a window was fetched around the seek position rather than only from the front")
    }

    func testARefusedObjectFailsThePlayerRatherThanHangingIt() async throws {
        let object = Self.wavObject(frames: 4_000)
        let endpoint = MediaEndpoint(object: object, refusal: 404)
        let loader = makeLoader(object: object, endpoint: endpoint)
        let item = AVPlayerItem(asset: loader.makeAsset())
        let player = AVPlayer(playerItem: item)
        defer { player.pause() }

        await settle(item)

        XCTAssertEqual(item.status, .failed,
                       "a Drive error has to surface as a failed item, not an endless spinner")
        XCTAssertNotNil(item.error)
    }
}
