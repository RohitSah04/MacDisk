import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    /// Set when the body was buffered in memory.
    public let data: Data?
    /// Set when the body was streamed straight to disk.
    public let fileURL: URL?

    public init(statusCode: Int, headers: [String: String], data: Data? = nil, fileURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.fileURL = fileURL
    }

    /// HTTP header names are case-insensitive; URLSession lower-cames them on Apple platforms but
    /// not on others, so look them up defensively.
    public func value(forHeader name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// 206 = the server honoured the Range header. Anything else for a ranged request means the
    /// whole body came back and the caller must not trust its offset arithmetic.
    public var isPartialContent: Bool { statusCode == 206 }
}

/// One seam between CloudDisk and the network, so the whole Drive layer can be tested without
/// touching the internet or Google credentials.
public protocol HTTPTransport: Sendable {
    /// - Parameters:
    ///   - request: fully built request, including headers. Body data may be set for JSON posts.
    ///   - uploadingFile: stream this file as the body instead of `request.httpBody` (large uploads).
    ///   - responseDestination: write the response body to this file instead of buffering it in RAM.
    func send(_ request: URLRequest,
              uploadingFile: URL?,
              writingResponseTo responseDestination: URL?) async throws -> HTTPResponse
}

public extension HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request, uploadingFile: nil, writingResponseTo: nil)
    }

    func send(_ request: URLRequest, uploadingFile: URL?) async throws -> HTTPResponse {
        try await send(request, uploadingFile: uploadingFile, writingResponseTo: nil)
    }

    func send(_ request: URLRequest, writingResponseTo destination: URL?) async throws -> HTTPResponse {
        try await send(request, uploadingFile: nil, writingResponseTo: destination)
    }
}

/// `URLSession`-backed transport used by both the app and the extension.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public static let shared = URLSessionTransport(session: URLSessionTransport.makeSession())

    public static func makeSession(configuration: URLSessionConfiguration = .default) -> URLSession {
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.waitsForConnectivity = true
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest,
                     uploadingFile: URL?,
                     writingResponseTo responseDestination: URL?) async throws -> HTTPResponse {
        do {
            if let uploadingFile {
                return try await sendUpload(request, file: uploadingFile)
            }
            if let responseDestination {
                return try await sendDownload(request, to: responseDestination)
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DriveError.invalidResponse(detail: "expected an HTTP response")
            }
            return HTTPResponse(
                statusCode: http.statusCode,
                headers: Self.headerMap(from: http),
                data: data
            )
        } catch let error as DriveError {
            throw error
        } catch is CancellationError {
            throw DriveError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw DriveError.cancelled }
            throw DriveError.network(detail: error.localizedDescription)
        } catch {
            // Anything else happened on this Mac — a file that could not be written, a handle that
            // could not be closed. Only a `URLError` may be reported as a network failure, because
            // that code tells the system the server is unreachable and takes the whole domain
            // offline, which is the wrong diagnosis for a local one and stops the user from
            // retrying.
            throw error
        }
    }

    private func sendUpload(_ request: URLRequest, file: URL) async throws -> HTTPResponse {
        var uploadRequest = request
        // The body comes from disk; a stale in-memory body would be sent instead.
        uploadRequest.httpBody = nil
        let (data, response) = try await session.upload(for: uploadRequest, fromFile: file)
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse(detail: "expected an HTTP response")
        }
        return HTTPResponse(statusCode: http.statusCode, headers: Self.headerMap(from: http), data: data)
    }

    private func sendDownload(_ request: URLRequest, to destination: URL) async throws -> HTTPResponse {
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DriveError.invalidResponse(detail: "expected an HTTP response")
        }

        // The downloaded file is owned by URLSession and lives outside our container; the
        // destination is not expected to exist yet, so move rather than copy.
        try DownloadedFile.place(from: temporaryURL, to: destination)

        return HTTPResponse(
            statusCode: http.statusCode,
            headers: Self.headerMap(from: http),
            fileURL: destination
        )
    }

    private static func headerMap(from response: HTTPURLResponse) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String {
                map[key] = String(describing: value)
            }
        }
        return map
    }
}

/// Puts the file URLSession wrote into the place CloudDisk asked for.
///
/// `moveItem` will not overwrite, so a destination left behind by an earlier attempt has to go first —
/// and only then. Removing a path that was never created throws, and a throw here would fail a
/// download whose bytes had already arrived intact.
enum DownloadedFile {
    static func place(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

/// Parses the Google API error envelope so `reason` can drive retry decisions.
public struct GoogleAPIErrorPayload: Decodable {
    public struct Inner: Decodable {
        public let code: Int?
        public let message: String?
        public let errors: [Entry]?
    }
    public struct Entry: Decodable {
        public let domain: String?
        public let reason: String?
        public let message: String?
    }
    public let error: Inner?

    public var reason: String? { error?.errors?.first?.reason ?? error?.message }
    public var message: String { error?.message ?? "" }
}

public enum HTTPErrorMapper {
    /// Turns a non-2xx response into a `DriveError`. The body is truncated and never logged: it can
    /// echo request metadata, and the Authorization header must never end up in a diagnostic.
    public static func error(statusCode: Int, body: Data?) -> DriveError {
        var reason: String?
        var message = ""

        if let body, let payload = try? JSONDecoder().decode(GoogleAPIErrorPayload.self, from: body) {
            reason = payload.reason
            message = payload.message
        }

        if message.isEmpty, let body, let text = String(data: body, encoding: .utf8) {
            message = text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
                .description
        }

        if message.isEmpty { message = "no response body" }
        return DriveError.describe(statusCode: statusCode, googleReason: reason, message: message)
    }

    /// `Retry-After` in either the delta-seconds or HTTP-date form.
    public static func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        guard let header = response.value(forHeader: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
