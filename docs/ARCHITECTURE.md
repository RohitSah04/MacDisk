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
| `Models` | `DriveFile.swift`, `DriveResponses.swift` | Codable Drive v3 resources — the file shape with its `capabilities`, plus about/changes/export responses |
| `Networking` | `HTTPTransport.swift`, `DriveError.swift` | Transport protocol (injectable for tests), typed error taxonomy, retryability |
| `Auth` | `GoogleCredential.swift`, `GoogleOAuthClient.swift`, `KeychainCredentialStore.swift`, `TokenProvider.swift` | Shared-keychain credential store, token endpoint without the SDK, single-flight refresh, 401 → refresh → retry once |
| `Drive` | `DriveService.swift`, `DriveService+Transfer.swift`, `DriveQuery.swift` | Full v3 surface: list/get/download/range/upload/create/rename/move/copy/trash/changes/about/export, and the query/id escaping that Google requires |
| `Provider` | `CloudDiskFileProviderAgent.swift`, `CloudDiskProviderCore.swift`, `DriveFileProviderItem.swift`, `DriveEnumerator.swift`, `ProviderIdentity.swift`, `ProviderErrorMapper.swift`, `ProviderServices.swift`, `ProviderOperation.swift`, `PartialExtent.swift`, `WritePolicy.swift`, `CloudDiskDomain.swift` | The File Provider implementation, independent of the app-extension target so it is unit-testable: replication, enumeration, identifiers, error bridging, shared dependencies, byte extents, the write permission table and the domain descriptor |
| `Cache` | `CacheSystem.swift`, `OfflineStore.swift` | The system's side of the local cache (materialized inventory, user-visible URLs, eviction, download requests, container signals) and everything CloudDisk does with those answers: measurement, "clear cached files" and "keep offline" |
| `Streaming` | `DriveRangeReader.swift`, `DriveAssetResourceLoader.swift` | Authenticated byte-range reads; `AVAssetResourceLoaderDelegate` for the built-in player |
| `State` | `ProviderState.swift` | The App Group files both processes share: sync cursor, pin set, activity log, extension heartbeat |
| root | `CloudDiskConfig.swift` | Info.plist-derived client ID, scope, keychain access group, App Group container and display name |

The extension target is a thin shim: `CloudDiskProvider/FileProviderExtension.swift` is one line —
`final class FileProviderExtension: CloudDiskFileProviderAgent {}` — because
`NSExtensionPrincipalClass` has to name a class in the extension's own binary. The agent, and every
method it implements, lives in the package, so the whole provider is testable without `fileproviderd`.

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

Two questions, answered separately and never from a CloudDisk ledger of bytes:

**What the Finder location costs on this Mac.** `AppCore.LocalCache` is the UI state —
`.unknown / .loading / .loaded(CacheInventory) / .unavailable(reason)` — and `OfflineStore.inventory()`
produces the inventory: materialized, pinned and evictable bytes, file and folder counts, and an
`isExact` flag with the number of items whose size could not be named. Every input is the system's own:
`NSFileProviderManager.enumeratorForMaterializedItems()` for the set, `getUserVisibleURL(for:)` for the
path, `totalFileAllocatedSize` for the bytes. `declaredBytes` from the item is carried for display only,
because for a partly materialized object it is the length of the whole thing, not of the part on disk.

**Whether one object must stay.** A "keep offline" mark is a Drive id in the App Group pin set
(`ProviderState.setPinned`), which the extension reads when it publishes items, translated into
`NSFileProviderItemProtocol.contentPolicy`:

- pinned → `.downloadEagerlyAndKeepDownloaded`, which is both the eager download and the non-evictable
  mark. The macOS 12-era `.allowsEvicting` capability is deprecated and not used, and nothing is
  separately flagged "non-purgeable": the policy is what the system reads.
- unpinned → `.inherited`, deliberately not `.downloadLazily`. An explicit child policy overrides the
  container's, so a child that says "lazily" would not inherit its folder's keep-offline mark.
- the three virtual containers (root, Trash, working set) keep `.downloadLazily`; they have no bytes.

Pinning then signals the parent container so the new policy reaches the disk replica, and asks
`__requestDownloadForItem(withIdentifier:requestedRange:)` for the whole object — a Finder-side download
otherwise only starts when the user opens the file.

- "Clear cached files" (`OfflineStore.releaseEligibleItems()`) iterates the materialized inventory,
  skips folders and pinned items **without offering them** — eviction stops at the first non-evictable
  child of a folder — calls `evictItem(identifier:)` on the rest, and reports each refusal under its own
  heading (`.nonEvictable`, `.unsyncedEdits`, `EBUSY`, already-absent) separately from a real failure.
