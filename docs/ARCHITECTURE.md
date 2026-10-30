# CloudDisk — architecture

## Process model

Three OS-level participants, one shared core:

```
┌────────────────────────────┐        ┌───────────────────────────────┐
│ CloudDisk.app (container)  │        │ fileproviderd (system)        │
│  SwiftUI main app          │        │   └─ CloudDiskProvider.appex  │
│  · sign-in / account       │  IPC   │      NSFileProviderReplicated │
│  · dashboard, activity     │◄──────►│      Extension instance       │
│  · player, storage mgmt    │        │      per domain               │
│  · domain registration     │        │      (lives beyond app exit)  │
└───────────┬────────────────┘        └───────────────┬───────────────┘
            │            CloudDiskKit (static lib, same code both sides)
            ▼                                          ▼
   Keychain group 59YP46BFR2.dev.rohitsah.clouddisk   App Group group.dev.rohitsah.clouddisk
   (refresh + access token, email, scope)             (domain identifier, sync cursor, activity log)
                                │
                                ▼
                     Google Drive REST v3 + oauth2.googleapis.com
```

The extension is a separate process owned by `fileproviderd`. It is launched when Finder or the
system needs it and is killed when idle. Consequences that drive the design:

1. The extension must be able to authenticate **without the app running**. It therefore owns its
   own OAuth token refresh (refresh token from the shared keychain) rather than asking the app.
2. No in-memory state survives between extension instantiations. Sync cursors, anchors and
   operation metadata are persisted in the domain's state directory / App Group container.
3. Memory is limited; enumerations stream page by page and never build a full tree in RAM.

## CloudDiskKit layout

`CloudDiskKit` is a local Swift package with a **static library** product. Static, not dynamic,
because an app extension that links a dynamic library must have it present in the container app's
`Contents/Frameworks` and signed correctly; a static archive removes that failure mode entirely and
costs only duplicate symbol size.

| Area | Files | Responsibility |
| --- | --- | --- |
| `Models` | `DriveFile.swift`, `DriveChanges.swift`, `DriveAbout.swift` | Codable Drive v3 resources, with the field set the provider actually needs |
| `Networking` | `HTTPTransport.swift`, `DriveError.swift` | Transport protocol (injectable for tests), typed error taxonomy, retryability |
| `Auth` | `Credential.swift`, `KeychainCredentialStore.swift`, `TokenProvider.swift` | Shared-keychain credential store, single-flight refresh, 401 → refresh → retry once |
| `Drive` | `DriveService.swift`, `DrivePaged.swift`, `QueryEscaping.swift` | Full v3 surface: list/get/download/range/upload/create/rename/move/copy/trash/changes/about/export |
| `Provider` | `CloudDiskProviderCore.swift`, `DriveFileProviderItem.swift`, `DriveEnumerator.swift`, `SyncAnchor.swift`, `PendingOps.swift` | The File Provider implementation, independent of the app-extension target so it is unit-testable |
| `Streaming` | `RangeReader.swift`, `DriveResourceLoader.swift` | Authenticated byte-range reads; `AVAssetResourceLoaderDelegate` for the built-in player |
| `State` | `SyncCursorStore.swift`, `ActivityStore.swift`, `DomainRegistry.swift` | Persistence of cursors/anchors, app-group activity log, domain identifier constants |
| `App` | `AppModel.swift`, `DriveBrowserModel.swift` | Observable state for the UI, no GoogleSignIn import (keeps the package dependency-free) |

The extension target is a thin shim: `FileProviderExtension.swift` forwards
`NSFileProviderReplicatedExtension` methods to a `CloudDiskProviderCore` instance. All real logic
lives in the package and is testable without `fileproviderd`.

## Authentication

- Sign-in uses `GIDSignIn` (app target only) with
  `additionalScopes: ["https://www.googleapis.com/auth/drive"]`.
- The resulting `accessToken` + `refreshToken` + expiry + account email are written by the app into
  the shared keychain item `dev.rohitsah.clouddisk.google-credential` with access group
  `$(AppIdentifierPrefix)dev.rohitsah.clouddisk` and
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the extension must be able to read it after a
  reboot, before the user unlocks the app).
