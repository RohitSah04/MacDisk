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
5. **Item identifiers are permanent.** Reusing a Drive ID for a different file is forbidden. Drive's
   `files.copy` endpoint exists and CloudDisk's service layer calls it, but the File Provider
   interface never needs to: a Finder copy is a local clone the system then hands to `createItem` as
   new content, so the copied row becomes a new Drive object through the upload path.
6. **Trash needs both a `trashed`-aware enumerator and the real delete API.** Drive trashes a
   folder's descendants with it while the default children query filters trashed objects out, so
   CloudDisk lifts that filter for a trashed parent and advertises trashed items with
   `.allowsDeleting` but not `.allowsTrashing` — that combination is what makes Finder show "delete
   immediately" and ask its own confirmation first. CloudDisk cannot add a second gate: File Provider
   exposes no hook between the user's click and `deleteItem`.
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
    test users. CloudDisk requests `https://www.googleapis.com/auth/drive` (read/write, per
    `CloudDiskConfig.driveScope`) because the product requires uploads and edits; the user must add
    that scope in Google Cloud Console and either publish the consent screen or list themselves as a
    test user, or sign-in will fail with `access_denied`/`invalid_grant`.
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

Updated as work completes. The acceptance run of 2026-10-31 → 11-01
(`docs/ACCEPTANCE_TEST_REPORT.md`) moved most of the signed-in rows below from *unverified* to
*verified*, and added the propagation, mount-hijack and stale-replica rows; anything still marked
unverified here has genuinely not been seen.

