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

## Phase 3 — Read-only provider

Real `item(for:)`, `fetchContents`, paged `enumerateItems`, working-set change enumeration with
persisted anchors, `enumerator(for:)` returning nil with the right error for non-containers,
cancellation wired to the returned `Progress`, correct root container.
Validated by launching the app on this Mac and inspecting the registered domain.

## Phase 4 — Streaming + previews

`RangeReader` and `DriveResourceLoader` for the in-app player; `fetchPartialContents` for
system-driven partial materialization; per-path behaviour documented and separately tested.

## Phase 5 — Read/write

`createItem`/`modifyItem`/`deleteItem` doing real API work with capability enforcement, conflict
detection against `baseVersion`, and an operation/activity record for failures and retries.

## Phase 6 — Cache and offline

`contentPolicy` pinning, eviction of eligible cache, real cache-size reporting from the
materialized-items enumerator, no competing cache.

## Phase 7 — Production UI

Dashboard / Account / Storage / Activity / browser / player against live data. Demo rows deleted.

## Phase 8 — Validation

New `CloudDiskTests` target, full test run, launch test for Finder persistence, everything else
marked unverified with the reason.

## Phase 9 — Release

`.app` artifact, DMG if signing allows, install/OAuth/test/limitation/release-checklist docs, final
report.

## Known hard dependencies on the user

| Needs user action | Why it cannot be automated here |
| --- | --- |
| Interactive Google sign-in in the running app | OAuth consent requires the user's browser session; no headless path |
| Google Cloud Console: add scope `drive`, publish/verify consent screen or add test users | Google-side configuration, and `drive` is a sensitive scope |
| Any Developer ID signing / notarization | Only an Apple Development certificate exists on this machine |
