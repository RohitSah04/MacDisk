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

## Phase 1 — Foundation (in progress)

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

## Phase 2 — Drive service

Full v3 surface with pagination, range downloads, resumable uploads, changes feed, exports,
`about.get` for storage, retry/backoff, and an error taxonomy that maps to File Provider codes.
Unit-tested against a stub transport.

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
