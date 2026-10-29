
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier

    private let anchor = NSFileProviderSyncAnchor(
        Data("cloud-disk-v1".utf8)
    )

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        super.init()
    }

    func invalidate() {
        // No persistent resources to clean up.
    }

    private struct DriveListResponse: Decodable {
        let files: [DriveFileRecord]?
    }

    private struct DriveFileRecord: Decodable {
        let id: String
        let name: String
        let mimeType: String
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        guard let defaults = UserDefaults(
            suiteName: "group.dev.rohitsah.clouddisk"
        ) else {
            print("CloudDisk DEBUG: App Group UserDefaults unavailable.")

            observer.finishEnumeratingWithError(
                NSError(
                    domain: "CloudDisk",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The shared App Group preferences are unavailable."
                    ]
                )
            )
            return
        }

        let token = defaults.string(forKey: "GoogleDriveAccessToken") ?? ""

        print("CloudDisk DEBUG: Shared preferences accessible.")
        print("CloudDisk DEBUG: Token present: \(!token.isEmpty)")

        guard !token.isEmpty else {
            observer.finishEnumeratingWithError(
                NSError(
                    domain: "CloudDisk",
                    code: 11,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No Google token found. Open CloudDisk and sign in again."
                    ]
                )
            )
            return
        }
            observer.finishEnumeratingWithError(
                NSError(
                    domain: "CloudDisk",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Google Drive token is missing. Open CloudDisk and sign in again."
                    ]
                )
            )
            return
        }

        let folderID: String

        if enumeratedItemIdentifier == .rootContainer {
            folderID = "root"
        } else {
            folderID = enumeratedItemIdentifier.rawValue
        }

        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files"
        )!

        components.queryItems = [
            URLQueryItem(
                name: "pageSize",
                value: "1000"
            ),
            URLQueryItem(
                name: "orderBy",
                value: "name"
            ),
            URLQueryItem(
                name: "fields",
                value: "files(id,name,mimeType)"
            ),
            URLQueryItem(
                name: "q",
                value: "'\(folderID)' in parents and trashed = false"
            )
        ]

        guard let url = components.url else {
            observer.finishEnumeratingWithError(URLError(.badURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )

        URLSession.shared.dataTask(with: request) {
            data, response, error in

            if let error {
                observer.finishEnumeratingWithError(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                observer.finishEnumeratingWithError(
                    URLError(.badServerResponse)
                )
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let responseText = String(
                    data: data ?? Data(),
                    encoding: .utf8
                ) ?? "Unknown Google Drive API error"

                observer.finishEnumeratingWithError(
                    NSError(
                        domain: "GoogleDriveAPI",
                        code: httpResponse.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Google Drive API error (\(httpResponse.statusCode)): \(responseText)"
                        ]
                    )
                )
                return
            }

            do {
                let result = try JSONDecoder().decode(
                    DriveListResponse.self,
                    from: data ?? Data()
                )

                let items = (result.files ?? []).map { file in
                    FileProviderItem(
                        identifier: NSFileProviderItemIdentifier(file.id),
                        filename: file.name,
                        contentType: UTType(mimeType: file.mimeType) ?? .data
                    )
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)

                print(
                    "CloudDisk: Enumerated \(items.count) Google Drive items."
                )
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }.resume()
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(
            upTo: self.anchor,
            moreComing: false
        )
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(anchor)
    }
}
