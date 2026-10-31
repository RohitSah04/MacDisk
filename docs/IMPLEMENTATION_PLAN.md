# CloudDisk — implementation plan

Ordered by dependency. Each phase ends with a green `xcodebuild` and, where possible, a green test
run. Status is recorded honestly: done / partial / unverified.

## Phase 0 — Audit (done)

- Read every project file, `project.pbxproj`, both Info.plists, both entitlements,
  `Package.resolved`, both schemes.
- Verified the baseline build succeeds and dumped the *signed* entitlements of both the app and the
  embedded appex.
- Git checkpoint `157479f`; `.gitignore` added for build products.
- Output: `docs/PROJECT_AUDIT.md`, `docs/ARCHITECTURE.md`, this file, `docs/KNOWN_LIMITATIONS.md`.

## Phase 1 — Foundation (done)

1. Create the `CloudDiskKit` local package (static library) with models, transport, typed errors,
   keychain credential store and token provider.
2. Wire the package into both targets in `project.pbxproj` (`XCLocalSwiftPackageReference` +
   `packageProductDependencies`), then confirm with a build rather than assuming it works.
3. Entitlements: add `keychain-access-groups` to the extension, switch both to the shared
   `$(AppIdentifierPrefix)dev.rohitsah.clouddisk` group.
4. Project config: macOS-only `SUPPORTED_PLATFORMS`/`SDKROOT` for the app target, drop the iOS-only
   `INFOPLIST_KEY_*` noise, `PRODUCT_NAME = CloudDisk`, display name, extension pipeline-depth keys.
5. Replace the App Group `UserDefaults` token bridge; delete the plaintext path entirely.
6. Scope change to `drive` plus the Cloud Console steps the user must perform.
7. Domain registration: single source of truth for the identifier, safe re-registration, explicit
   handling of "domain already exists", status surfaced to the UI instead of a dead `@State`.

**Exit criteria:** both targets build; no token appears in `UserDefaults`; keychain sharing is
proven by a unit test of the store's encode/decode path (real keychain access is exercised in the
launch test).

## Phase 2 — Drive service (done as far as this machine allows)

Full v3 surface with pagination, range downloads, resumable uploads, changes feed, exports,
`about.get` for storage, retry/backoff, and an error taxonomy that maps to File Provider codes.
Unit-tested against a stub transport.

**Verified (140 package tests, 0 failures, `swift test`; app + extension build with
`** BUILD SUCCEEDED **`).** These are stub-verified — the transport is scripted, so they prove the
requests CloudDisk *sends* and the decoding of responses Drive *documentedly* returns, not Google's
behaviour:

| Area | Proven by |
| --- | --- |
| Auth | cached token never touches the token endpoint; refresh token never appears in `Authorization`; 401 → refresh → replay exactly once; second 401 stops the loop; `invalid_grant` → reconnect, zero requests; 10 concurrent callers → 1 refresh; sign-out revokes then clears; `GoogleCredential` description hides both secrets; form-encoded refresh body, `expires_in` default, revoke endpoint |
| Enumeration | 3-page `allChildren` walk with `pageToken` progression and identical `q`; limit stops the walk; `pageSize`/`orderBy`/`supportsAllDrives`/`includeItemsFromAllDrives`/`fields` on the wire; trashed variants; search never reaching the transport |
| Change feed | multi-page drain keeping the terminal anchor; `resumeToken` truncation; `removes` semantics; missing start token throws; 410 `expiredStartPageToken` is *not* retried |
| Retry | 429 → success; 403 `userRateLimitExceeded` retried; 503 exhausting 3 attempts; permanent errors each costing exactly 1 request; `Retry-After` honoured, clipped by `maxDelay`, floored; exponential+jitter bounds; cancellation between attempts |
| Download | metadata-then-media with `writingResponseTo` and progress; `alt=media&acknowledgeAbuse`; folder refused; Google Docs routed to `/export`; no-export-format refused and leaves **no zero-byte file behind** |
| Ranges | 206 + `Content-Range` parse; 200 whole-object flagged (offset 0 not flagged); impossible windows rejected before any network call |
| Upload | multipart under 2 MiB in one request (envelope framing, MIME sniff, explicit override); resumable 3-chunk walk with exact `Content-Range` per chunk; server-reported accepted-offset resumption across 6 calls; no-progress stall aborts with "no progress"; zero-byte upload finalises `bytes */0`; missing `Location` → 1 call; `replaceContents` uses `X-HTTP-Method-Override: PATCH` |
| Mutations | create/rename/move/copy/delete bodies and queries; delete → trash with no `DELETE` present, purge only from an already-trashed item; conflict detection; version-token fallbacks `v:`/`m:`/`t:`; export preference table per Workspace type |
| Safety | malformed Drive ids cannot escape their path segment (`a%2F..%2F..%2Fchanges`); unsafe parent ids rejected by `nameContains`; HTML error bodies truncated to ≤320 chars with no newlines |

