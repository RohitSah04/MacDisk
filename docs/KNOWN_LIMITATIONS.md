# CloudDisk — known limitations

Divided into limits that are **structural** (Apple or Google will not allow otherwise) and limits
that are **current** (this build has not proven them yet). Structural limits are not "bugs to fix";
they define what "works like a disk" can mean.

## Structural — Apple File Provider

1. **A File Provider domain is not a normal folder.** `fileproviderd` owns the process, kills it when
   idle and restarts it on demand. Any design that assumes a long-running helper will fail; all sync
   state must be persisted, and the extension must be able to authenticate without the app running.
2. **The system decides when bytes are fetched.** An extension can only answer
   `fetchContents`/`fetchPartialContents`. It cannot force Quick Look or a third-party app to stream.
   Partial materialization is available on macOS 12.3+ via `NSFileProviderPartialContentFetching`,
   but some consumers still request the whole extent. So "open a 4 GB video in QuickTime and scrub"
   may materialize more than CloudDisk's own player would.
3. **Thumbnails cannot be supplied by a replicated extension.** `fetchThumbnails(for:requestedSize:…)`
   exists on `NSFileProviderExtension`, the legacy domain-based class, not on
   `NSFileProviderReplicatedExtension`. Finder icon previews for cloud-only files therefore come from
   whatever the system decides to read. CloudDisk's own browser uses Drive's `thumbnailLink` instead,
   which is the only place we control thumbnails.
4. **"Keep my Mac in sync" / eviction is the system's decision.** CloudDisk can mark items
   non-purgeable and request downloads, and can *ask* for eviction via
   `evictItem(identifier:completionHandler:)`, but macOS may refuse (`EBUSY` for open descriptors,
   `NSFileProviderErrorUnsyncedEdits` for local edits, `NSFileProviderErrorNonEvictable`). Those
   refusals must be surfaced, not hidden.
5. **Item identifiers are permanent.** Reusing a Drive ID for a different file is forbidden; Drive's
   copy operation creates a new ID, which is why "copy in Finder" maps to a real Drive copy rather
   than a local clone.
6. **The Trash container requires `NSFileProviderItemCapabilitiesAllowsTrashing`** and an actual trash
   implementation; Drive supports trashing, but permanently deleting from Finder's trash needs the
   `delete` API and a `trashed`-aware enumerator, which is extra surface area beyond a first release.
7. **Hard links, symlinks, file permissions, ACLs, xattrs, extended attributes and case-insensitive
   name collisions do not exist in Drive.** Drive is flat-name-per-folder, case-insensitive-ish, with
   no POSIX metadata. Renaming to a name that differs only in case, or creating a name Drive will
   collide with, produces a "bounced" filename from the system.
8. **macOS sandbox + App Group + keychain sharing is the only sanctioned bridge** between app and
   extension. There is no way to make the app proxy Drive requests for the extension, so the
   extension must hold the refresh token itself.

9. **A registered domain keeps the appex path it was first given.** `NSFileProviderManager.addDomain`
   updates a domain's display name and hidden state, and re-creating the domain after a
   `.preserveDownloadedUserData` removal still does not replace the extension bundle URL
   `fileproviderd` stored. Consequences: a build must be installed at a stable path (an in-place
   update at the same path is what the system expects), and a machine that once registered a
   *different* app with the same extension identifier keeps serving that one. CloudDisk detects this
   with the extension heartbeat (see ARCHITECTURE.md → Domain identity) and reports it in the UI
   instead of pretending the location is live.
## Structural — Google Drive

10. **Google Docs/Sheets/Slides are not files.** They have no byte content to download. They can only
   be exported (`/files/{id}/export`) to a fixed format list per type, and they cannot be edited by
   writing bytes back. CloudDisk advertises them as read-only with an exported representation.
11. **Full-Drive access needs the sensitive `drive` scope.** In an unverified OAuth consent screen
    this means the "Google hasn't verified this app" interstitial and sign-in restricted to explicit
    test users. Only `drive.readonly` (current state) is trivially granted; `drive` cannot be
    requested without the user completing Cloud Console configuration.
12. **`alt=media` range support is not universal.** Binary files honour `Range`; Google Docs have no
    media at all; and Drive may return `200` with the whole body instead of `206` for very small or
    oddly-encoded files. The streaming layer must detect that and degrade instead of assuming a `206`.
13. **Rate limits are per-project and bursty** (default ~12,000 queries/minute/user, but 429s with
    `rateLimitExceeded` happen on parallel enumeration). Correct behaviour is exponential backoff with
    jitter and honoring `Retry-After`, not unlimited retries.
14. **Shared drives and shortcuts add identity wrinkles**: a file can have multiple parents, and
    Drive's `shortcut` mimeType has no content. Multi-parent items must be flattened to one
    canonical parent for the Finder tree or they will appear in two places, which File Provider
    cannot represent.
15. **A refresh token can die silently** (user revokes access in their Google account). The only
    detection is `invalid_grant` on refresh, which must map to a reconnect prompt.

## Current — this build

Updated as work completes; anything left in this list is not verified.

| Item | Status |
| --- | --- |
| Finder domain registration | **verified**: launching the built app registers domain `primary-google-drive` (display name CloudDisk, `repl,syncTrash`) and `fileproviderd` starts the extension from that bundle; the domain is marked `needs-auth` because no credential exists yet |
| Extension actually runs this build | **verified**: the live appex process is the one inside the built `CloudDisk.app`, and the system-reported provider flags (`supports failing upload on conflict: 1`) come from this build's Info.plist |
| Shared keychain usable at runtime | unverified in UI — entitlements of both bundles are identical (`59YP46BFR2.dev.rohitsah.clouddisk`, checked with `codesign -d --entitlements :-`), the app's probe row needs a look by the user |
| Finder browsing with real credentials | unverified — needs an interactive Google sign-in by the user |
| Full-file download on open | to be implemented in Phase 3 |
| Upload/rename/move/delete | to be implemented in Phase 5 |
| Byte-range streaming in the built-in player | to be implemented in Phase 4 |
| Persistence across logout/restart of macOS | to be validated in Phase 8 |
| Developer ID signing + notarization + DMG distribution | **not possible on this machine**: only an Apple Development certificate is installed, so the distributed build will be ad-hoc/development-signed and will not install on another Mac without extra steps |
| Mac App Store distribution | not attempted (File Provider + sandbox rules differ, and no App Store profile exists) |

## Development-machine notes

- On this Mac the system's provider record is pinned to
  `~/Library/Developer/Xcode/DerivedData/pro-beavlgmbfmvnfjfqybfklneyodna/Build/Products/Debug/pro.app.pre-clouddisk-stale`
  because that bundle (the pre-production prototype) created the domain. Until it is cleared, every
  rebuilt `CloudDisk.app` must be copied to that exact path and launched from there for Finder to serve
  the new code; `open`-ing the build under `pro/build/DerivedData` registers the domain but leaves the
  old appex in charge. The prototype bundle is kept beside it as `pro.app.prototype-backup`.
- A clean machine (or a fresh user account) does not have this problem: the first `addDomain` call
  records the app's own appex.