- Both targets declare that same keychain access group; this is what makes the sharing possible and
  is the fix for audit finding 6/7.
- `TokenProvider` performs the refresh directly against `https://oauth2.googleapis.com/token` using
  the client ID from the app's Info.plist (`GIDClientID`), guarded by one `NSLock` + a
  generation counter so ten concurrent extension calls cause **one** refresh, not ten.
- A 401 from Drive triggers exactly one refresh-and-retry; a refresh error whose `error` field is
  `invalid_grant` means revoked consent → the credential is deleted and every File Provider call
  fails with `NSFileProviderErrorNotAuthenticated` until the user reconnects.
- Tokens are never logged. `Credential` conforms to `CustomStringConvertible` with a redacted
  description, and the Drive error payloads are truncated and stripped of header echoes.

## File Provider semantics

### Domain identity, registration and liveness

`CloudDiskDomain` is the single description of the Finder location: identifier
`primary-google-drive`, display name `CloudDisk`, `supportsSyncingTrash` on because Drive really does
have a trash. The app calls `register()` on **every** launch, not only the first: the display name and
the domain features are read from the object passed to `addDomain`, so a domain that is never re-added
keeps whatever the first-installed build asked for.

What re-adding does **not** do is change which appex the system launches. `fileproviderd` records the
extension bundle URL the first time it sees a given extension identifier and keeps using that literal
path afterwards — verified on this Mac (system build 26B123, FP version 4838.41.1) by removing the
domain with
`.preserveDownloadedUserData`, re-adding it from a different app copy, restarting `fileproviderd` and
watching the record stay pointed at the old bundle. `CloudDiskDomain.repair()` performs that
remove-then-add anyway, because it is what re-creates the domain's replicated volume when the folder
was left behind by an earlier installation.

Since no public API lets an app read the registered appex path back, the extension records it itself:
every `CloudDiskFileProviderAgent` writes its own `Bundle.main.bundlePath` into
`provider-heartbeat.json` in the App Group container at start-up and on each enumeration request. The
app nudges the domain with `signalEnumerator` and polls that file. Three outcomes, all reported in the
UI rather than assumed:

| Heartbeat | Meaning | Action |
| --- | --- | --- |
| fresh, path inside this app bundle | Finder and the app agree on the live build | none |
| fresh, path outside this bundle | an older copy still serves the domain | `repair()` once, then re-check |
| absent after the wait | the extension never started | `repair()` once, then report honestly |

The heartbeat is liveness only. It never carries a token, an account or a URL with credentials.

- Item identifiers are the raw Google Drive file IDs. `root` (the Drive root folder ID) maps to
  `NSFileProviderItemIdentifier.rootContainer`; a synthetic root item is returned for
  `.rootContainer` so parents resolve. Drive IDs are URL-safe alphanumeric+`-_`, which is what the
  identifier contract needs.
- `itemVersion.contentVersion` is Drive's `version` (an opaque revision number) and
  `metadataVersion` is `modifiedTime`. Both are real server values, so the system can detect a
  changed file without hashing content.
- Enumeration is paged: `NSFileProviderPage` carries the Drive `pageToken`, and
  `finishEnumerating(upTo:)` hands back the next page token. This replaces audit finding 5.
- Change enumeration uses the Drive `changes.getChanges` feed with a persisted `startPageToken`;
  the returned `NSFileProviderSyncAnchor` encodes the new `newStartPageToken`. An expired cursor
  (`410 gone`) is reported as `NSFileProviderErrorSyncAnchorExpired`, which makes the system
  re-enumerate from scratch instead of showing stale data. This replaces audit finding 4.
- `fetchContents` downloads `?alt=media` into
  `NSFileProviderManager.temporaryDirectoryURL()` and returns the URL plus the item — the system
  then clones it onto the user-visible path. `NSFileProviderErrorNoSuchItem` is returned for 404 so
  the system removes the dead replica.