**Five production bugs were found by these tests and fixed** — each was a live failure mode, not a
test artifact:
1. `userRateLimitExceeded` (Google's actual 403 spelling) mapped to `permissionDenied`, so a
   retryable rate limit became a user-facing failure. Both spellings now match on a substring.
2. `delete(fileID:)` decoded the 2-field `id,trashed` response into `DriveFile`, whose `name` and
   `mimeType` are required — every trash/purge would have failed decoding. A purpose-built private
   `TrashState` resource is used instead.
3. The patch query sent a non-existent `keepRevisionInTime`, which Drive rejects outright →
   `keepRevisionForever=false`.
4. `CharacterSet.urlPathAllowed` keeps `/`, so an id containing a slash would retarget the request
   at a different endpoint. Path segments now strip `/ ? #`.
5. `nameContains` interpolated a caller-supplied parent id into a quoted `q` literal without
   validating it, unlike `children(of:)`.

**Unverified (credential-gated).** `LiveDriveSmokeTests` covers the same surface against the real
API — token exchange, paged enumeration of a real root, parallel enumeration under rate limits,
multipart and resumable round trips, mid-file byte ranges, content replacement, rename/move/copy,
trash-then-purge, changes feed, conflict detection, Workspace export, thumbnail links, invalid-grant
handling. **It has never been run.** Without `CLOUDDISK_LIVE_CLIENT_ID` /
`CLOUDDISK_LIVE_REFRESH_TOKEN` all 14 cases report `skipped`, and the suite run shows
`140 tests, with 14 tests skipped`. It costs nothing and creates only a folder named
`CloudDisk Test Scratch (safe to delete)`, which `tearDown` permanently deletes:

    CLOUDDISK_LIVE_CLIENT_ID=… CLOUDDISK_LIVE_REFRESH_TOKEN=… \
      swift test --filter LiveDriveSmokeTests

**Exit criteria met:** package builds, `swift test` green, both app targets still build. Not met, and
not claimable here: anything requiring a real Google account or a signed-in Finder session.

## Phase 3 — Read-only provider (done as far as this machine allows)

`item(for:)`, `enumerateItems`, `enumerateChanges`, `fetchContents`, `enumerator(for:)`,
`importDidFinish` and the trash/working-set containers all do real Drive work through
`CloudDiskProviderCore`; the appex (`CloudDiskFileProviderAgent`) is a translation layer over it.
Validated by driving the core with scripted Drive replies and the two observer objects the system
would hand the enumerator.

**Verified (229 package tests, 0 failures, 14 skipped; `swift build`, `swift build --build-tests`,
`xcodebuild -scheme CloudDisk` all green, `CloudDiskProvider.appex` embedded in the built app).**
Stub-verified again — the transport is scripted, so this proves CloudDisk's half of the File Provider
contract, not `fileproviderd`'s behaviour:

| Area | Proven by |
| --- | --- |
| Identity | Drive id ⇄ `NSFileProviderItemIdentifier` round trip, foreign identifiers rejected as `noSuchItem` without a request, virtual containers answered locally, version bytes namespaced per item and inside the system's length limit |
| Metadata | one request per file reused while a page is built, `contentPolicy` from pin state, trashed items advertising read/delete-without-trash so Finder offers "delete immediately", type resolution preferring a registered MIME over a conflicting extension and never handing Launch Services a synthesized `dyn.` type |
| Enumeration | paged `didEnumerate` → `finishEnumerating(upTo:)` with the next page token, root/trash container queries, a trashed folder listing the children Drive trashed with it, shortcuts published as their target (and still listed when the target cannot be read, rather than hidden) |
| Change feed | stored cursor reused without re-asking Google, changes → `didUpdate_items`/`didDelete_items`, truncated drain reporting `moreComing` with a **resume** anchor rather than rewinding, `importDidFinish` establishing the anchor exactly once, 410 expiring the anchor and dropping the stored token |
| Cancellation | an enumerator invalidated while its Drive request is in flight publishes nothing and never touches the released observer |
| Download | metadata-then-media, bytes on disk at the URL handed to the system, progress, folder refused before any transfer, a failed media request leaving no partial file and recording `.failure`, no token text in activity |
| Versioning | a `fetchContents` for a version Drive has moved past refused with `versionNoLongerAvailable` instead of answering with newer bytes; a still-matching version served normally |
| Writing | create folder/file (multipart envelope asserted on the wire), rename, move, trash-vs-purge, conflict detection producing a "conflicted copy" rather than an overwrite, tag/symlink/alias refused, non-empty folder delete refused with `directoryNotEmpty`. Drive's `files.copy` endpoint is stub-tested at the service layer but the provider never calls it — a Finder copy is a local clone followed by `createItem` with contents, which is what is tested here |
| Error bridge | every `DriveError` landing in `NSFileProviderErrorDomain`/`NSCocoaErrorDomain` with the documented code, so nothing becomes an infinite retry |

**Six defects found by this suite and fixed** — each was a live failure mode:
1. The enumerator called `didEnumerate`/`finishEnumerating` on observers after `invalidate()`. The
   system releases the observer when it discards an enumerator, so a Drive reply landing after that
   is a use-after-free in `fileproviderd`'s address space. Observers are now held behind a gate
   closed *before* the tasks are cancelled.
2. Conflict detection never fired. `uploadContent` compared the system's `baseVersion` against the
   server by UTF-8-decoding the version bytes — but those bytes are `SHA-256(item id)` prefix + token
   and are usually not valid UTF-8, so the decode returned nil and *every* edit looked unchanged.
   Finder would have silently overwritten a remote edit. The comparison now re-derives the version and
   compares `Data`.
3. `removes` was only honoured on the last page of a changes walk, so a purge that Google marks
   mid-feed left the app believing it still had a valid anchor.
4. An expired anchor was reported to the system but the stored cursor was never cleared, so every
   subsequent walk resumed from the same rejected token — a permanent loop.
5. Change enumeration drained up to 50 pages inside one `enumerateChanges` call, and the scoped
   enumerator finished by publishing the token it *started* from, rewinding the system's cursor on
   every cycle. Now a bounded 10-page drain returning the resume token.
6. `fetchContents` ignored `requestedVersion`, so a request for a specific version was answered with
   whatever bytes Drive held at that moment.

Fixes 1 and 6 were **mutation-verified**, as was shortcut resolution: deleting the gate close,
deleting the version check and neutering `resolveShortcut` each make the corresponding test fail
(test 1 initially passed without the fix, which is how the in-flight case and
`StubTransport.holdReply` came to exist).

**Not verified and not claimable here:** that Finder shows a folder, that a double-click downloads,
that restart keeps the domain mounted, that eviction works. Those need `fileproviderd`, a signed-in
Google account, and a UI session — recorded in `docs/KNOWN_LIMITATIONS.md`.

## Phase 4 — Streaming + previews

**Done as far as this machine allows** (261 tests, 14 skipped, 0 failures;
`xcodebuild -scheme CloudDisk` green). Four pieces:

| Piece | File | What it does |
| --- | --- | --- |
| Aligned extent math + placement | `Provider/PartialExtent.swift` | Turns the system's minimal range into a legal aligned window and writes the served bytes at the offset that window names |
| Ranged read to disk | `Drive/DriveService+Transfer.swift` | `downloadRange(fileID:offset:length:to:)` streams one `Range` into a file, 206 or a whole-object 200, and says which |
| Partial materialization | `Provider/CloudDiskProviderCore.swift`, `Provider/CloudDiskFileProviderAgent.swift` | `fetchPartialContents` + `NSFileProviderPartialContentFetching`, reporting `retrievedRange` so only the fetched window counts as materialized |
| Player streaming | `Streaming/DriveRangeReader.swift`, `Streaming/DriveAssetResourceLoader.swift` | One bounded read-ahead window (deliberately *not* a second content cache) behind an `AVAssetResourceLoaderDelegate` |

| Area | Proven by |
| --- | --- |
| Extent math | minimal range widened to the requested alignment, a range past the end answered with the whole item, a zero-length request still producing one block, `alignment: 0` treated as "everything is aligned", a range that runs past EOF clamped to the file not the alignment, and only an extent that *ends* at the object allowed to stop mid-block |
| Extent placement | an extent placed at its offset with the file reaching exactly the extent's end, an extent from byte 0 moved rather than copied, a short extent refused and leaving no file behind |
| Provider partial fetch | a `bytes 4096-8191` request for `{4196, 500}` of a 1 MB object with **two** Drive calls and 4 KB of transfer, `retrievedRange` matching it; a whole-object window taking the streaming download instead of a range; a 200 answer to a range request reported from byte 0; an extent too short to cover the request refused; an extent that covers the request but stops mid-block refused; a Google-native doc exported whole; a strict-version request refused on metadata alone; a folder refused |
| Range reads | sequential reads inside one window costing one request, a seek past the window fetching the window that contains it, a window at EOF clamped to what remains, a whole-object answer still read from the right place, a read past the end an error rather than empty bytes, a refused range reported with no partial window left |
| Player integration | **a real WAV, played through AVFoundation with nothing but ranged reads**: `AVPlayerItem` reaches `readyToPlay` with the right 10 s duration, `AVAssetReader` decoding from 4 s yields the samples that live at 4 s with a window fetched around that offset, and a refused object fails the item instead of hanging it. Every media request recorded is a `bytes …-…` range and none carries more than one window |
| Content type | the loader hands AVFoundation a **UTI**, because a MIME string outside Apple's table fails the asset with "Cannot Open" before a byte is read (verified with a standalone delegate probe: `audio/wav`, `audio/vnd.wave`, `audio/x-wav` and a nil type all refuse; the UTI loads) |

**Defects found in this phase and fixed** — all five were live failure modes:
1. `PartialExtent.aligned` read `length <= 0` as "the whole item", so any zero-length ask from the
   system would have transferred a 20 GB archive to answer it. Now `span = max(0, length)` with the
   whole-item answer reserved for a request that really does span the object.
2. `MediaExtent.plan` clamped only *unspecified* lengths to a chunk, so a bounded request for the
   whole object was served as one range — 114 688 bytes in the observed WAV run, 100 MB in the unit
   test. A single read would have pulled an entire large file into memory. Both the clamp and the
   delegate loop now bound every request.
3. The loader passed Drive's MIME string to `AVAssetResourceLoaderDelegate`. AVFoundation refused the
   asset outright. It now takes a `UTType` and declares its identifier.
4. `DriveRangeReader` trapped (`SIGTRAP`, not a test failure) when a window arrived as a `Data` slice:
   a slice keeps its parent's index space, so `subdata(in:)` read outside the window. The window is
   normalized when stored.
5. The partial fetch reported any extent that covered the request, including one that ended mid-block,
   which is not a legal answer and would have let the system mark bytes materialized that never
   arrived. Found while writing the refusal test — the first version of that test passed with the
   guard deleted, which is why the covering-but-unaligned case is now a separate case.

Defects 2, 4 and 5 were **mutation-verified**: removing the chunk clamp fails both the plan test and
the playback window bound, removing the normalization crashed the suite, and `isAligned` neutered
fails the mid-block test.

**Not verified and not claimable here:** that Drive itself honours `Range` on a real object (the live
smoke test that would prove it skips without credentials), that `fileproviderd` calls
`fetchPartialContents` at the moments assumed, that Finder's Quick Look or a third-party player plays
a streamed video, or that an MP4/H.264 object streams in this app — the playback test uses a WAV
because this machine can synthesize one with known bytes at known offsets. Recorded in
`docs/KNOWN_LIMITATIONS.md`.


## Phase 5 — Read/write

**Done as far as this machine allows** (284 tests, 14 skipped, 0 failures;
`xcodebuild -scheme CloudDisk` green). The three write methods were already doing real API work from
Phase 3 (`create`/`modify`/`delete`, conflict detection against `baseVersion`, resumable uploads);
what this phase added is the permission layer that was missing between them and Google.

| Piece | File | What it does |
| --- | --- | --- |
| Write decision table | `Provider/WritePolicy.swift` | Reads Drive's `capabilities` flags and answers one question: is there *positive evidence* this write cannot land? An absent flag is an unknown, not a ban |
| Source-side enforcement | `Provider/CloudDiskProviderCore.swift` | `modify` judges the metadata it fetched a moment before the write, not the copy the system enumerated five minutes ago |
| Container enforcement | same, `create` + the move branch of `modify` | A destination that rejects children, or that is itself in the trash, fails with zero requests spent — the metadata cache already holds the answer from the listing that put it on screen |
| Delete permission | `Drive/DriveService.swift` | The `files.get` that already decides *trash vs. permanent* now also asks `capabilities(canTrash,canEdit)`, so a delete Google will refuse costs one round trip instead of two |
| Honest error codes | `Provider/ProviderErrorMapper.swift`, core | New `CoreError.writeNotAllowed` bridged to `NSCocoaErrorDomain` / `fileWriteNoPermission`; a 403 that arrives mid-write is re-labelled as a write failure |
| Complete activity record | core | Every write failure — upload, rename, move, delete, reimport replay — lands in the activity log with the user's own sentence as the detail, and deletes are logged with the filename rather than the Drive id |

| Area | Proven by |
| --- | --- |
| Write rules (8 pure cases) | field sets that write nothing are never judged on Drive's flags; `canEdit: false` refusing content, rename, move and all three together; `canMoveItemOutOfWorld: false` refusing *only* the move; the trash flag outranking an editable permission; four shapes of missing permission data all passing; both container rules; every sentence naming the item and none leaking an internal id |
| Provider write checks | a read-only item's edit refused after one request with no upload; a rename refused; a move refused; a drag out of the Trash refused; capability data absent → the upload still runs; Google's own 403 during an upload re-labelled with the server's sentence; create into a folder that rejects children, and into one that is trashed, costing **0** requests; a move into a read-only folder refused before the PATCH; a delete recorded as "notes.txt" |
| Drive delete permission | the trash-state request asks for the flags; `canTrash: false` refused with one request and neither a PATCH nor a DELETE; a permanent delete of an already-trashed object never blocked by an absent flag; no capability object at all → the write goes to Google; `canEdit: false` blocking a delete when `canTrash` is absent |
| Document metadata | a Google Doc's rename lands as one PATCH while its content stays pending and **no** `/upload/` request is made |
| Conflict handling (unchanged, re-verified) | the version comparison against `baseVersion`, the two-file resolution with its own activity line, `.failOnConflict` on macOS 26+, an acknowledged-but-empty content ask |

**Defects and asymmetries found in this phase and fixed** — the first was a live user-visible failure,
the rest are correctness or legibility:
1. `modify` returned *every* requested field as pending for a Google Workspace document, while
   `DriveFileProviderItem.capabilities` advertised `.allowsRenaming` and `.allowsReparenting` for it
   (both come from `canEdit`). A rename of a Google Doc in Finder therefore never landed and never
   failed — it silently reverted. Name and folder are ordinary Drive metadata, so they are written now
   and only `.contents` stays pending.
2. A denied save was reported with `fileReadNoPermission`, the code for "you cannot open this", because
   `DriveError.permissionDenied` had one mapping for both directions. Writes now raise
   `writeNotAllowed` → `fileWriteNoPermission`, whether the local check caught it or Google did.
3. The reimport replay of a local edit that survived a restart was the only write whose failure
   produced no activity record at all: the error reached the system, and the user's Activity list
   showed nothing.
4. `delete` recorded the raw Drive id as the activity subject, and refused-or-allowed was decided by
   Google's 403 alone even though the object's flags arrive in the very request that decides
   trash-versus-permanent.
5. `modify` compared the item's raw `filename` against Drive's name but sent the *materialized* one, so
   a name that APFS cleaning changes would re-PATCH a value the object already had. A tightening rather
   than a reachable defect for anything CloudDisk minted — those names arrive already materialized — and
   it is not mutation-verified.

Every guard this phase added is **mutation-verified**, in six runs: neutering `WritePolicy.refusal`
fails 10 tests and sends the refused writes to Drive — the stub runs out of replies, which is the proof
the request really would have gone out; turning "unknown" into "forbidden" fails 22 tests including
every pre-existing write test, which is the rule that keeps an ordinary edit working; and removing the
403 relabel, the `mayTrash` guard, either container check, or the delete-name and reimport records each
fails exactly the tests named above.

**Not verified and not claimable here.** That `fileproviderd` ever asks CloudDisk to write an item the
listing said was read-only — these checks are a backstop for a permission that changed after
enumeration, and on a signed-in Mac the system usually honours the advertised capabilities, so the new
refusals may never fire in practice; the tests prove the code path, not Finder's route into it. Google's
exact `capabilities` payload per share type (viewer, commenter, shared-drive organizer) — every rule
acts only on an explicit `false`, which is the safe shape but is not the same as having seen the real
responses. A Workspace-document rename being accepted by Drive in production. Server-side copy:
File Provider has no clone option in `createItem`, so a Finder copy of a dataless item materializes and
re-uploads; `DriveService.copy` is the tested `files.copy` primitive for CloudDisk's own browser, not a
path the provider uses. And the offline write queue: this is File Provider's journal, not a CloudDisk
structure — the replication engine persists the pending change, survives an extension restart and
replays it into `createItem` with `.mayAlreadyExist` (which is what the reimport matching exists for),
so no competing queue was built. Killing `fileproviderd` mid-write to watch that replay cannot be done
without a signed-in domain and is recorded as unverified.

## Phase 6 — Cache and offline

**Done as far as this machine allows** (319 tests, 17 skipped, 0 failures;
`xcodebuild -scheme CloudDisk` green). CloudDisk now answers "what is this Finder location costing my
disk?", "which of it can I get back?" and "keep this one offline" from File Provider's own store and
from APFS — never from a CloudDisk ledger, and never by holding a second copy of the bytes.

| Piece | File | What it does |
| --- | --- | --- |
| The system's side of the cache | `Cache/CacheSystem.swift` | One protocol for the five questions that are not about Google: what is materialized (`enumeratorForMaterializedItems`, pages starting at `NSFileProviderPage(Data())`), where each item lives (`getUserVisibleURL`), will you release it (`evictItem`), will you download it (`__requestDownloadForItem` with the whole-object range), and re-signal a container. `FileProviderCacheSystem` is the real thing; `UnavailableCacheSystem` answers an unmounted domain's way — an explanation, never a zero |
| Measurement | `Cache/OfflineStore.swift` | `inventory()` walks those rows, measures each user-visible path with `totalFileAllocatedSize` and produces `CacheInventory`: materialized / pinned / evictable bytes, counts, and an explicit `isExact` flag with the number of files whose bytes could not be named |
| Release | same | `releaseEligibleItems()` offers every non-folder, non-pinned row and classifies the system's answer into released / refused-with-a-reason / failed. `release(driveID:name:)` is the single-file version |
| Pinning | same + `Provider/DriveFileProviderItem.swift` | A pin is published as `contentPolicy`: `.downloadEagerlyAndKeepDownloaded` for kept-offline, `.inherited` otherwise, then the container is signalled so the policy reaches the disk replica and the item itself is asked for immediately |
| Shared vocabulary | `State/ProviderState.swift` | `pin` / `unpin` activity kinds, so "Kept offline" and "Released offline" appear in the user's log next to downloads and deletes |
| App wiring | `Provider/ProviderServices.swift`, `pro/AppCore.swift`, `pro/ContentView.swift` | `ProviderServices` owns the `CacheSystem` (real when a domain resolves, unavailable otherwise); `AppCore` publishes `localCache`, `lastEviction`, `refreshLocalCache()`, `clearLocalCache()` and `setKeepOffline(_:pinned:)`; the status window gained a "Local cache" row with the real figure, a Re-measure / Clear cached files pair, and the refusal sentences |
| No competing cache | — | Deliberately absent: no CloudDisk content store, no `materializedItemsDidChange` (CloudDisk publishes the whole changes feed as its working set, so implementing it would loop materialize → signal → drain), no macOS 27 `NSFileProviderNamespacePolicyMaterializeEagerly` (it would eager-download every file in the domain, the opposite of a virtual drive) |

| Area | Proven by |
| --- | --- |
| Measurement (8 cases) | a 4 KB file declared as 5 MB contributes its **disk** blocks and nothing else; pinned / evictable byte split over real files; a folder's own directory blocks are not counted as cached content; the mount point and the virtual namespaces are not counted as content at all; a path that is a directory on disk wins over a row that claims a file; an item with no path or a gone path reports `unmeasuredFileCount` and `isExact == false` instead of 0 bytes; pins are re-read from shared state on every call, so the extension's writes are seen; `UnavailableCacheSystem` and a truncated enumeration both throw rather than reporting an empty cache |
| Release (8 cases) | the pinned file is never even offered, because eviction aborts at the first non-evictable child; folders are never offered; each refusal code maps to its own sentence (`.nonEvictable`, `.unsyncedEdits`, `.noSuchItem` → already absent, `EBUSY` → open in another app); an unexpected error is a **failure**, not a refusal; one refusal does not stop the rest of the sweep; a released file whose size was unknown keeps the freed total a floor; a single named release touches exactly that identifier; the run writes one activity line and a run with nothing to free writes none |
| Pinning (7 cases) | pin → policy published, parent container signalled, whole-object download requested by identifier, activity line "Downloading now; kept offline afterwards"; trashed item signals Trash rather than its stale Drive parent; `.noSuchItem` from the download ask becomes "downloads as soon as Finder lists the file" and still counts as a kept promise; a refusal keeps the mark **and** logs a failure with the system's own sentence; unpin never asks for a download; a pin whose shared write fails is reported as not-in-effect and claims nothing downstream; with no domain the answer says the location is missing |
| Provider publishing (3 cases) | a pinned item carries `.downloadEagerlyAndKeepDownloaded` through `item(for:)`, an unpinned one inherits, and `items(from:)` reads the pin set once per page |
| App wiring (2 cases) | no manager ⇒ `ProviderServices.offline` throws `.unavailable` rather than returning an empty inventory; scripted system ⇒ the store reports exactly what the script said |

**Defects and traps found in this phase and fixed** — one found by the compiler, one found by running
the app against its own mounted domain, four near-misses:
1. `setPinned` wrote the pin with `try?`, so an App Group container that could not be written produced
   a successful-looking outcome *and* a download request for bytes nobody had promised to keep. A failed
   persist is now `.systemUnavailable`, the activity line is a failure, and no signal or download is
   claimed.
2. Unpinned items were published as `.downloadLazily`. That is an explicit child policy, and an explicit
   child policy overrides the container's — so "keep this folder offline" would have pinned the folder
   and left every file inside it evictable. Unpinned now means `.inherited`; two assertions written
   against the old value were corrected, and the reason is stated in the test that pins it down.
3. `NSFileProviderItem.documentSize` imports as `NSNumber??` (nullable *and* optional protocol
   requirement), so `documentSize?.int64Value` does not compile and a careless unwrap reads "no size"
   for an item that does have one. Both levels are handled explicitly.
4. `error as? NSFileProviderError` then `.code` is used for classification rather than comparing
   `NSError` codes: the provider-side error and the object that comes back through the bridge are
   different Swift types.
5. No pre-filter on `isUploaded` before eviction. It is an optional protocol requirement, and an absent
   `BOOL` reads as NO through the bridge — pre-filtering on it would have declared every item dirty.
   The system's own `.unsyncedEdits` refusal is what decides, and it is reported as "still holds
   changes that have not reached Google Drive" rather than as a failure.
6. The mount point counts as a materialized item. Found by running the app: an empty, signed-out
   CloudDisk domain reported its own root folder (and Trash) as cached content, so the row read
   "Zero KB in 0 files across 1 folder" — a number that is not a lie but is not an answer either.
   `inventory()` now drops container identifiers, and the empty-state sentence is keyed on
   `fileCount > 0` rather than on `items` being empty, because a domain can hold folder rows and no
   file bytes. Removing the filter makes the new test fail on two assertions.

Every guard added here is **mutation-verified** (nine mutants, seven caught by the named test, one —
forcing a released file's bytes to `nil` — caught by two others, and one provably equivalent: counting
a folder's bytes cannot change a total because folder rows never carry `allocatedBytes`, which is why
the folder test asserts that nil directly).

**What was run against the real system.** The built app was launched with this code in place, and the
"Local cache" row was read by a human eye: the domain registered and mounted at
`~/Library/CloudStorage/CloudDisk-CloudDisk`, `getUserVisibleURL` named that path, the
materialized-items enumerator answered — one page, containing the domain's own containers — instead of
hanging or throwing, and `OfflineStore.inventory()` turned that into a reading the UI displayed. That
run is what found defect 6, and a second run confirmed the fix reads as
"Finder is holding no CloudDisk file on this Mac — everything is online-only" with "Clear cached files"
disabled.

**Not verified and not claimable here.** Nothing was signed in during that run, so no Drive object was
ever materialized: the byte arithmetic over real content, the pinned / unmeasured / freed sentences, and
all three write-side calls (`evictItem`, `__requestDownloadForItem`, `signalEnumerator`) were never
asked of the live system, and a multi-page enumeration was never seen. Those are the calls inside
`FileProviderCacheSystem` that the scripted suite cannot reach. `DomainCacheSmokeTests` aims at the
read paths over a mounted domain, read-only and with a deadline so a silent system skips instead of
hanging — and all three cases **skip on this machine**, because `NSFileProviderManager.domains()`
answers for the calling process and a command-line test binary is not an app with CloudDisk's
entitlements. Running them needs an app-target context (Phase 8). Likewise unobservable
here: that FPFS actually holds `.downloadEagerlyAndKeepDownloaded` bytes across a reboot; that a pinned
folder's inheritance reaches its children (the rule is Apple's, the cascade is not measured); that a
partially materialized file reports allocated bytes below its declared length on a real domain (APFS
allocated the whole file for a hand-made sparse test, so the distinction is proven by the code reading
disk blocks rather than by an observed hole); and Finder's own "Keep Downloaded" menu item, which writes
File Provider's preference and **not** CloudDisk's pin set — the two are independent by design, so a
file pinned in Finder is invisible to CloudDisk's list and vice versa.

