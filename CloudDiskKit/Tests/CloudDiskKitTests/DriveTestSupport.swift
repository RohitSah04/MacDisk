import Foundation
@testable import CloudDiskKit

/// A script-driven transport: it records every request and answers from a queue.
///
/// This is the seam `HTTPTransport` was designed for. It lets the whole Drive layer — pagination,
/// ranges, resumable sessions, the changes feed, retry and the 401 path — be tested without network
/// access and without Google credentials, which is the only honest way to assert *what request the
/// real API would receive*.
final class StubTransport: HTTPTransport, @unchecked Sendable {

    struct Reply {
        var statusCode: Int
        var headers: [String: String]
        var body: Data?

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            let data = try! JSONSerialization.data(withJSONObject: object)
            var all = ["Content-Type": "application/json; charset=UTF-8"]
            for (key, value) in headers { all[key] = value }
            return Reply(statusCode: status, headers: all, body: data)
        }

        static func text(_ string: String, status: Int = 200,
                         headers: [String: String] = [:]) -> Reply {
            Reply(statusCode: status, headers: headers, body: Data(string.utf8))
        }

        /// The Google error envelope, because `reason` — not the status code — decides retry.
        static func googleError(status: Int, reason: String? = nil, message: String,
                                retryAfter: String? = nil) -> Reply {
            var inner: [String: Any] = ["message": message]
            if let reason {
                inner["errors"] = [["domain": "global", "reason": reason, "message": message]]
            }
            inner["code"] = status
            var headers: [String: String] = [:]
            if let retryAfter { headers["Retry-After"] = retryAfter }
            return .json(["error": inner], status: status, headers: headers)
        }

        static let noContent = Reply(statusCode: 204)
    }

    struct Call {
        let request: URLRequest
        let uploadingFile: URL?
        let writingResponseTo: URL?
    }

    private let lock = NSLock()
    private var script: [Reply]
    private var recorded: [Call] = []

    /// When set, each reply is withheld until this semaphore is signalled.
    ///
    /// Lets a test invalidate an enumerator while its Drive request is genuinely still in flight,
    /// which is the only way to prove the observer is silenced mid-await rather than merely before it
    /// starts. Waited outside the lock, so recorded calls stay visible while a request is parked.
    var holdReply: DispatchSemaphore?

    init(script: [Reply] = []) {
        self.script = script
    }

    func enqueue(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: replies)
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var requestCount: Int { calls.count }

    func requests() -> [URLRequest] { calls.map(\.request) }

    /// `nil` rather than a crash: an out-of-range index is a failing assertion, and aborting the
    /// process here would hide every other test result in the run.
    func request(_ index: Int) -> URLRequest? {
        let all = calls
        guard all.indices.contains(index) else { return nil }
        return all[index].request
    }

    // MARK: Assertions helpers

    func header(_ name: String, at index: Int) -> String? {
        request(index)?.value(forHTTPHeaderField: name)
    }

    func queryItems(at index: Int) -> [String: String] {
        guard let url = request(index)?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var map: [String: String] = [:]
        for item in items { map[item.name] = item.value ?? "" }
        return map
    }

    func path(at index: Int) -> String { request(index)?.url?.path ?? "" }
    func host(at index: Int) -> String { request(index)?.url?.host ?? "" }
    func method(at index: Int) -> String { request(index)?.httpMethod ?? "" }
    func body(at index: Int) -> Data? { request(index)?.httpBody }

    func bodyText(at index: Int) -> String? {
        body(at: index).flatMap { String(data: $0, encoding: .utf8) }
    }

    func jsonObject(at index: Int) -> [String: Any] {
        guard let data = body(at: index),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Decodes the metadata part of a recorded multipart body.
    ///
    /// The content part is arbitrary bytes, which is why the envelope is scanned as data rather
    /// than converted to a string first.
    func multipartMetadata(at index: Int) -> [String: Any] {
        guard let data = body(at: index),
              let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        var depth = 0
        var insideString = false
        var escaped = false
        var start: Int?
        var cursor = headerEnd.upperBound

        while cursor < data.count {
            let byte = data[cursor]
            cursor += 1

            guard let jsonStart = start else {
                if byte == 0x7B { start = cursor - 1; depth = 1 }
                continue
            }
            if escaped { escaped = false; continue }
            if byte == 0x5C { escaped = insideString; continue }
            if byte == 0x22 { insideString.toggle(); continue }
            if insideString { continue }
            if byte == 0x7B { depth += 1 }
            if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    let slice = data.subdata(in: jsonStart..<cursor)
                    return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any] ?? [:]
                }
            }
        }
        return [:]
    }

    // MARK: HTTPTransport

    func send(_ request: URLRequest,
              uploadingFile: URL?,
              writingResponseTo responseDestination: URL?) async throws -> HTTPResponse {
        let reply: Reply = try lock.withLock {
            recorded.append(Call(request: request, uploadingFile: uploadingFile,
                                 writingResponseTo: responseDestination))
            guard !script.isEmpty else {
                throw DriveError.invalidResponse(detail: "StubTransport ran out of scripted responses")
            }
            return script.removeFirst()
        }
        if let hold = holdReply {
            // Bounded, so a forgotten signal fails the test instead of hanging the suite.
            _ = hold.wait(timeout: .now() + 10)
        }

        guard let destination = responseDestination else {
            return HTTPResponse(statusCode: reply.statusCode, headers: reply.headers,
                                data: reply.body)
        }

        // Mirrors URLSessionTransport: the body lands on disk and is not buffered in memory.
        let data = reply.body ?? Data()
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return HTTPResponse(statusCode: reply.statusCode, headers: reply.headers,
                            fileURL: destination)
    }
}

