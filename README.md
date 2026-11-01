# CloudDisk

### Your Google Drive. Your Mac. One native Finder experience.

<p align="center">
  <strong>A native macOS cloud-storage application that integrates Google Drive directly into Finder using Apple's File Provider framework.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS-black?logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Language-Swift-orange?logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-blue" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/Storage-Google%20Drive-4285F4?logo=googledrive" alt="Google Drive" />
  <img src="https://img.shields.io/badge/Architecture-File%20Provider-6A5ACD" alt="File Provider" />
  <img src="https://img.shields.io/badge/Tests-382%20passed-success" alt="Tests" />
</p>

<p align="center">
  <a href="https://github.com/RohitSah04/MacDisk">GitHub Repository</a> •
  <a href="https://github.com/RohitSah04/MacDisk/issues">Report a Bug</a> •
  <a href="https://github.com/RohitSah04/MacDisk/discussions">Discussions</a>
</p>

---

## Overview

CloudDisk brings Google Drive closer to the macOS experience.

Instead of relying on a traditional browser-based file manager, CloudDisk integrates Google Drive into Finder as a native File Provider location.

Browse cloud files, open documents, preview images, play videos, upload files and manage your Drive content through a familiar macOS interface.

The application is designed around an important idea:

**Cloud files should behave like local files without requiring every file to occupy space on your Mac.**

CloudDisk uses Apple's File Provider replication system to manage file availability and local materialization. Files can remain cloud-only until needed, while downloaded copies can be released when they are no longer required.

## Why CloudDisk?

Cloud storage is convenient, but managing files across cloud services can feel disconnected from the desktop operating system.

CloudDisk explores a more integrated approach:

- Access Google Drive directly from Finder.
- Download files when they are needed.
- Keep important files available offline.
- Automatically release eligible local copies after inactivity.
- Preview documents and images.
- Stream supported video content.
- Manage Drive files through native file operations.

The goal is to combine the convenience of cloud storage with the familiar experience of macOS.

## Features

### 1. Native Finder Integration

CloudDisk registers a File Provider domain and exposes Google Drive as a location in Finder.

- Appears under Finder → Locations.
- Browse files and folders.
- Navigate nested directories.
- Access cloud-backed files using familiar macOS workflows.
- Uses Apple's File Provider replication architecture.

### 2. On-Demand File Downloads

CloudDisk avoids requiring every cloud file to be downloaded in advance.

- Files can remain dataless until accessed.
- Opening a file requests its content from Google Drive.
- Supports whole-file materialization.
- Supports partial byte-range fetching where supported by the requesting application and the file.
- Reopening an evicted file triggers materialization again.

### 3. Smart 15-Minute Auto-Eviction

One of CloudDisk's key features is intelligent local-cache management.

When a downloaded file has remained idle for 15 minutes, CloudDisk can request that macOS release its local copy.

The original file remains in Google Drive.

**How it works:**

1. A cloud file is opened or downloaded.
2. CloudDisk records its access information.
3. The file remains available during the 900-second idle window.
4. The eviction scheduler identifies eligible local copies.
5. CloudDisk requests eviction through Apple's File Provider API.
6. macOS releases the local materialized copy when permitted.
7. Opening the file again downloads it on demand.

**Protection mechanisms:**

- Pinned files are protected from automatic eviction.
- In-flight reads are protected.
- Unknown access history is handled conservatively.
- Open-file and system eviction refusals are respected.
- Failed eviction operations do not silently delete cloud originals.

The eviction process is best-effort: macOS controls the final decision and may defer or refuse an eviction.

### 4. Offline Pinning

Some files should always remain available.

CloudDisk supports keeping selected files downloaded.

- Pin important files for offline access.
- Request their download.
- Protect pinned files from automatic cache eviction.
- Manage local availability separately from ordinary cloud-only files.

### 5. Video Streaming and Media Preview

CloudDisk includes a built-in media playback path.

- AVPlayer-based video playback.
- Authenticated HTTP byte-range requests.
- Custom AVAssetResourceLoader integration.
- Range-based media fetching.
- Image and PDF previews.
- Quick Look integration through the File Provider location.

Actual partial materialization depends on the requesting application and macOS.

### 6. Google Drive File Management

CloudDisk integrates with Google Drive API v3.

Supported operations include:

- List files and folders.
- Upload files.
- Download files.
- Rename files.
- Move files.
- Copy files.
- Trash files.
- Synchronize changes made outside CloudDisk.
- Export supported Google Workspace document types.