## Phase 7 — Production UI

**Built, and every screen looked at while the app was running** (319 tests, 17 skipped, 0 failures;
`xcodebuild -scheme CloudDisk` green and warning-free). The single status window became a
`NavigationSplitView` with three sections. Nothing on any of them is a demo row: each value is read from
the keychain, from File Provider, from Drive, or from the log the extension writes, and each missing
value says why it is missing.

| Screen | File | What it shows |
| --- | --- | --- |
| Status | `pro/StatusView.swift` (was `ContentView.swift`) | Six rows — account, Finder location, extension liveness, credential sharing, Drive quota, local cache — each with the real figure and the one button that can fix it, plus the extension's recent activity |
| Files | `pro/FilesView.swift` + `pro/FileBrowser.swift` | Drive's own listing, not a second index: breadcrumbs, folder navigation, pagination ("Load more"), `searchable` search, keep-offline marks read from the shared pin set, and a context menu for open / preview / play / reveal in Finder / keep offline / rename / move to trash |
| Activity | `pro/ActivityView.swift` | The whole log the extension writes into the App Group (up to 200 lines), read the same way the status card reads it — a download that is not in there did not happen |
| Preview | `pro/PreviewView.swift` | Quick Look pointed at the File Provider path for one object, so the system materializes what the preview needs |
| Player | `pro/PlayerView.swift` | `AVPlayer` over `DriveAssetResourceLoader` + `DriveRangeReader` — seeking is a range request, no local copy |

