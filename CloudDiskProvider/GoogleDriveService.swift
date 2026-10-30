
import Foundation

// MARK: - Google Drive File Model

struct GoogleDriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let parents: [String]?

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }
}

// MARK: - Google Drive API Response

private struct GoogleDriveListResponse: Decodable {
    let files: [GoogleDriveFile]
    let nextPageToken: String?
}

// MARK: - Google Drive Service

enum GoogleDriveService {

    private static let appGroup =
        "group.dev.rohitsah.clouddisk"

    private static let tokenKey =
        "GoogleDriveAccessToken"

    private static let baseURL =
        "https://www.googleapis.com/drive/v3"

    // MARK: - Read Shared Access Token

    static func accessToken() throws -> String {

        guard let defaults = UserDefaults(
            suiteName: appGroup
        ) else {
            throw DriveError.appGroupUnavailable
        }

        guard let token = defaults.string(
            forKey: tokenKey
        ), !token.isEmpty else {
            throw DriveError.tokenNotFound
        }

        return token
    }

    // MARK: - List Files and Folders

    static func listFiles(
        in parentIdentifier: String
    ) async throws -> [GoogleDriveFile] {

        let token = try accessToken()

        var components = URLComponents(
            string: "\(baseURL)/files"
        )!

        let parentQuery: String

        if parentIdentifier == "root" {
            parentQuery = "'root' in parents"
        } else {
            parentQuery = "'\(parentIdentifier)' in parents"
        }

        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "\(parentQuery) and trashed = false"
            ),
            URLQueryItem(
                name: "pageSize",
                value: "1000"
            ),
            URLQueryItem(
                name: "orderBy",
                value: "folder,name"
            ),
            URLQueryItem(
                name: "fields",
                value: "files(id,name,mimeType,size,modifiedTime,parents),nextPageToken"
            ),
            URLQueryItem(
                name: "supportsAllDrives",
                value: "true"
            ),
            URLQueryItem(
                name: "includeItemsFromAllDrives",
                value: "true"
            )
        ]

        guard let url = components.url else {
            throw DriveError.invalidURL
        }

        var request = URLRequest(url: url)

        request.httpMethod = "GET"

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {

            let message = String(
                data: data,
                encoding: .utf8
            ) ?? "Unknown Google Drive API error"

            throw DriveError.apiError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let result = try JSONDecoder().decode(
            GoogleDriveListResponse.self,
            from: data
        )

        return result.files
    }

    // MARK: - Get Individual File Details

    static func getFile(
        id: String
    ) async throws -> GoogleDriveFile {

        let token = try accessToken()

        guard let encodedID = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else {
            throw DriveError.invalidURL
        }

        guard let url = URL(
            string: "\(baseURL)/files/\(encodedID)?fields=id,name,mimeType,size,modifiedTime,parents"
        ) else {
            throw DriveError.invalidURL
        }

        var request = URLRequest(url: url)

        request.httpMethod = "GET"

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {

            let message = String(
                data: data,
                encoding: .utf8
            ) ?? "Unknown Google Drive API error"

            throw DriveError.apiError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        return try JSONDecoder().decode(
            GoogleDriveFile.self,
            from: data
        )
    }
}

// MARK: - Google Drive Errors

enum DriveError: LocalizedError {

    case appGroupUnavailable
    case tokenNotFound
    case invalidURL
    case invalidResponse
    case apiError(
        statusCode: Int,
        message: String
    )

    var errorDescription: String? {

        switch self {

        case .appGroupUnavailable:
            return "CloudDisk could not access its shared App Group."

        case .tokenNotFound:
            return "Google access token not found. Connect your Google account again."

        case .invalidURL:
            return "Could not create the Google Drive API URL."

        case .invalidResponse:
            return "Google Drive returned an invalid response."

        case .apiError(let statusCode, let message):
            return "Google Drive API error (\(statusCode)): \(message)"
        }
    }
}