| Item | Status |
| --- | --- |
| Finder domain registration | **verified**: launching the built app registers domain `primary-google-drive` (display name CloudDisk, `repl,syncTrash`) and `fileproviderd` starts the extension from that bundle; the domain is marked `needs-auth` because no credential exists yet |
| Extension actually runs this build | **verified**: the live appex process is the one inside the built `CloudDisk.app`, and the system-reported provider flags (`supports failing upload on conflict: 1`) come from this build's Info.plist |
| Drive request surface (auth, pagination, change feed, retry, ranges, multipart + resumable upload, mutations, exports) | **344 package tests, 0 failures, 14 skipped** against a stub transport: they prove the bytes CloudDisk sends and Drive's documented response shapes. **And the live behaviour has now been seen** — listing, the changes feed and its anchors, whole-file and ranged reads, upload, rename, move and trash were exercised against a real account in `docs/ACCEPTANCE_TEST_REPORT.md`, which is also how two stale assumptions in the suite were found: seven field names in our requests do not exist in Drive v3, and the tests had encoded them as the contract |
| Drive service against the live API | **run by hand against a real account** (acceptance report T2–T13). `LiveDriveSmokeTests` (14 cases) still *skip* unless `CLOUDDISK_LIVE_CLIENT_ID` + `CLOUDDISK_LIVE_REFRESH_TOKEN` are in the environment, so they are not what proved it; running them deliberately is the way to make that coverage repeat automatically |
| Shared keychain usable at runtime | **verified at runtime**: the entitlements of both bundles are identical (`59YP46BFR2.dev.rohitsah.clouddisk`, checked with `codesign -d --entitlements :-`), and the built app's "Credential sharing" row reads green — "The app and the File Provider extension read one keychain item". **Verified since the acceptance run**: a real refresh token round-tripping between the two processes — the app saves it, the extension uses it for every Drive read and the domain flipped to `needs-auth: yes` while signed out and back to `no` when signed in. What the run *also* found is that the save path itself was broken (`-25303`), so this row was true as a mechanism and false in practice until `6c2498a` |
| Finder browsing with real credentials | **verified** (acceptance report T5–T7): CloudDisk appears under *Locations*, the window opens, and the mount lists the account's real 52 root objects item for item, including entering a nested folder with 18 children. Two defects stood in the way and are fixed in the tested binary: My Drive children parented to the real folder id rather than `root`, and directories with an empty `fileSystemFlags` rendering as mode `--x` |
| Provider read path (`item(for:)`, `enumerateItems`, `enumerateChanges`, `fetchContents`, `fetchPartialContents`, `importDidFinish`) | **stub-verified end to end** through `CloudDiskProviderCore` + `DriveEnumerator`, and **now observed serving the real `fileproviderd`**: the acceptance run read the extension's own os_log for root, folder, trash and working-set enumerations, page and anchor tokens, fetches caused by Finder and Quick Look, and invalidations. **Still unverified**: enumerating a folder larger than one page |
| Full-file download on open | **verified against real Drive bytes** (T11): a dataless JPEG fetched on demand, `cp` completing in 2 s with 293,336 bytes that `file` identifies as a real 780×1040 JPEG. This path was completely broken before — the transport deleted the destination before moving bytes and the catch-all reported the local failure as a network outage — and the fix is `DownloadedFile.place(from:to:)` |
| Upload/rename/move/delete/trash | wired into `createItem`/`modifyItem`/`deleteItem` and stub-verified, including conflict detection producing a "conflicted copy" instead of an overwrite and every write failure reaching the activity log with the user's own filename as the subject; **and driven through the real mount** (T12): create, write, rename, move, duplicate and delete each landed where the shell said, with the app's activity list recording the corresponding Drive operation |
| Write permission enforcement | **stub-verified rules** (`WritePolicy` + the drive layer's delete check): an explicit `false` in `canEdit`/`canMoveItemOutOfWorld`/`canAddChildren`/`canTrash` refuses before the request goes out, the trash flag outranks an editable permission, a destination folder's own rights are checked because the system only validates the item being moved, and a denied save is reported as `fileWriteNoPermission` rather than a read code. **Unverified**: Google's real `capabilities` payload per share type (viewer, commenter, shared-drive organizer) — the account used for the acceptance run owns its own Drive, so only the owner case has been seen; and whether `fileproviderd` ever writes an item the last listing said was read-only, which is the only case these checks catch on top of the advertised capabilities. Deliberate rule: absent permission data is *not* treated as a ban, so the server stays the authority for anything CloudDisk cannot prove |
| Cache measurement (what the Finder location costs on disk) | **stub-verified logic, unverified system calls**: `OfflineStore.inventory()` is tested against real files on real disk (allocated blocks via `totalFileAllocatedSize`, folder blocks excluded, a declared 5 MB object contributing its 4 KB of blocks, unnameable paths reported as a floor rather than as zero). **Unverified**: that the materialized-items enumerator paginates as assumed (it answered one short page here, so only the first-page start at the empty `Data` page has been seen), that a partially materialized object reports allocated bytes below its declared length on a real domain, and every write-side call. `DomainCacheSmokeTests` targets exactly these calls read-only, with a deadline; it now lives in the app-hosted `CloudDiskTests` bundle (`xcodebuild -scheme CloudDisk test`) because `NSFileProviderManager.domains()` answers for the calling process, and **passed there against the mounted domain**: the materialized set answered, every named path existed, the inventory was internally consistent. **Still unverified**: pagination of the materialized set beyond one page, partially materialized objects reporting allocated bytes below their declared length, and every write-side call |
| Eviction ("Clear cached files") | **stub-verified rules**: a pinned item is never offered (eviction stops at the first non-evictable child of a folder), folders are not offered, each refusal code becomes its own sentence (`.nonEvictable`, `.unsyncedEdits`, `.noSuchItem`, `EBUSY`) instead of a silent skip, an unexpected error is reported as a failure, and one refusal does not stop the sweep. **Observed on a live mount** (acceptance report T14): an unpinned file evicted, the inventory's byte count fell, and a refused item surfaced as its own refusal sentence rather than being skipped silently — though the refusal that run produced was the defect below, not a correct one. **Unverified**: `.unsyncedEdits` and `EBUSY` in the wild, and a folder eviction stopping at a child. The run did find and fix a real defect here — releasing a pin left the file un-evictable forever, because a pin change did not move `metadataVersion` and FPFS therefore never re-read the policy |
| Offline pinning ("Keep offline") | **stub-verified**: a pin publishes `.downloadEagerlyAndKeepDownloaded`, signals the parent container, asks for the whole object, and is persisted in shared state that the extension reads when it enumerates; a pin whose shared write fails is reported as not-in-effect rather than as a promise. **Unverified**: that FPFS holds those bytes across a reboot, and that a pinned **folder**'s `.inherited` children really cascade (Apple's stated rule, never measured here). Also by design: Finder's own "Keep Downloaded" writes File Provider's preference, not CloudDisk's pin set, so a file pinned in Finder is invisible to CloudDisk's list and the reverse |
| "Local cache" status row | **run against a mounted domain on this machine, with real content in it**: the row read **3.9 MB in 3 files** for a signed-in account and matched `du -k`'s block counts file for file, it fell as items were evicted, and after the Status screen's *Rebuild* it read "Finder is holding no CloudDisk file on this Mac — everything is online-only" with "Clear cached files" correctly disabled at zero evictable items (the row once counted the mount point itself as materialized content, which was a defect). **Unverified**: an inventory that spans more than one page of materialized items, and a partially materialized object reporting fewer allocated bytes than its declared length |
| Offline write queue | not a CloudDisk structure, and none was built: File Provider's replication engine journals a pending change, survives an extension restart, and replays it into `createItem` with `.mayAlreadyExist` — which is what the reimport matching answers. **Unverified**: that replay after a kill of `fileproviderd` mid-write — a signed-in domain on a working mount now exists on this machine, but stopping the system daemon mid-operation was not performed against a live account |
| Partial materialization (`fetchPartialContents`) | wired into the extension and stub-verified: aligned window, the requested extent only, `retrievedRange` reported, short or unaligned answers refused, Workspace exports served whole, strict-version requests refused before transferring. **Now observed on a live mount** (acceptance report T9): `fileproviderd` does request aligned extents — a real MP4 played through `range=0+16384 … extent=0..<1048576` requests and still reported `compressed,dataless` with 0 allocated blocks afterwards, so the system's sparse-file behaviour matches what the code assumes. **Still unverified**: an interrupted partial read, and a strict-version request against a real domain |
| Byte-range streaming in the built-in player | **verified at the AVFoundation layer with a real encoded file**: a WAV served only through ranged reads reaches `readyToPlay` with the correct duration, decodes the samples at a 4 s seek position, and fails the item when the object is refused. **And live** (acceptance report T9): a 48,723,878-byte MP4 from the real account played in the in-app sheet, with CoreMedia reporting frames displayed on screen and `du -k` still reading **0** blocks afterwards, so the file was never materialized — the fetch log shows `extent=0..<1048576` windows. Getting there cost a crash: the app target never linked AVKit, where `AVPlayerView` lives. **Unverified**: seeking inside the player, and a third-party byte-range client (VLC/IINA) against the same object |
| Finder Quick Look / in-app preview | **verified live** (acceptance report T8, T10): a dataless PDF and JPEG both rendered, in Finder's space-bar Quick Look and in the app's own preview sheet, after the extension logged the fetch each demand caused (`bytes=279,946` and `bytes=293,336`). Both of the two open questions closed: Quick Look *can* read a path inside a sandboxed app's File Provider replica — but only after a narrow read exception was added to `pro.entitlements`, because the first attempts were sandbox denials inherited by `QuickLookUIService` — and preview triggers a **whole-object** materialization, not a partial one, which is why the preview path fetches the bytes itself rather than waiting on Quick Look's helper |
| App screens (Status / Files / Activity) | **rendered and read on this machine**: the built app was launched and all three sections were captured. Status showed the Finder location green at `~/Library/CloudStorage/CloudDisk-CloudDisk`, the extension serving this build, credential sharing green, and the account/quota rows naming the missing sign-in; Files showed its signed-out state (breadcrumb, disabled toolbar, `ContentUnavailableView` + Connect); Activity showed its empty state, which reading the write paths confirmed is true rather than a failed read — activity lines come only from real data operations and none has run. Two layout defects were found this way and fixed (the Files stack floating mid-window; Activity's empty state rendered as a list row) |
| Files screen against a real Drive folder | **walked with a signed-in account** (acceptance report T7–T9, T13, T14): 52 real rows, entering `Family` and seeing its 18 children, preview, play, *Keep offline*, the rename sheet and *Move to trash* each driven from the context menu, with the working/finished/refused status sentences appearing as the operations ran. **Unverified**: `searchable` search, "Load more" over a folder larger than one page, the ticket that drops a page arriving after the user moved on, and pin refresh. `FileBrowser`'s keep-offline outcome sentences and their agreement with `PinOutcome.succeeded` are covered by app-hosted `FileBrowserSentenceTests` |
| Persistence across logout/restart of macOS | **partly verified**: quitting and relaunching the built app leaves the domain mounted at the same path and still served by the same build, and the status rows re-read correctly from shared state without re-registering — now also asserted automatically: every `xcodebuild test` run launches a freshly built `CloudDisk.app` over the domain an earlier build registered, and the domain-identity, single-domain, mounted-path and served-by-this-build cases all pass without anything re-registering. **Unverified**: a machine reboot with the location mounted, and sign-out → sign-in leaving no stale domain. Both are on the manual list. The acceptance run did add the two properties a reboot depends on: **the credential and the sync cursor survive process death** — a freshly spawned provider resumed from `44955`, and later from `44961`, instead of asking Drive for a new start token — and **the system spawns the extension on demand with the app killed**, `launchd: Successfully spawned CloudDiskProvider … because launch job demand`, answering a read of a dataless file. CloudDisk is not a login item, so that is the boot condition short of a reboot |
| Out-of-band change propagation | **measured** (acceptance report T13): an edit made outside File Provider reaches the mount in seconds to minutes, and the bound is Google's changes feed, not CloudDisk's timer — the poll that fired one second after a rename returned `returned=0` and the same edit appeared two minutes later. The app nudges every 120 s and immediately after its own mutations. **Two gaps**: a brand-new object created elsewhere was never measured, because no second Drive client was available here; and with the app quit, nothing in CloudDisk polls Drive at all — the location then updates only when the system or the user causes an enumeration |
| The mount can be hijacked by another build | **observed three times** (T1): LaunchServices claims `dev.rohitsah.clouddisk` per bundle *path*, and every `xcodebuild` build or test run registers its own copy, which silently rebinds the domain to a Debug/DerivedData or `build/dd` copy. Recovery is `lsregister -u <competing copy>` then `lsregister -f -R -trusted dist/CloudDisk.app`, verified with `fileproviderctl dump`. A user who only ever runs the shipped `dist/CloudDisk.app` never meets this |
| Stale replica folders from re-registration | **observed**: re-registering while the mount point was occupied left five unmounted `~/Library/CloudStorage/CloudDisk-CloudDisk (…)` folders — one per re-registration — holding materialized copies of real files. They are not domains (`fileproviderctl dump` lists exactly one) and are inert, but they keep disk and look like the live location; only the live folder carries `com.apple.file-provider-domain-id`, which `xattr -l` shows. Nothing deletes them, and this build does not try |
| Developer ID signing + notarization + DMG distribution | **not possible on this machine**: only an Apple Development certificate is installed, so the distributed build will be ad-hoc/development-signed and will not install on another Mac without extra steps |
| Mac App Store distribution | not attempted (File Provider + sandbox rules differ, and no App Store profile exists) |

## Development-machine notes

- The provider record once pointed at a pre-production bundle left in
  `…/Build/Products/Debug/pro.app.pre-clouddisk-stale`, which is why rebuilt copies had to be moved to
  that path to be served. That is no longer true: the current `CloudDisk.app` re-registered the domain
  and the status screen reports *this* build as the server. The stale and backup bundles are still on
  disk and are inert **while nothing runs them** — launching one hijacks the mount (it presents its own
  `…/CloudStorage/pro-CloudDisk` location), so quit any copy before testing a new build. Check with
  `pgrep -lf "Debug/.*CloudDisk.app/Contents/MacOS/CloudDisk"`.
- A clean machine (or a fresh user account) does not have this problem: the first `addDomain` call
  records the app's own appex.
- `~/Library/Group Containers/group.dev.rohitsah.clouddisk` cannot be listed from a shell without Full
  Disk Access — `ls` returns *Operation not permitted*, not an empty directory. An empty-looking result
  there is a permissions answer, not evidence that the extension wrote nothing; read the shared state
  through the app instead.