Two decisions that shaped the code rather than the pixels. `FileBrowser` is owned by `RootView`, not by
`FilesView`, because the folder the user was standing in belongs to the window and not to whichever
sidebar row is selected; and the browser drops a page that arrives after the user has moved on via a
ticket counter, so a slow Drive response cannot repaint a folder the user has already left. A failed
listing keeps the rows already on screen and says so in the status bar, rather than replacing real
content with an error.

**What was run against the real system.** The built app was launched, and all three screens were
captured and read:

- Status rendered every row from live state — Finder location green at
  `/Users/rohitsah/Library/CloudStorage/CloudDisk-CloudDisk`, "File Provider extension — Serving this
  build — last answer 4 minutes ago", credential sharing green, quota and account both saying plainly
  that no Google account is connected, and the local-cache row reading "Finder is holding no CloudDisk
  file on this Mac — everything is online-only" with "Clear cached files" disabled.
- Files rendered its signed-out state: the "My Drive" breadcrumb, the toolbar's up/refresh pair disabled,
  the search field present, and a `ContentUnavailableView` that names the missing dependency instead of
  showing an empty table.
- Activity rendered its empty state, and reading the shared container confirmed the empty state is true
  rather than a read failure: activity lines are written only by real data operations (`download`,
  `upload`, `create`, `rename`, `move`, `copy`, `delete`, `synchronize`, `pin`, `unpin`), and on this
  machine none has ever run against a Drive object.