Google Docs, Sheets and Slides are handled through Drive export formats and are not ordinary editable binary files.

### 7. Secure Authentication

CloudDisk uses Google OAuth 2.0 for account authentication.

Security-related implementation includes:

- Google Sign-In integration.
- Shared Keychain credential storage.
- Secure credential access between the app and File Provider extension.
- Access-token refresh.
- Authentication recovery handling.
- Redacted credential logging.

Access and refresh tokens are not intended to be stored in plaintext application files or printed in logs.

### 8. Persistent Background File Provider

The File Provider extension is managed by macOS through `fileproviderd`.

This means the extension can service Finder requests independently of the main CloudDisk application window.

Persistent provider state includes:

- Synchronization cursors.
- File metadata.
- Offline pin information.
- Activity information.
- Cache and eviction history.

---

## Architecture

CloudDisk is built around three cooperating components.

```text
                  ┌─────────────────────────────┐
                  │        CloudDisk.app        │
                  │                             │
                  │          SwiftUI            │
                  │                             │
                  │  • Google Sign-In           │
                  │  • File Browser              │
                  │  • Dashboard                 │
                  │  • Media Player              │
                  │  • Cache Management          │
                  └──────────────┬──────────────┘
                                 │
                                 │ Shared State
                                 │
                  ┌──────────────▼──────────────┐
                  │        CloudDiskKit         │
                  │                             │
                  │  • Authentication           │
                  │  • Google Drive API         │
                  │  • File Provider Core       │
                  │  • Cache Management         │
                  │  • Streaming                │
                  │  • Persistent State         │
                  └──────────────┬──────────────┘
                                 │
                                 │
                 ┌───────────────▼──────────────┐
                 │       CloudDiskProvider      │
                 │                              │
                 │    File Provider Extension   │
                 │                              │
                 │  • Enumeration               │
                 │  • File Materialization      │
                 │  • File Operations           │
                 │  • Synchronization           │
                 │  • Eviction                  │
                 └───────────────┬──────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │       macOS             │
                    │      fileproviderd      │
                    │                         │
                    │   Finder → Locations    │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │      Google Drive       │
                    │                         │
                    │       Drive API v3      │
                    └─────────────────────────┘
```

### Component responsibilities

| Component | Responsibility |
|---|---|
| CloudDisk.app | User interface, account connection, dashboard and management |
| CloudDiskKit | Shared business logic, authentication, networking, cache and provider implementation |
| CloudDiskProvider | macOS File Provider extension |
| fileproviderd | System-managed File Provider lifecycle and file replication |
| Google Drive API v3 | Cloud file storage, metadata and file operations |
| Shared Keychain | Secure credential sharing |
| App Group | Shared provider state and synchronization information |

### Technology Stack

| Technology | Purpose |
|---|---|
| Swift | Core application language |
| SwiftUI | Native macOS interface |
| File Provider Framework | Finder integration and file replication |
| Google Drive API v3 | Cloud storage operations |
| Google Sign-In | OAuth authentication |
| Keychain Services | Secure credential storage |
| App Groups | Shared state between app and extension |
| AVKit / AVFoundation | Video playback and streaming |
| Quick Look | Document previews |
| XCTest / Swift Testing | Automated testing |
| Xcode | Development and build environment |

---

## Project Structure

```text
MacDisk/
│
├── CloudDiskKit/
│   ├── Sources/
│   │   └── CloudDiskKit/
│   │       ├── Auth/
│   │       ├── Cache/
│   │       ├── Drive/
│   │       ├── Models/
│   │       ├── Networking/
│   │       ├── Provider/
│   │       ├── State/
│   │       └── Streaming/
│   │
│   ├── Tests/
│   │   └── CloudDiskKitTests/
│   │
│   └── Package.swift
│
├── CloudDiskProvider/
│   ├── FileProviderExtension.swift
│   ├── Info.plist
│   └── CloudDiskProvider.entitlements
│
├── CloudDiskTests/
│
├── pro/
│   ├── MyApp.swift
│   ├── AppCore.swift
│   ├── RootView.swift
│   ├── FileBrowser.swift
│   ├── FilesView.swift
│   ├── PlayerView.swift
│   ├── PreviewView.swift
│   ├── ActivityView.swift
│   └── SharedViews.swift
│
├── pro.xcodeproj/
│
├── docs/
│   ├── ACCEPTANCE_TEST_REPORT.md
│   ├── ARCHITECTURE.md
│   ├── IMPLEMENTATION_PLAN.md
│   ├── INSTALL.md
│   ├── KNOWN_LIMITATIONS.md
│   ├── OAUTH_SETUP.md
│   ├── PROJECT_AUDIT.md
│   ├── RELEASE_CHECKLIST.md
│   ├── RELEASE_NOTES.md
│   └── TESTING.md
│
└── README.md
```

