import Foundation

/// Google Drive REST v3 — metadata surface.
///
/// Content transfer (download/range/upload) lives in `DriveService+Transfer.swift` so the two
/// concerns can be tested independently.
public struct DriveService: Sendable {

    public let config: CloudDiskConfig
    public let tokens: TokenProvider
    let transport: HTTPTransport
    let retryPolicy: DriveRetryPolicy
    public let pageSize: Int

    public init(config: CloudDiskConfig,
                tokens: TokenProvider,
                transport: HTTPTransport = URLSessionTransport.shared,
                pageSize: Int = 1000,
                retryPolicy: DriveRetryPolicy = .standard) {
        self.config = config
        self.tokens = tokens
        self.transport = transport
        self.pageSize = max(1, min(pageSize, 1000))
        self.retryPolicy = retryPolicy
    }

    // MARK: Request plumbing

    func apiURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            // Every input here is a compile-time path plus percent-encoded items.
            preconditionFailure("CloudDisk built an invalid Drive URL for \(path)")
        }
        return url
    }

    func uploadURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/upload" + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func jsonRequest(method: String, url: URL, body: Data?,
                             headers: [String: String] = [:]) -> @Sendable (String) -> URLRequest {
        { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let body {
                request.httpBody = body
                request.setValue("application/json; charset=UTF-8",
                                 forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return request
        }
    }

    /// Executes one request with retry, then maps a non-success status onto `DriveError`.
    ///
    /// - Parameter extraAcceptedStatusCodes: non-2xx statuses that mean "keep going" for a specific
    ///   flow — 206 for a range fetch, 308 for an incomplete resumable upload session.
    func execute(_ makeRequest: @escaping @Sendable (String) -> URLRequest,
                 uploadingFile: URL? = nil,
                 writingResponseTo destination: URL? = nil,
                 extraAcceptedStatusCodes: [Int] = []) async throws -> HTTPResponse {
        try await RetryRunner.run(policy: retryPolicy) { [tokens] in
            let response = try await tokens.authorizedSend(makeRequest,
                                                           uploadingFile: uploadingFile,
                                                           writingResponseTo: destination)
            if !response.isSuccess && !extraAcceptedStatusCodes.contains(response.statusCode) {
                var error = HTTPErrorMapper.error(statusCode: response.statusCode,
                                                  body: response.data)
                if case .rateLimited = error {
                    error = .rateLimited(retryAfter: HTTPErrorMapper.retryAfter(from: response))
                }
                throw error
            }
            return response
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse,
                                      context: String) throws -> T {
        guard let data = response.data else {
            throw DriveError.invalidResponse(detail: "\(context): empty response body")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DriveError.invalidResponse(detail: "\(context): \(error.localizedDescription)")
        }
    }

    // MARK: Listing

    public func childrenPage(parentID: String, pageToken: String? = nil,
                             includeTrashed: Bool = false) async throws -> DriveChildrenPage {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: try DriveQuery.children(of: parentID,
                                                                   includeTrashed: includeTrashed)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: "folder,name"),
            URLQueryItem(name: "fields", value: DriveFile.listFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let response = try await execute(jsonRequest(method: "GET",
                                                     url: apiURL(path: "/drive/v3/files", query: query),
                                                     body: nil))
        return try decode(DriveChildrenPage.self, from: response, context: "files.list")
    }

    /// Every child of a folder, following `nextPageToken` until exhausted.
    ///
    /// The prototype decoded `nextPageToken` and then threw it away, silently truncating any folder
    /// with more than one page of children.
    public func allChildren(parentID: String, limit: Int = 100_000) async throws -> [DriveFile] {
        var collected: [DriveFile] = []
        var pageToken: String?

        while true {
            let page = try await childrenPage(parentID: parentID, pageToken: pageToken)
            collected.append(contentsOf: page.fileList)
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            if collected.count >= limit { break }
            try Task.checkCancellation()
            pageToken = next
        }

        return collected
    }

    public func trashedPage(pageToken: String? = nil) async throws -> DriveChildrenPage {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: "trashed = true"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "fields", value: DriveFile.listFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let response = try await execute(jsonRequest(method: "GET",
                                                     url: apiURL(path: "/drive/v3/files", query: query),
                                                     body: nil))
        return try decode(DriveChildrenPage.self, from: response, context: "files.list(trashed)")
    }

    public func search(query text: String, parentID: String?) async throws -> [DriveFile] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: try DriveQuery.nameContains(text, in: parentID)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: DriveFile.listFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        query.append(URLQueryItem(name: "orderBy", value: "modifiedTime desc"))

        let response = try await execute(jsonRequest(method: "GET",
                                                     url: apiURL(path: "/drive/v3/files", query: query),
                                                     body: nil))
        let page: DriveChildrenPage = try decode(DriveChildrenPage.self, from: response,
                                                 context: "files.list(search)")
        return page.fileList
    }

    public func recentlyModified(limit: Int = 20) async throws -> [DriveFile] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "pageSize", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "fields", value: DriveFile.listFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        let response = try await execute(jsonRequest(method: "GET",
                                                     url: apiURL(path: "/drive/v3/files", query: query),
                                                     body: nil))
        let page: DriveChildrenPage = try decode(DriveChildrenPage.self, from: response,
                                                 context: "files.list(recent)")
        return page.fileList
    }

    /// Objects in `parentID` whose name is exactly `name`, folder first.
    ///
    /// Used when the system reimports an on-disk file after a restart: the extension has to decide
    /// whether the disk copy is a server object it already knows, and a name lookup is the cheapest
    /// check that does not require a full Drive scan. Drive matches `name =` case-insensitively,
    /// which lines up with the case-insensitive HFS+/APFS volumes File Provider replicates onto.
    public func exactMatches(named name: String, in parentID: String) async throws -> [DriveFile] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: try DriveQuery.nameExactly(name, in: parentID)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: DriveFile.listFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "GET",
            url: apiURL(path: "/drive/v3/files", query: query),
            body: nil))
        let page: DriveChildrenPage = try decode(DriveChildrenPage.self, from: response,
                                                 context: "files.list(exact-name)")
        return page.fileList
    }

    public func file(id: String) async throws -> DriveFile {
        try await file(id: id, fields: DriveFile.fields)
    }

    public func file(id: String, fields: String) async throws -> DriveFile {
        guard DriveQuery.isValidIdentifier(id) else {
            throw DriveError.itemNotFound(id: id)
        }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "GET",
            url: apiURL(path: "/drive/v3/files/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)",
                        query: query),
            body: nil
        ))
        return try decode(DriveFile.self, from: response, context: "files.get(\(id))")
    }

    // MARK: Mutations

    public func createFolder(name: String, parentID: String) async throws -> DriveFile {
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": DriveFile.folderMimeType,
            "parents": [parentID]
        ]
        let body = try Self.jsonBody(metadata)
        let query: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            // File Provider cannot represent an item under two parents, so every folder we create
            // is single-parent by construction.
            URLQueryItem(name: "enforceSingleParent", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "POST",
            url: apiURL(path: "/drive/v3/files", query: query),
            body: body
        ))
        return try decode(DriveFile.self, from: response, context: "files.create(folder)")
    }

    public func rename(fileID: String, to newName: String) async throws -> DriveFile {
        try await patch(fileID: fileID, metadata: ["name": newName])
    }

    public func move(fileID: String, from oldParentID: String, to newParentID: String) async throws -> DriveFile {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "addParents", value: newParentID),
            URLQueryItem(name: "removeParents", value: oldParentID),
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "enforceSingleParent", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "PATCH",
            url: apiURL(path: "/drive/v3/files/\(fileID)", query: query),
            body: Data("{}".utf8)
        ))
        return try decode(DriveFile.self, from: response, context: "files.update(move)")
    }

    public func copy(fileID: String, toParentID parentID: String, name: String?) async throws -> DriveFile {
        var metadata: [String: Any] = ["parents": [parentID]]
        if let name { metadata["name"] = name }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "enforceSingleParent", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "POST",
            url: apiURL(path: "/drive/v3/files/\(fileID)/copy", query: query),
            body: try Self.jsonBody(metadata)
        ))
        return try decode(DriveFile.self, from: response, context: "files.copy")
    }

    /// Moves a Drive object to the trash, or removes it for good when it is already trashed.
    ///
    /// Drive's `files.delete` is a *permanent* delete, so it must never be the first thing a Finder
    /// "Move to Trash" reaches. The trashed flag is checked rather than assumed, because an item the
    /// user deletes a second time — from CloudDisk's Trash folder — is exactly the case where
    /// permanent removal is what was asked for.
    public func delete(fileID: String) async throws {
        let state = try await file(id: fileID, fields: "id,trashed")
        if state.isTrashed {
            try await deletePermanently(fileID: fileID)
        } else {
            _ = try await setTrashed(true, fileID: fileID)
        }
    }

    /// The raw `trashed` flag write. `delete(fileID:)` is the operation a user expects; this is the
    /// primitive it is built from.
    public func setTrashed(_ trashed: Bool, fileID: String) async throws -> DriveFile {
        try await patch(fileID: fileID, metadata: ["trashed": trashed])
    }

    public func deletePermanently(fileID: String) async throws {
        let query = [URLQueryItem(name: "supportsAllDrives", value: "true")]
        _ = try await execute(jsonRequest(
            method: "DELETE",
            url: apiURL(path: "/drive/v3/files/\(fileID)", query: query),
            body: nil
        ))
    }

    @discardableResult
    public func patch(fileID: String, metadata: [String: Any]) async throws -> DriveFile {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "keepRevisionInTime", value: "false")
        ]
        let response = try await execute(jsonRequest(
            method: "PATCH",
            url: apiURL(path: "/drive/v3/files/\(fileID)", query: query),
            body: try Self.jsonBody(metadata)
        ))
        return try decode(DriveFile.self, from: response, context: "files.update")
    }

    /// Conflict check used before any destructive write.
    ///
    /// The system hands the extension the `contentVersion` it believes is current; if Drive
    /// disagrees, the file changed remotely since it was enumerated, and overwriting it would
    /// lose data. Returning a conflict lets File Provider present both versions.
    public func assertContentUnchanged(fileID: String, baseContentVersion: Data?) async throws -> DriveFile {
        let current = try await file(id: fileID)
        guard let baseContentVersion else { return current }
        let expected = String(data: baseContentVersion, encoding: .utf8)
        guard let expected, expected != current.contentVersionToken else {
            return current
        }
        throw DriveError.conflict(detail: "\(fileID) changed remotely (expected \(expected.prefix(12)), found \(current.contentVersionToken.prefix(12)))")
    }

    // MARK: Changes feed

    public func startChangeToken() async throws -> String {
        let query = [URLQueryItem(name: "supportsAllDrives", value: "true")]
        let response = try await execute(jsonRequest(
            method: "GET",
            url: apiURL(path: "/drive/v3/changes/startPageToken", query: query),
            body: nil
        ))
        struct Token: Decodable { let startPageToken: String }
        let decoded: Token = try decode(Token.self, from: response, context: "changes.startPageToken")
        return decoded.startPageToken
    }

    public func changePage(from pageToken: String) async throws -> DriveChangesPage {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: DriveFile.changesFields),
            URLQueryItem(name: "includeCorpusTrashes", value: "true"),
            URLQueryItem(name: "includeRemovedEntries", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        let response = try await execute(jsonRequest(
            method: "GET",
            url: apiURL(path: "/drive/v3/changes", query: query),
            body: nil
        ))
        return try decode(DriveChangesPage.self, from: response, context: "changes.list")
    }

    /// Drains the changes feed from `pageToken` and returns the terminal `newStartPageToken`, which
    /// is what CloudDisk persists as its sync anchor.
    public func collectChanges(from pageToken: String,
                              maxPages: Int = 50) async throws -> DriveChangeBatch {
        var changes: [DriveChange] = []
        var cursor = pageToken
        var newStart: String?
        var pagesRead = 0

        while true {
            let page = try await changePage(from: cursor)
            changes.append(contentsOf: page.changeList)
            newStart = page.newStartPageToken ?? newStart
            pagesRead += 1

            guard let next = page.nextPageToken, !next.isEmpty else { break }
            if pagesRead >= maxPages {
                // `next` is itself a valid changes pageToken, so the caller can resume from it and
                // still make forward progress instead of losing everything drained so far.
                return DriveChangeBatch(changes: changes, startPageToken: nil, resumeToken: next,
                                        removedEverything: page.removes ?? false,
                                        truncated: true)
            }
            try Task.checkCancellation()
            cursor = next
        }

        guard let newStart else {
            throw DriveError.invalidResponse(detail: "changes feed returned no newStartPageToken")
        }
        return DriveChangeBatch(changes: changes, startPageToken: newStart, resumeToken: nil,
                                removedEverything: false, truncated: false)
    }

    // MARK: Account

    public func about() async throws -> DriveAbout {
        let query = [URLQueryItem(name: "fields", value: DriveAbout.fields)]
        let response = try await execute(jsonRequest(
            method: "GET",
            url: apiURL(path: "/drive/v3/about", query: query),
            body: nil
        ))
        return try decode(DriveAbout.self, from: response, context: "about.get")
    }

    // MARK: Helpers

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func queryItems(_ pairs: [String: String]) -> [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

public struct DriveChangeBatch: Equatable, Sendable {
    public let changes: [DriveChange]
    /// Non-nil only when the feed was drained to the end.
    public let startPageToken: String?
    /// Token to resume from when `truncated` is true.
    public let resumeToken: String?
    public let removedEverything: Bool
    /// True when `maxPages` stopped the drain; the cursor is not yet current.
    public let truncated: Bool

    public init(changes: [DriveChange], startPageToken: String?, resumeToken: String?,
                removedEverything: Bool, truncated: Bool) {
        self.changes = changes
        self.startPageToken = startPageToken
        self.resumeToken = resumeToken
        self.removedEverything = removedEverything
        self.truncated = truncated
    }
}