- The app was then **quit and relaunched**, and the new process found the same domain still mounted and
  still served by the same build. That is an app-restart test, not a machine-reboot test — see below.

**Defects found by looking at the screenshots, not by the compiler.** Both were layout, and both were
invisible in a preview:

1. `FilesView`'s `VStack` floated in the vertical middle of the window. The listing area kept its
   intrinsic height, so a signed-out browser left the breadcrumb and the status bar sandwiching the
   empty state in mid-air. The first fix — a flexible frame on the whole stack — made the stack fill the
   window and still centered its contents; the frame belongs on the listing, so the listing takes the
   slack and the breadcrumb sits at the top. Confirmed by a second capture.
2. `ActivityView`'s empty state was a row inside the `List`, which reads as one more entry rather than
   as the absence of entries. It is now an overlay over the list area.

Also folded in while the screens were being separated: the relative-date formatting that three screens
each spelled their own way now lives in `DateText`, `DriveFile`'s `Identifiable` conformance moved to
the type that owns it (an app-side extension of two imported types warns), and the `AVPlayerItem` status
observation moved off KVO — a `Task { @MainActor in self?… }` inside a KVO handler warns about capturing
`self` concurrently, and `status` is not an async-loadable property on `AVPlayerItem`, so it is a
Combine publisher with a cancellable held by the model.

