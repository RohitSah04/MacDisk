import Foundation
/// Bytes fetched by a ranged request, with the extent actually served.
public struct DriveRangeData: Equatable, Sendable {
    public let data: Data
    public let offset: Int64
    /// Total size of the remote object, parsed from `Content-Range` when available.
    public let totalSize: Int64?
    /// True when the server answered 200 with the whole object instead of honouring `Range`.
    /// Callers must not apply offset arithmetic to such a response.
    public let servedWholeObject: Bool

    public init(data: Data, offset: Int64, totalSize: Int64?, servedWholeObject: Bool) {
        self.data = data
        self.offset = offset
        self.totalSize = totalSize
        self.servedWholeObject = servedWholeObject
    }

    public var length: Int { data.count }
    public var endOffset: Int64 { offset + Int64(data.count) }
}

/// Content transfer for Drive objects: full downloads, byte-range reads, exports, uploads.
public extension DriveService {

    // MARK: Download

    /// Downloads an entire Drive object to `destination`.
    ///
    /// The returned `DriveFile` is the metadata as of this download, which matters: File Provider
    /// requires the item handed back from `fetchContents` to carry the version of the bytes it just
    /// received, and it detects a remote update by comparing.
    func download(fileID: String, to destination: URL,
                  progress: Progress? = nil) async throws -> DriveFile {
        let metadata = try await file(id: fileID)

        if metadata.isFolder {
            throw DriveError.unsupportedItem(detail: "\(fileID) is a folder and has no content")
        }
        if metadata.isGoogleNative {
            // Workspace documents have no media; they only exist through the export endpoint.
            guard let mimeType = GoogleWorkspaceExport.exportMimeType(for: metadata) else {
                throw DriveError.unsupportedItem(detail: "no export format for \(metadata.mimeType)")
            }
            try await export(fileID: fileID, mimeType: mimeType, to: destination, progress: progress)
            return metadata
        }

        let query: [URLQueryItem] = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            // Drive refuses media for files flagged as scanned-abuse unless the caller accepts.
            URLQueryItem(name: "acknowledgeAbuse", value: "true")
        ]
        let url = apiURL(path: "/drive/v3/files/\(encoded(fileID))", query: query)

        _ = try await execute({ token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }, writingResponseTo: destination)