/// The token endpoint without Google.
final class StubTokenExchange: TokenExchanging, @unchecked Sendable {

    enum Outcome {
        case token(String, expiresIn: TimeInterval, scope: String?)
        case failure(DriveError)
    }

    private let lock = NSLock()
    private var script: [Outcome]
    private let fallback: Outcome
    private var count = 0
    private var revocations: [String] = []
    private var seenRefreshTokens: [String] = []
    private var seenClientIDs: [String] = []

    /// Stands in for network latency so concurrent callers can be observed coalescing.
    var delay: TimeInterval = 0

    init(script: [Outcome] = [], fallback: Outcome = .token("fresh-token", expiresIn: 3600,
                                                            scope: nil)) {
        self.script = script
        self.fallback = fallback
    }

    var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var revokeCount: Int { lock.lock(); defer { lock.unlock() }; return revocations.count }
    var recordedRevokedTokens: [String] { lock.lock(); defer { lock.unlock() }; return revocations }
    var recordedRefreshTokens: [String] { lock.lock(); defer { lock.unlock() }; return seenRefreshTokens }
    var recordedClientIDs: [String] { lock.lock(); defer { lock.unlock() }; return seenClientIDs }

    func refresh(refreshToken: String, clientID: String) async throws -> TokenRefreshResult {
        let outcome: Outcome = lock.withLock {
            count += 1
            seenRefreshTokens.append(refreshToken)
            seenClientIDs.append(clientID)
            return script.isEmpty ? fallback : script.removeFirst()
        }
        let latency: TimeInterval = lock.withLock { delay }

        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }

        switch outcome {
        case .token(let accessToken, let expiresIn, let scope):
            return TokenRefreshResult(accessToken: accessToken, expiresIn: expiresIn, scope: scope)
        case .failure(let error):
            throw error
        }
    }

    func revoke(token: String) async {
        lock.withLock { revocations.append(token) }
    }
}