**Not verified and not claimable here.** The Files screen has never listed a real Drive folder, so none
of this has been seen to work: rows, entering a folder, "Load more" across a second page, search, the
context-menu actions, the rename sheet, keep-offline from the browser, reveal-in-Finder, open-with-default-app.
The preview sheet has never been opened and `QLPreviewView` has never been handed a URL — including the
question of whether the app's sandbox lets Quick Look read a File Provider path at all. The player has
never played: no object, no range request, no seek. `FileBrowser`'s logic (pagination, the stale-page
ticket, pin refresh, the outcome sentences) had **no test coverage of any kind** at this point, because
it lived in the app target and no app-target test bundle existed; Phase 8's bundle covers the sentence
wording and the `succeeded` agreement, not this logic. Unchanged from
Phase 6 and still true: the domain surviving an *app* relaunch is not the same claim as surviving a
*machine* reboot, and this machine was never rebooted with the domain mounted.

## Phase 8 — Validation

**A hosted test bundle exists, and the checks that skipped for two phases now run.** `CloudDiskTests`
(`com.apple.product-type.bundle.unit-test`, TEST_HOST `CloudDisk.app`) is the app target's own bundle:
`NSFileProviderManager.domains()` answers for the calling process, so a test has to run inside the app
that holds the App Group and the domain. `DomainCacheSmokeTests` moved here from the package for
exactly that reason and — with the domain registered by this build — **passed for the first time**: the
materialized set answered, every path the system named was really on disk, and the inventory was
internally consistent. The bundle is not part of `swift test`; run it with
`xcodebuild -scheme CloudDisk -destination platform=macOS test`.