        progress?.completedUnitCount = metadata.byteCount ?? progress?.completedUnitCount ?? 0
        return metadata
    }

    /// Reads one byte range. Used by the streaming engine and by partial materialization.
    ///
    /// Drive honours `Range` on `alt=media` for binary objects and answers 206 with `Content-Range`.
    /// A 200 here means the server sent the whole object, which callers must not treat as a range.
    func downloadRange(fileID: String, offset: Int64, length: Int) async throws -> DriveRangeData {
        guard offset >= 0, length > 0 else {
            throw DriveError.invalidResponse(detail: "invalid range \(offset)+\(length)")
        }
        let lastByte = offset + Int64(length) - 1
        let query: [URLQueryItem] = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "acknowledgeAbuse", value: "true")
        ]
        let url = apiURL(path: "/drive/v3/files/\(encoded(fileID))", query: query)

        let response = try await execute({ token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes \(offset)-\(lastByte)", forHTTPHeaderField: "Range")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }, extraAcceptedStatusCodes: [206])

        guard let data = response.data else {
            throw DriveError.invalidResponse(detail: "range request returned no body")
        }
        return DriveRangeData(
            data: data,
            offset: response.isPartialContent ? offset : 0,
            totalSize: Self.totalSize(fromContentRange: response.value(forHeader: "Content-Range")),
            servedWholeObject: !response.isPartialContent && offset > 0
        )
    }

    // MARK: Export

    /// Converts a Google Workspace document into a real file format.
    func export(fileID: String, mimeType: String, to destination: URL,
               progress: Progress? = nil) async throws {
        let query = [URLQueryItem(name: "mimeType", value: mimeType)]
        let url = apiURL(path: "/drive/v3/files/\(encoded(fileID))/export", query: query)

        _ = try await execute({ token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }, writingResponseTo: destination)

        if let progress, progress.totalUnitCount > 0 {
            progress.completedUnitCount = progress.totalUnitCount
        }
    }

    // MARK: Thumbnails

    /// Fetches Drive's server-side thumbnail.
    ///
    /// This exists so a preview never has to download the original: `thumbnailLink` is generated by
    /// Drive and sized by the `sz` parameter.
    func thumbnailData(for file: DriveFile, maxPixelSize: Int = 512) async throws -> Data? {
        guard let link = file.thumbnailLink, let url = URL(string: link) else { return nil }
        let sized = appendingSize(to: url, maxPixelSize: maxPixelSize)

        let response = try await execute({ token in
            var request = URLRequest(url: sized)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        })
        return response.data
    }

    private func appendingSize(to url: URL, maxPixelSize: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "sz", value: String(maxPixelSize)))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: Upload

    /// Uploads a local file, choosing multipart for small payloads and a resumable session for
    /// larger ones.
    ///
    /// Multipart costs one round trip; resumable costs one per chunk but survives an interrupted
    /// connection, which is the only strategy that can handle a several-gigabyte file honestly.
    enum UploadStrategy: Equatable, Sendable {
        case multipart, resumable

        /// Threshold below which multipart is used.
        public static let multipartLimit: Int64 = 2 * 1024 * 1024

        public static func suited(toByteCount byteCount: Int64) -> UploadStrategy {
            byteCount <= multipartLimit ? .multipart : .resumable
        }
    }

    func upload(fileURL: URL, name: String, parentID: String, mimeType: String?,
                strategy: UploadStrategy? = nil, progress: Progress? = nil) async throws -> DriveFile {
        let byteCount = Self.byteCount(of: fileURL)
        let resolvedStrategy = strategy ?? UploadStrategy.suited(toByteCount: byteCount)
        let detectedMimeType = mimeType ?? Self.guessMimeType(of: fileURL)

        switch resolvedStrategy {
        case .multipart:
            return try await uploadMultipart(fileURL: fileURL, name: name, parentID: parentID,
                                             mimeType: detectedMimeType, byteCount: byteCount,
                                             progress: progress)
        case .resumable:
            return try await uploadResumable(fileURL: fileURL, name: name, parentID: parentID,
                                             mimeType: detectedMimeType, byteCount: byteCount,
                                             progress: progress)
        }
    }

    /// Replaces the content of an existing Drive object, keeping its id.
    func replaceContents(of fileID: String, with fileURL: URL, name: String? = nil,
                         mimeType: String? = nil, progress: Progress? = nil) async throws -> DriveFile {
        let byteCount = Self.byteCount(of: fileURL)
        let metadata: [String: Any] = {
            var value: [String: Any] = [:]
            if let name { value["name"] = name }
            if let mimeType { value["mimeType"] = mimeType }
            return value
        }()

        // Replacing content always goes through a resumable session: the payload may be anything
        // from zero bytes to several gigabytes, and only the session survives an interruption.
        return try await uploadResumable(fileURL: fileURL, name: name, parentID: nil,
                                         mimeType: mimeType, byteCount: byteCount,
                                         progress: progress, existingFileID: fileID,
                                         metadataOverride: metadata)
    }

    // MARK: Multipart

    private func uploadMultipart(fileURL: URL, name: String, parentID: String, mimeType: String,
                                 byteCount: Int64, progress: Progress?) async throws -> DriveFile {
        let metadata: [String: Any] = ["name": name, "parents": [parentID], "mimeType": mimeType]
        let body = try Self.multipartBody(metadata: metadata,
                                          content: Data(contentsOf: fileURL),
                                          mimeType: mimeType)

        let query: [URLQueryItem] = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "enforceSingleParent", value: "true")
        ]
        let url = uploadURL(path: "/drive/v3/files", query: query)

        progress?.totalUnitCount = byteCount
        let response = try await execute({ token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(Self.multipartBoundary)",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        })
        progress?.completedUnitCount = byteCount
        return try decode(DriveFile.self, from: response, context: "files.insert(multipart)")
    }

    static let multipartBoundary = "clouddisk-boundary-\(UUID().uuidString)"

    static func multipartBody(metadata: [String: Any], content: Data,
                              mimeType: String) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [])
        var body = Data()
        body.append("--\(multipartBoundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(json)
        body.append("\r\n--\(multipartBoundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(content)
        body.append("\r\n--\(multipartBoundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // MARK: Resumable

    private func uploadResumable(fileURL: URL, name: String?, parentID: String?, mimeType: String?,
                                 byteCount: Int64, progress: Progress?,
                                 existingFileID: String? = nil,
                                 metadataOverride: [String: Any] = [:]) async throws -> DriveFile {
        var metadata: [String: Any] = metadataOverride
        if metadata["name"] == nil, let name { metadata["name"] = name }
        if let parentID { metadata["parents"] = [parentID] }
        if let mimeType, existingFileID == nil { metadata["mimeType"] = mimeType }

        let sessionURL = try await startResumableSession(metadata: metadata,
                                                          byteCount: byteCount,
                                                          mimeType: mimeType,
                                                          existingFileID: existingFileID)

        var sent: Int64 = 0
        let chunkSize = Self.resumableChunkSize
        progress?.totalUnitCount = byteCount

        // Each PUT is retried individually so a dropped connection resumes from the server's
        // accepted offset instead of re-sending everything.
        while sent < byteCount {
            try Task.checkCancellation()
            let offset = sent
            let length = Int(min(Int64(chunkSize), byteCount - offset))
            let chunk = try Self.readBytes(of: fileURL, offset: offset, count: length)

            switch try await sendResumableChunk(sessionURL: sessionURL, chunk: chunk,
                                                offset: offset, total: byteCount,
                                                progress: progress) {
            case .accepted(let acceptedOffset):
                guard acceptedOffset > offset else {
                    // Google acknowledged the chunk without durably receiving any of it; continuing
                    // would resend the same bytes forever.
                    throw DriveError.invalidResponse(detail: "resumable session made no progress at offset \(offset)")
                }
                sent = acceptedOffset
            case .finalized(let response):
                // Google answers 200/201 as soon as the last byte lands, so the session is already
                // closed and a second finalize PUT on it would be an error.
                return try decode(DriveFile.self, from: response, context: "files.insert(resumable)")
            }
        }

        // byteCount == 0 never enters the loop; the closing PUT below still finalizes it.
        let response = try await finalizeResumable(sessionURL: sessionURL, byteCount: byteCount)
        return try decode(DriveFile.self, from: response, context: "files.insert(resumable)")
    }

    /// Drive requires chunk lengths to be a multiple of 256 KB, except for the final chunk.
    static let resumableChunkSize = 4 * 256 * 1024

    private func startResumableSession(metadata: [String: Any], byteCount: Int64,
                                       mimeType: String?,
                                       existingFileID: String?) async throws -> URL {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: DriveFile.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "enforceSingleParent", value: "true")
        ]
        let path = existingFileID.map { "/drive/v3/files/\(encoded($0))" } ?? "/drive/v3/files"
        let url = uploadURL(path: path, query: query)
        let body = try Self.jsonBody(metadata)

        let response = try await execute({ token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let mimeType {
                request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            }
            request.setValue(String(byteCount), forHTTPHeaderField: "X-Upload-Content-Length")
            if existingFileID != nil {
                // The session was opened against an existing object: the uploads are PATCHes.
                request.setValue("PATCH", forHTTPHeaderField: "X-HTTP-Method-Override")
            }
            request.httpBody = body
            return request
        })

        guard let location = response.value(forHeader: "Location"),
              let sessionURL = URL(string: location) else {
            throw DriveError.invalidResponse(detail: "resumable session returned no Location header")
        }
        return sessionURL
    }

    /// Outcome of one resumable chunk PUT.
    enum ResumableChunkOutcome {
        /// 308: the session accepted bytes up to the given absolute offset and awaits more.
        case accepted(offset: Int64)
        /// 200/201: Google finalised the upload and returned the file resource.
        case finalized(HTTPResponse)
    }

    private func sendResumableChunk(sessionURL: URL, chunk: Data, offset: Int64,
                                    total: Int64, progress: Progress?) async throws -> ResumableChunkOutcome {
        let endInclusive = offset + Int64(chunk.count) - 1
        let response = try await execute({ token in
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes \(offset)-\(endInclusive)/\(total)",
                             forHTTPHeaderField: "Content-Range")
            request.httpBody = chunk
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }, extraAcceptedStatusCodes: [308])

        progress?.completedUnitCount = offset + Int64(chunk.count)

        guard response.statusCode == 308 else {
            return .finalized(response)
        }
        // Google reports what it has durably received; trust that over our own arithmetic.
        return .accepted(offset: Self.acceptedByteCount(fromRangeHeader: response.value(forHeader: "Range"),
                                                        fallback: offset + Int64(chunk.count)))
    }

    private func finalizeResumable(sessionURL: URL, byteCount: Int64) async throws -> HTTPResponse {
        try await execute({ token in
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // An empty final PUT with the full range tells Drive the upload is complete.
            request.setValue("bytes */\(byteCount)", forHTTPHeaderField: "Content-Range")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        })
    }

    // MARK: File helpers

    static func byteCount(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func readBytes(of url: URL, offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(offset))
        return handle.readData(ofLength: count)
    }

    static func guessMimeType(of url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        if #available(macOS 11.0, *) {
            if let type = UTType(filenameExtension: pathExtension) {
                return type.preferredMIMEType ?? "application/octet-stream"
            }
        }
        return "application/octet-stream"
    }

    func encoded(_ fileID: String) -> String {
        fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileID
    }

    static func totalSize(fromContentRange header: String?) -> Int64? {
        guard let header else { return nil }
        // "bytes 0-499/1234"
        guard let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    static func acceptedByteCount(fromRangeHeader header: String?, fallback: Int64) -> Int64 {
        guard let header else { return fallback }
        // "bytes=0-1048575" → 1048576 accepted
        guard let dash = header.firstIndex(of: "-") else { return fallback }
        let tail = header[header.index(after: dash)...]
        let digits = String(tail).filter { $0.isNumber }
        guard let last = Int64(digits) else { return fallback }
        return last + 1
    }
}

import UniformTypeIdentifiers
