# Testing CloudDisk

Three automated surfaces exist, and each one exists because part of the system cannot be reached
from the others. Everything not automated is listed in `docs/KNOWN_LIMITATIONS.md` — this file never
reports a skip as a pass.

## 1. The Drive layer, without the network

```sh
swift test --package-path CloudDiskKit
```

**344 tests, 14 skipped, 0 failures** (state at the end of the acceptance run described in
`docs/ACCEPTANCE_TEST_REPORT.md`). The seam is `HTTPTransport` → `StubTransport`, which scripts
Drive's replies and records every request, so tests assert *what
bytes the real API would receive*: pagination and page tokens, the changes feed and its anchors,
byte-range reads, multipart and resumable upload, mutations, Workspace export links, rate-limit
retry (the `reason` field, not the status code, decides), the 401 → refresh → retry path, token
refresh coalescing and revocation. The 14 skips are `LiveDriveSmokeTests`, which need
`CLOUDDISK_LIVE_CLIENT_ID` + `CLOUDDISK_LIVE_REFRESH_TOKEN` in the environment and are skipped by
default so an ordinary run never touches the network. The live behaviour they would measure has since
been measured by hand against a real account — see the acceptance report — but these 14 cases still
have to be run deliberately to count as passing.

## 2. The File Provider domain, inside the app

```sh
xcodebuild -scheme CloudDisk -destination 'platform=macOS' test
```

**14 tests, 0 skipped, 0 failures** on this machine, run from `CloudDiskTests/` — the app target's
hosted bundle, because `NSFileProviderManager.domains()` answers for the calling process and only
`CloudDisk.app` holds the App Group and the domain:

- `DomainCacheSmokeTests` — the real system's materialized set answered, every path it named was
  on disk, the inventory was internally consistent. Read-only, with a deadline.
- `DomainPersistenceTests` — the registered domain still carries `CloudDiskConfig`'s display name
  and trash flag; there is only one such location; the mounted root is under `~/Library/CloudStorage`
  and exists; the extension that answered the heartbeat lives inside this build. Each case skips
  (with the reason in the skip message) rather than failing when its subject does not exist — e.g. no
  registered domain on a fresh machine.
- `FileBrowserSentenceTests` — the five "keep offline" outcome sentences stay distinguishable, the
  refusals do not read as kept promises, and they agree with `PinOutcome.succeeded`.
- `KeychainPersistenceTests` — the real save/update/delete path of `KeychainCredentialStore`, added
  after the acceptance run found that every live sign-in failed with `-25303`. These three are hosted
  for a reason of their own: a plain test binary has no keychain access group and answers `-34018` to
  every data-protection call, so the failure is only reachable inside the signed app.

Running this suite re-registers the Debug copy with LaunchServices, which can silently move the
domain off the bundle under test. After any `xcodebuild … test`, confirm with
`fileproviderctl dump | grep -A1 dev.rohitsah` that the `bundle URL` still names the copy you mean,
and re-register it with `lsregister -f -R -trusted` if it does not.

## 3. The whole app, built

```sh
xcodebuild -scheme CloudDisk -destination 'platform=macOS' build          # Debug
xcodebuild -scheme CloudDisk -configuration Release build                 # what dist/ is built from
```

Both configurations build green and warning-free (the Release log's only two warnings are the
standard AppIntents metadata-processor notices, which appear for any app that does not use
AppIntents).

## What only a signed-in human can test

This list has now been walked once, against a real account, on this machine:
`docs/ACCEPTANCE_TEST_REPORT.md` is that record — action, observation, log evidence and verdict per
item, plus the eleven defects it found. The status marks below are that run's findings.

1. **Sign in** — Connect, complete consent, return; status screen green, quota row shows real usage.
   **Done** (T2, T3). Found the `-25303` credential-save defect that made every real sign-in fail.
2. **Browse** — Finder sidebar *Locations → CloudDisk*: folders list, thumbnails, entering nested
   folders, search in the app's Files screen, "Load more" over a folder larger than one page.
   **Done** except two: search and "Load more" over a second page were not exercised (T5–T7).
3. **Download** — double-click a file in Finder; it opens with the bytes fetched on demand.
   **Done** for the fetch-on-demand path (`cp` of a dataless file, T11); opening a file into a
   third-party application was not.
4. **Preview** — Quick Look (space bar in Finder, and the in-app preview sheet); for video, seek in
   the in-app player and in Quick Look. **Done** for PDF and JPEG in both places (T8, T10); seeking a
   video inside Quick Look was not tried.
5. **Third-party player** — open a video from the mounted location in VLC/IINA and seek; this is the
   byte-range path without CloudDisk's own player. **Not done.**
6. **Upload** — drag a file into a Finder window of the location; create, rename, move, duplicate,
   delete; confirm each lands on drive.google.com. **Done** (T12), confirmed against Drive's own API
   answers and the app's activity log rather than the web UI.
7. **Offline** — "Keep offline" on a file (and a folder), wait for the download, then disconnect the
   network and open the file; "Clear cached files" in the app; confirm pinned items survive it.
   **Done** for a single file, the inventory and eviction (T14); not with the network disconnected,
   and not for a folder.
8. **Sync** — change or delete a file on another device; confirm the mounted location updates
   without re-mounting. **Done** for changes the app itself makes, which bypass File Provider and are
   therefore genuine out-of-band edits (T13). Not done from a second device — none was available here
   — and a brand-new object created elsewhere was not measured.
9. **Restart** — reboot the Mac with the location mounted; it must still be there and still serve
   this build. Signing out and back in must leave no stale domain. **Not done**: it needs a reboot.
   The half that does not — the system launching the extension on demand with the app killed — is
   verified (T15).
10. **Conflicts** — edit the same file offline in two places; expect a "conflicted copy", never a
    silent overwrite. **Not done.**

Anything still marked not done keeps its row in `docs/KNOWN_LIMITATIONS.md`.