---

## Getting Started

### Requirements

Before building CloudDisk, make sure you have:

- A Mac with Apple silicon.
- macOS 14 or later.
- Xcode with macOS development support.
- Swift toolchain compatible with the project.
- A Google account.
- A Google Cloud project with the Google Drive API enabled.

### 1. Clone the repository

```bash
git clone https://github.com/RohitSah04/MacDisk.git

cd MacDisk
```

### 2. Open the Xcode project

```bash
open pro.xcodeproj
```

Select the `CloudDisk` scheme and a macOS destination.

### 3. Configure Google OAuth

CloudDisk requires your own Google OAuth configuration.

1. Open Google Cloud Console.
2. Create or select a Google Cloud project.
3. Enable Google Drive API v3.
4. Configure the OAuth consent screen.
5. Create the appropriate OAuth client.
6. Configure the client ID and URL scheme for the application.
7. Configure the required entitlements and shared Keychain access.
8. Add yourself as a test user if the OAuth consent screen is in testing mode.

Read the detailed setup instructions before running the app:

[Google OAuth Setup Guide](docs/OAUTH_SETUP.md)

**Important:** Never commit your OAuth client secret, refresh token, access token, private credentials or personal configuration files.

### 4. Build the application

From the repository root:

```bash
xcodebuild \
  -scheme CloudDisk \
  -destination 'platform=macOS' \
  build
```

Alternatively, build through Xcode.

### 5. Run the application

Launch the built CloudDisk application.

1. Connect your Google account.
2. Complete the OAuth consent flow.
3. Allow CloudDisk to register its File Provider domain.
4. Open Finder.
5. Navigate to Locations.
6. Open CloudDisk.

Your Google Drive content should appear through the registered Finder location once setup is complete.

For installation, deployment and domain-registration details, see:

[Installation Guide](docs/INSTALL.md)

---

## Testing

CloudDisk includes a dedicated Swift package test suite and application-hosted tests.

### Run the CloudDiskKit test suite

```bash
swift test --package-path CloudDiskKit
```

### Latest recorded package test result

| Metric | Result |
|---|---:|
| Tests executed | 382 |
| Passed | 382 |
| Skipped | 14 |
| Failed | 0 |

The 14 skipped tests are live Google Drive API smoke tests that require explicitly supplied credentials.

### What is tested?

- OAuth credential handling.
- Token refresh behavior.
- Google Drive API requests.
- File enumeration.
- File identity and parent mapping.
- File Provider state persistence.
- Cache management.
- Automatic eviction decisions.
- Offline pinning.
- Partial content and byte ranges.
- Streaming support.
- File operations.
- Error handling.

The automated test suite is not a replacement for real-device acceptance testing. Live Google Drive behavior and macOS File Provider behavior are also documented separately.

Read:

- [Testing Guide](docs/TESTING.md)
- [Acceptance Test Report](docs/ACCEPTANCE_TEST_REPORT.md)

---

## Verification and Real-World Testing

CloudDisk has undergone real-world testing against a live Google Drive account on Apple silicon macOS.

The acceptance work covered:

- Google authentication.
- Persistent credential access.
- Finder File Provider registration.
- Real Drive file and folder enumeration.
- Nested folder navigation.
- Image and PDF previews.
- Video playback.
- Finder Quick Look.
- On-demand downloads.
- Upload, rename, move, copy and trash operations.
- Synchronization of external Drive changes.
- Offline pinning.
- Automatic local-copy eviction.
- Re-downloading after eviction.
- Persistence across a Mac restart.

### Automatic eviction verification

The 15-minute eviction mechanism was observed on a real macOS mount.

A downloaded file was materialized, recorded in the access ledger, retained during its idle window and subsequently released through the File Provider eviction API. Its Finder metadata remained available, and reopening the file downloaded its content again.

The restart test also confirmed that the domain, credential state, access ledger and demand-download path survived reboot.

**Verification note:** The sync-anchor resume observation across reboot remained unverified in the recorded T15 run. The full acceptance evidence and its qualifications are available in the test report.

---

## Security and Privacy

Security is an important part of CloudDisk's architecture.

The application is designed to:

- Store authentication credentials in Keychain rather than plaintext files.
- Share credentials between the app and extension through a configured Keychain access group.
- Use App Groups for shared provider state.
- Avoid printing access and refresh tokens in application logs.
- Redact sensitive credential information from diagnostic output.
- Keep Google Drive originals separate from local cache eviction.
- Use Google's OAuth consent and authorization mechanisms.

### Credential configuration

Developers must configure their own OAuth client and consent screen.

Do not publish:

- OAuth client secrets.
- Access tokens.
- Refresh tokens.
- Private keys.
- Personal account credentials.
- Keychain exports.
- Private signing certificates.

If you discover a security issue, please do not publish credentials or sensitive account information in a public issue.

---

## Known Limitations

CloudDisk works within the capabilities and restrictions of Apple's File Provider framework and Google Drive.

Some important limitations:

1. **System-controlled materialization:** macOS decides when a file's content is downloaded. Different applications may request different amounts of data.
2. **Best-effort eviction:** macOS can refuse to evict files that are open, protected or contain unsynchronized changes.
3. **External video players:** Partial materialization behavior depends on the application requesting the file. Some applications may request more data than expected.
4. **Google Workspace files:** Google Docs, Sheets and Slides are exported to supported formats and are not ordinary editable binary files.
5. **OAuth verification:** Full Drive access uses a sensitive Google OAuth scope. An application with an unverified consent screen may be restricted to configured test users.
6. **Sync lifecycle:** The File Provider extension is system-managed and is not guaranteed to run continuously.
7. **System scheduling:** The 15-minute idle threshold determines eligibility for eviction; it does not guarantee that macOS releases the local copy at exactly 15 minutes.

For the complete and current list:

[Known Limitations](docs/KNOWN_LIMITATIONS.md)

---

## Documentation

The `docs/` directory contains additional technical documentation.

| Document | Description |
|---|---|
| [Installation](docs/INSTALL.md) | Installation, deployment and removal |
| [OAuth Setup](docs/OAUTH_SETUP.md) | Google Cloud and OAuth configuration |
| [Architecture](docs/ARCHITECTURE.md) | Internal architecture and design decisions |
| [Testing](docs/TESTING.md) | Automated and manual testing |
| [Acceptance Test Report](docs/ACCEPTANCE_TEST_REPORT.md) | Real-world verification evidence |
| [Known Limitations](docs/KNOWN_LIMITATIONS.md) | Structural and current limitations |
| [Implementation Plan](docs/IMPLEMENTATION_PLAN.md) | Development history and implementation phases |
| [Project Audit](docs/PROJECT_AUDIT.md) | Project review and technical findings |
| [Release Checklist](docs/RELEASE_CHECKLIST.md) | Release preparation |
| [Release Notes](docs/RELEASE_NOTES.md) | Build and release information |

---

## Roadmap

Potential future improvements include:

- [ ] Multi-account Google Drive support.
- [ ] More advanced cache controls.
- [ ] Improved sync and conflict-resolution visibility.
- [ ] More extensive macOS version testing.
- [ ] Expanded automated integration testing.
- [ ] Improved installation and update experience.
- [ ] Distribution with Developer ID signing and notarization.
- [ ] Additional cloud storage provider support.

The roadmap represents possible future work, not a claim that these features are already implemented.

---

## Contributing

Contributions, bug reports, suggestions and technical discussions are welcome.

If you want to contribute:

1. Fork the repository.
2. Create a feature branch.
3. Make your changes.
4. Add or update tests where appropriate.
5. Run the test suite.
6. Submit a pull request with a clear description.

For bugs, please include:

- macOS version.
- CloudDisk build information.
- Steps to reproduce.
- Relevant redacted logs.
- Expected behavior.
- Actual behavior.

Never include OAuth tokens, personal Drive files or private credentials in an issue or pull request.

---

## License

No open-source license has been added to this repository yet.

Until a license is added, assume that the source code is not granted for reuse, redistribution or modification beyond the permissions provided by applicable law. A public GitHub repository is not automatically an open-source-licensed project.

---

## Author

**Developed by Rohit Sah**

GitHub: [@RohitSah04](https://github.com/RohitSah04)

Project: [CloudDisk — MacDisk](https://github.com/RohitSah04/MacDisk)

---

<p align="center">
  <strong>CloudDisk</strong><br/>
  Bringing cloud storage closer to the macOS desktop.
</p>

<p align="center">
  Built with Swift, SwiftUI and Apple's File Provider framework.
</p>