/// JSON shapes Drive returns, built as dictionaries so no test hand-writes escaping.
enum DriveJSON {
    static func file(id: String, name: String, mimeType: String = "text/plain",
                     size: Int64? = nil, version: String? = nil, md5Checksum: String? = nil,
                     parents: [String]? = nil, trashed: Bool? = nil, starred: Bool? = nil,
                     shared: Bool? = nil, ownedByMe: Bool? = nil,
                     modifiedTime: String? = nil, createdTime: String? = nil,
                     exportLinks: [String: String]? = nil, thumbnailLink: String? = nil,
                     shortcutTarget: String? = nil,
                     capabilities: [String: Any]? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "drive#file", "id": id, "name": name, "mimeType": mimeType
        ]
        // The v3 API really does send size as a string.
        if let size { object["size"] = String(size) }
        if let version { object["version"] = version }
        if let md5Checksum { object["md5Checksum"] = md5Checksum }
        if let parents { object["parents"] = parents }
        if let trashed { object["trashed"] = trashed }
        if let starred { object["starred"] = starred }
        if let shared { object["shared"] = shared }
        if let ownedByMe { object["ownedByMe"] = ownedByMe }
        if let modifiedTime { object["modifiedTime"] = modifiedTime }
        if let createdTime { object["createdTime"] = createdTime }
        if let exportLinks { object["exportLinks"] = exportLinks }
        if let thumbnailLink { object["thumbnailLink"] = thumbnailLink }
        if let shortcutTarget {
            object["shortcutDetails"] = ["targetId": shortcutTarget,
                                         "targetMimeType": "text/plain"]
        }
        if let capabilities { object["capabilities"] = capabilities }
        return object
    }

    static func folder(id: String, name: String, parents: [String]? = nil) -> [String: Any] {
        file(id: id, name: name, mimeType: DriveFile.folderMimeType, parents: parents)
    }

    static func page(files: [[String: Any]], nextPageToken: String? = nil,
                     newPageToken: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["kind": "drive#fileList", "files": files]
        if let nextPageToken { object["nextPageToken"] = nextPageToken }
        if let newPageToken { object["newPageToken"] = newPageToken }
        return object
    }

    static func change(fileId: String, file: [String: Any]? = nil,
                       removed: Bool? = nil) -> [String: Any] {
        var object: [String: Any] = ["kind": "drive#change", "fileId": fileId]
        if let file { object["file"] = file }
        if let removed { object["removed"] = removed }
        return object
    }

    static func changesPage(changes: [[String: Any]], nextPageToken: String? = nil,
                            newStartPageToken: String? = nil,
                            removes: Bool? = nil) -> [String: Any] {
        var object: [String: Any] = ["kind": "drive#changeList", "changes": changes]
        if let nextPageToken { object["nextPageToken"] = nextPageToken }
        if let newStartPageToken { object["newStartPageToken"] = newStartPageToken }
        if let removes { object["removes"] = removes }
        return object
    }

    static let emptyPage: [String: Any] = ["kind": "drive#fileList", "files": []]
}

/// Wires a `DriveService` and a `TokenProvider` to the same stubs, which is how both objects are
/// used in the app and the extension.
struct DriveTestEnvironment {

    static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let fastRetry = DriveRetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.004)
    static let noRetry = DriveRetryPolicy(maxAttempts: 1, baseDelay: 0.001, maxDelay: 0.001)

    let service: DriveService
    let tokens: TokenProvider
    let transport: StubTransport
    let exchanger: StubTokenExchange
    let store: InMemoryCredentialStore
    let config: CloudDiskConfig

    static func make(transport: StubTransport,
                     exchanger: StubTokenExchange = StubTokenExchange(),
                     credential: GoogleCredential? = DriveTestEnvironment.credential(),
                     pageSize: Int = 1000,
                     retryPolicy: DriveRetryPolicy = DriveTestEnvironment.fastRetry,
                     now: @escaping @Sendable () -> Date = { DriveTestEnvironment.referenceDate })
        -> DriveTestEnvironment {
        let config = CloudDiskConfig(clientID: "1234567890-test.apps.googleusercontent.com",
                                     keychainAccessGroup: nil)
        let store = InMemoryCredentialStore(credential: credential)
        let tokens = TokenProvider(config: config, store: store, exchanger: exchanger,
                                   transport: transport, now: now)
        let service = DriveService(config: config, tokens: tokens, transport: transport,
                                   pageSize: pageSize, retryPolicy: retryPolicy)
        return DriveTestEnvironment(service: service, tokens: tokens, transport: transport,
                                    exchanger: exchanger, store: store, config: config)
    }

    /// The refresh token is deliberately unlike the access token so a test can prove which one is
    /// ever sent to the token endpoint.
    static func credential(accessToken: String = "cached-access-token",
                           refreshToken: String = "stored-refresh-token",
                           expiresIn: TimeInterval = 3600) -> GoogleCredential {
        GoogleCredential(accessToken: accessToken, refreshToken: refreshToken,
                         tokenExpiration: referenceDate.addingTimeInterval(expiresIn),
                         scope: "https://www.googleapis.com/auth/drive",
                         accountEmail: "user@example.com",
                         accountIdentifier: "account-1",
                         displayName: "Test User")
    }

    /// A credential already inside the refresh window, so the next request must refresh first.
    static func expiringCredential() -> GoogleCredential {
        credential(expiresIn: 30)
    }

    /// A temporary directory that outlives the `defer`-style cleanup tests can forget.
    static func scratchDirectory(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clouddisk-drive-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Content whose byte at offset `n` is `n % 251`, so a test can prove which window of the file
    /// a chunked request actually carried.
    static func deterministicBytes(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count { data.append(UInt8(index % 251)) }
        return data
    }

    static func deterministicByte(at offset: Int) -> UInt8 { UInt8(offset % 251) }

    static func writeFile(_ data: Data, named name: String, in directory: URL) -> URL {
        let url = directory.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }
}
