# Testing CloudDisk

Three automated surfaces exist, and each one exists because part of the system cannot be reached
from the others. Everything not automated is listed in `docs/KNOWN_LIMITATIONS.md` — this file never
reports a skip as a pass.

## 1. The Drive layer, without the network

```sh
swift test --package-path CloudDiskKit
```

**316 tests, 14 skipped, 0 failures** (state as of the Phase 8 build). The seam is `HTTPTransport`
→ `StubTransport`, which scripts Drive's replies and records every request, so tests assert *what
bytes the real API would receive*: pagination and page tokens, the changes feed and its anchors,
byte-range reads, multipart and resumable upload, mutations, Workspace export links, rate-limit
retry (the `reason` field, not the status code, decides), the 401 → refresh → retry path, token
refresh coalescing and revocation. The 14 skips are `LiveDriveSmokeTests`, which need real
credentials (see `docs/OAUTH_SETUP.md`) and have never run on this machine.

## 2. The File Provider domain, inside the app

```sh
xcodebuild -scheme CloudDisk -destination 'platform=macOS' test
```

**11 tests, 0 skipped, 0 failures** on this machine, run from `CloudDiskTests/` — the app target's
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

## 3. The whole app, built

```sh
xcodebuild -scheme CloudDisk -destination 'platform=macOS' build          # Debug
xcodebuild -scheme CloudDisk -configuration Release build                 # what dist/ is built from
```

Both configurations build green and warning-free (the Release log's only two warnings are the
standard AppIntents metadata-processor notices, which appear for any app that does not use
AppIntents).

## What only a signed-in human can test

No Google credentials exist on the build machine, so every path that needs a real account has never
been exercised by a machine. The manual checklist, in the order the app presents it:

1. **Sign in** — Connect, complete consent, return; status screen green, quota row shows real usage.
2. **Browse** — Finder sidebar *Locations → CloudDisk*: folders list, thumbnails, entering nested
   folders, search in the app's Files screen, "Load more" over a folder larger than one page.
3. **Download** — double-click a file in Finder; it opens with the bytes fetched on demand.
4. **Preview** — Quick Look (space bar in Finder, and the in-app preview sheet); for video, seek in
   the in-app player and in Quick Look.
5. **Third-party player** — open a video from the mounted location in VLC/IINA and seek; this is the
   byte-range path without CloudDisk's own player.
6. **Upload** — drag a file into a Finder window of the location; create, rename, move, duplicate,
   delete; confirm each lands on drive.google.com.
7. **Offline** — "Keep offline" on a file (and a folder), wait for the download, then disconnect the
   network and open the file; "Clear cached files" in the app; confirm pinned items survive it.
8. **Sync** — change or delete a file on another device; confirm the mounted location updates
   without re-mounting.
9. **Restart** — reboot the Mac with the location mounted; it must still be there and still serve
   this build. Signing out and back in must leave no stale domain.
10. **Conflicts** — edit the same file offline in two places; expect a "conflicted copy", never a
    silent overwrite.

Each of these maps to a row in `docs/KNOWN_LIMITATIONS.md` stating that it is unverified.