`DomainPersistenceTests` (read-only: it skips rather than repairing what it is checking) asserts what
the status screen claims in words — the registered domain still carries `CloudDiskConfig`'s display
name and trash flag; there is only one location of that name; the mounted root really is under
`~/Library/CloudStorage` and really exists; and the extension that answered the heartbeat lives inside
this build, which is the check that catches the stale-bundle hazard this project actually hit.

`FileBrowserSentenceTests` covers the one piece of the browser a hosted bundle reaches without
credentials: the five "keep offline" outcome sentences stay distinguishable, the two refusals do not
read as kept promises, the sentences agree with `PinOutcome.succeeded` (a disagreement would show a
green checkmark over a failure), and unpinning says the bytes *may go* rather than that they stayed.

**Getting the bundle to build cost two fixes worth recording:**

1. A hosted test bundle may not also statically link the same package product as its host ("This will
   result in duplication of library code"), so the test target links no packages at all —
   `import CloudDiskKit` resolves through the host app's own linked product.
2. `PinOutcome` was a public type with an internal memberwise initializer, so no client could ever
   construct it; it now has a public `init(pinned:effect:)`, matching the other public values in
   `OfflineStore.swift`.

**One real defect, and it was in the test, not the product.** The mounted-path case first compared the
system's answer against `FileManager.homeDirectoryForCurrentUser` — which in the sandboxed test host
is `~/Library/Containers/dev.rohitsah.clouddisk/Data`, not the user's home. The system's answer,
`~/Library/CloudStorage/CloudDisk-CloudDisk`, was the correct one; the test now resolves the real home
from the password database. Recorded because "the test failed" and "the assertion was written against
the wrong home" are different facts, and only the second is a defect.

**What was run.** `swift test --package-path CloudDiskKit` → 316 tests, 14 skipped (live Drive),
0 failures — three fewer than Phase 7 because the smoke cases moved to the hosted bundle.
`xcodebuild -scheme CloudDisk -destination platform=macOS test` → **11 tests, 0 skipped, 0
failures** — zero skips means the domain was registered, mounted, and served by this build for every
assertion. The whole-app build is green and warning-free.

**Still not verified, and green tests do not change that.** The domain surviving an *app* relaunch —
every `xcodebuild test` launches a freshly built host over a domain registered by an earlier one — is
still not a *machine reboot*, which was never done. The smoke tests see the materialized set as one
page; the enumerator's pagination beyond the first remains assumed. `FileBrowser`'s remaining logic —
pagination, the stale-page ticket, pin refresh, the rename/move context actions — is still untested,
and the Files screen itself has still never listed a real Drive folder: covered sentences are wording,
not behaviour.

## Phase 9 — Release

`.app` artifact, DMG if signing allows, install/OAuth/test/limitation/release-checklist docs, final
report.

## Known hard dependencies on the user

| Needs user action | Why it cannot be automated here |
| --- | --- |
| Interactive Google sign-in in the running app | OAuth consent requires the user's browser session; no headless path |
| Google Cloud Console: add scope `drive`, publish/verify consent screen or add test users | Google-side configuration, and `drive` is a sensitive scope |
| Any Developer ID signing / notarization | Only an Apple Development certificate exists on this machine |