- Per-item progress and error flags (`isUploading` and the rest) are read inside the extension where the
  system asks for them; they are not mirrored into a second state machine the app would have to keep
  in sync.
- No custom cache directory exists anywhere in the design. File content is never stored by CloudDisk;
  only metadata is cached, and it is a 10-second TTL cache of Drive answers, not bytes.

## Sync and write path

- `createItem` performs a real upload: multipart for small files, resumable (`POST /upload…?uploadType=resumable`)
  for large ones, and returns the **server** item so the system adopts the server ID and version.
- `modifyItem` inspects `changedFields`: content changes upload new bytes; name/parent changes map to
  Drive rename/move (`parents` add-remove). `baseVersion` is compared against the server copy and a
  mismatch keeps both rather than silently overwriting: the remote object keeps Google's newest
  version, the local bytes become a "… (conflicted copy)" file beside it, and `shouldFetchContent`
  tells the system to re-read the winner. Where the system asks for the other policy
  (`NSFileProviderModifyItemOptions.failOnConflict`, macOS 26+) the extension throws
  `NSFileProviderErrorLocalVersionConflictingWithServer` instead.
- **Permissions are checked before the request, not only advertised.** `WritePolicy` reads Drive's
  `capabilities` on the metadata the write has already fetched — plus the cached listing of a
  destination folder — and refuses only on an explicit `false`: `canEdit` for content, rename and
  metadata; `canMoveItemOutOfWorld` for leaving someone else's folder; `canAddChildren` for the folder
  receiving a create or a move, which is the one permission the system cannot validate for a provider
  because it checks the item being moved, not the destination; and the trash flag outranks all of them.
  Drive's `canTrash`/`canEdit` ride along in the same `files.get` that already decides
  trash-versus-permanent-delete. What Google did not say is not a refusal — its 403 stays the authority
  for a permission that changed after the listing, and a false guess from missing fields would make an
  editable object uneditable.
- A denied save is reported as `NSCocoaErrorDomain`/`fileWriteNoPermission` (`CoreError.writeNotAllowed`),
  never as a read failure, and every write failure — upload, rename, move, delete, or a local edit
  replayed after a restart — is recorded in the App Group activity store with the item's filename, so
  the Activity screen reflects real failures rather than a fabricated list.
- A Google Workspace document's name and folder are ordinary Drive metadata and are written; only its
  content stays pending, because Drive has no upload path for an exported document.
- There is no CloudDisk-side write queue. File Provider journals a pending change itself, survives an
  extension restart, and replays it into `createItem` with `.mayAlreadyExist` — which is what the
  reimport matching exists to answer without duplicating the user's files.

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

Three seams, each one there because some part of the system cannot be reached from a unit test:

- `HTTPTransport` → `StubTransport` scripts Drive's replies in order, so "this request must not be made"
  is provable: the stub runs out of scripted responses and the test fails. This is how the whole Drive
  layer — pagination, ranges, resumable sessions, the changes feed, retry, the 401 path — is tested
  without network access or credentials.
- `CacheSystem` → `ScriptedCacheSystem` answers the five File Provider questions (what is materialized,
  where it lives, will you evict, will you download, signal) with recorded calls, so inventory
  arithmetic, which items are offered for eviction and how each refusal is named are all testable
  against real files on real disk while `fileproviderd` stays out of it. `FileProviderCacheSystem`
  itself therefore has no unit coverage and is listed as unverified.
- `ProviderState(directory:)` points the App Group files at a temporary directory, and a second instance
  over the same directory stands in for the other process — which is what proves the pin set and the
  activity log really are cross-process state rather than process memory.

- Pure logic (Drive service, token provider, query escaping, page/anchor encoding, item mapping, error
  taxonomy, write permissions, cache arithmetic) → `CloudDiskKitTests`, 319 cases, run with
  `swift test --package-path CloudDiskKit`.
- A registered domain, when one exists → `DomainCacheSmokeTests` asks the real system what it holds and
  where it lives, read-only, with a deadline so an unresponsive `fileproviderd` skips rather than hangs.
  It skips unless the calling process can see a CloudDisk domain, which a command-line test binary
  cannot on this machine.
- File Provider behaviour that needs `fileproviderd` → launch validation on this Mac, recorded
  per-item in `docs/KNOWN_LIMITATIONS.md`. Anything not actually run is marked unverified, never
  "passing".
