
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        // No persistent network resources to clean up yet.
    }

    // MARK: - Google Drive access token

    private func accessToken() throws -> String {
        guard let defaults = UserDefaults(
            suiteName: "group.dev.rohitsah.clouddisk"
        ) else {
            throw NSError(
                domain: "CloudDisk",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not access the shared App Group."
                ]
            )
        }

        guard let token = defaults.string(
            forKey: "GoogleDriveAccessToken"
        ), !token.isEmpty else {
            throw NSError(
                domain: "CloudDisk",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No Google Drive access token was found. Open CloudDisk and sign in again."
                ]
            )
        }

        let expiry = defaults.double(
            forKey: "GoogleDriveAccessTokenExpiry"
        )

        if expiry > 0 && Date().timeIntervalSince1970 >= expiry - 60 {
            throw NSError(
                domain: "CloudDisk",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Google access token has expired. Open CloudDisk and sign in again."
                ]
            )
        }

        return token
    }

    // MARK: - Google Drive API

    private struct DriveListResponse: Decodable {
        let files: [DriveFileRecord]?
        let nextPageToken: String?
    }

    private struct DriveFileRecord: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let modifiedTime: String?
    }

    private func fetchDriveFiles(
        completion: @escaping (Result<[DriveFileRecord], Error>) -> Void
    ) {
        do {
            let token = try accessToken()

            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files"
            )!

            components.queryItems = [
                URLQueryItem(
                    name: "pageSize",
                    value: "100"
                ),
                URLQueryItem(
                    name: "orderBy",
                    value: "folder,name"
                ),
                URLQueryItem(
                    name: "fields",
                    value: "files(id,name,mimeType,size,modifiedTime),nextPageToken"
                ),
                URLQueryItem(
                    name: "q",
                    value: "trashed = false"
                )
            ]

            guard let url = components.url else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(URLError(.badServerResponse)))
                    return
                }

                guard (200..<300).contains(http.statusCode) else {
                    let message = String(
                        data: data ?? Data(),
                        encoding: .utf8
                    ) ?? "Unknown Google Drive API error"

                    completion(.failure(NSError(
                        domain: "GoogleDriveAPI",
                        code: http.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Google Drive returned HTTP \(http.statusCode): \(message)"
                        ]
                    )))
                    return
                }

                do {
                    let result = try JSONDecoder().decode(
                        DriveListResponse.self,
                        from: data ?? Data()
                    )
                    completion(.success(result.files ?? []))
                } catch {
                    completion(.failure(error))
                }
            }.resume()

        } catch {
            completion(.failure(error))
        }
    }

    private func makeItem(
        from file: DriveFileRecord
    ) -> FileProviderItem {
        FileProviderItem(
            identifier: NSFileProviderItemIdentifier(file.id),
            filename: file.name,
            contentType: UTType(mimeType: file.mimeType) ?? .data
        )
    }

    // MARK: - File Provider

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(
                FileProviderItem(identifier: .rootContainer),
                nil
            )
            return Progress()
        }

        fetchDriveFiles { result in
            switch result {
            case .success(let files):
                if let file = files.first(where: {
                    $0.id == identifier.rawValue
                }) {
                    completionHandler(self.makeItem(from: file), nil)
                } else {
                    completionHandler(nil, NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileNoSuchFileError
                    ))
                }

            case .failure(let error):
                completionHandler(nil, error)
            }
        }

        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        completionHandler(
            nil,
            nil,
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Downloading file contents will be implemented in the next step."
                ]
            )
        )
        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        completionHandler(
            nil,
            [],
            false,
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError
            )
        )
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        completionHandler(
            nil,
            [],
            false,
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError
            )
        )
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError
            )
        )
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier
        )
    }
}