- `fetchPartialContents(for:version:request:minimalRange:aligningTo:…)` (macOS 12.3+) issues
  `Range: bytes=` requests, rounds the retrieved extent up to the requested alignment and reports
  the actual `retrievedRange`. `NSFileProviderMaterializationFlags` is deliberately left empty: the
  one flag available, `KnownSparseRanges`, tells the system to mark the *whole* file materialized
  even where it holds holes, which is the opposite of what a partial fetch is for. This is what makes
  Finder previews, Quick Look and third-party apps able to pull only the bytes they need instead of
  the whole file — whether they actually do is the system's decision, not ours.
- Capabilities come from Drive's `permissions`/`capabilities` for the authenticated user, not from a
  constant: read-only shares do not advertise `allowsWriting`/`allowsRenaming`/`allowsDeleting`.
- Google Workspace native types are advertised as their exported flavour (`com.google.docs` style
  UTTypes fall back to `.content`/`.pdf`) and downloaded through the `export` endpoint with a
  documented format list; they are marked `.allowsReading` but not `.allowsWriting` from Finder,
  because editing a Google Doc as a flat file is not something Drive supports.

## Storage states

Cloud-only → downloading → downloaded → offline-pinned → uploading → pending → error. These are not
a parallel cache: they are derived from File Provider's own answers (`isDownloaded`,
`isUploading`, `downloadingError`, the materialized-items enumerator from
`NSFileProviderManager.enumeratorForMaterializedItems`) plus `NSFileProviderItem.contentPolicy`.

- "Keep offline" sets `contentPolicy = .downloadEagerlyAndKeepDownloaded` on the item and marks the
  file non-purgeable, which is what prevents eviction from selecting it.
- "Clear eligible cache" iterates materialized items, skips pinned and in-use ones and calls
  `evictItem(identifier:completionHandler:)`, reporting `NSFileProviderErrorUnsyncedEdits` and
  `EBUSY` results instead of pretending they succeeded.
- No custom cache directory exists anywhere in the design.

## Sync and write path

- `createItem` performs a real upload: multipart for small files, resumable (`POST /upload…?uploadType=resumable`)
  for large ones, and returns the **server** item so the system adopts the server ID and version.
- `modifyItem` inspects `changedFields`: content changes upload new bytes; name/parent changes map to
  Drive rename/move (`parents` add-remove). `baseVersion` is compared against the server version and
  a mismatch returns `NSFileProviderErrorServerVersionMismatch`-style conflict so the system keeps
  both copies rather than silently overwriting.
- Failed operations are recorded in the App Group activity store with a retry action, so the
  Activity screen reflects real failures rather than a fabricated list.

## Streaming

Two distinct paths, because they are genuinely different:

- **A. CloudDisk's player.** `AVPlayer` with a fake-URL (`clouddisk-drive://media/<fileId>`) asset and
  `DriveAssetResourceLoader` conforming to `AVAssetResourceLoaderDelegate`. It answers `dataRequest`
  with byte-range GETs against Drive, serves only the requested window, and holds exactly one bounded
  read-ahead window in memory — not a cache of file content, because File Provider already owns
  materialized bytes on the volume and a second store would double disk use and fight eviction.
  Seeking is a new range request. This path creates no local file and consumes no disk. AVFoundation is
  told the type as a **UTI**; a MIME string it does not recognize makes the asset fail with
  "Cannot Open" before a single byte is read.
- **B. Finder / Quick Look / third-party apps.** Opening a dataless item triggers the File Provider
  materialization machinery; `fetchPartialContents` is implemented, so reads can pull extents on
  demand. Whether a given app gets partial or full materialization is the system's decision, not ours,
  and Quick Look is known to prefer a fully readable file for some formats. This is documented as a
  limitation rather than claimed as a feature.

## Testing strategy

- Pure logic (Drive service, token provider, query escaping, page/anchor encoding, item mapping,
  error taxonomy, pending-op queue) → `CloudDiskTests` with a stubbed `HTTPTransport`.
- File Provider behaviour that needs `fileproviderd` → manual/launch validation on this Mac, with
  the outcome recorded per-item in `docs/TESTING.md`. Anything not actually run is marked
  unverified, never "passing".
