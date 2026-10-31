# CloudDisk — final report

**Version 1.0 (1)** · macOS 14+ · arm64 · built 31 October 2026 from commit `c669a3f` (Phase 8) and
the Phase 9 packaging on top.

CloudDisk mounts a Google Drive account as a native Finder location under
`~/Library/CloudStorage/CloudDisk-CloudDisk`, served by an `NSFileProviderReplicatedExtension`
bundled with a SwiftUI app. Browsing, previews, streaming, downloads, uploads, rename/move/delete,
offline pinning and eviction are all implemented through the system's own replication engine — there
is no parallel CloudDisk cache fighting File Provider for disk.

## What exists

| Piece | Where |
| --- | --- |
| `CloudDiskKit` — Drive REST v3 client (pagination, changes feed, byte ranges, resumable upload, retry, OAuth refresh, keychain), File Provider core, cache/offline store, shared state | `CloudDiskKit/Sources/CloudDiskKit` |
| File Provider extension | `CloudDiskProvider/` |
| SwiftUI app — status checklist, file browser, player, preview, activity log | `pro/` |
| App-hosted test bundle | `CloudDiskTests/` |
| Release artifacts | `dist/CloudDisk.app`, `dist/CloudDisk.dmg` |
| Docs | `docs/` — architecture, implementation plan, known limitations, install, OAuth setup, testing, release checklist |

## What is verified, and by what

- **The Drive layer's wire behaviour** — 316 package tests, 0 failures, against a scripted transport
  that records the exact requests: pagination, anchors, ranges, multipart and resumable upload,
  mutation and conflict handling, Workspace exports, retry and the 401 path. (`swift test
  --package-path CloudDiskKit`; 14 live-API cases skipped — no credentials on this machine.)
- **The Finder location on this machine** — the app registered the domain, Finder shows it at
  `/Users/rohitsah/Library/CloudStorage/CloudDisk-CloudDisk`, the extension answering the heartbeat
  lives inside this build, and the 11 hosted tests in `CloudDiskTests` assert the domain identity,
  its uniqueness, the mounted path and the served-by-this-build fact on every run
  (`xcodebuild -scheme CloudDisk test`).
- **The app's screens** — all three sections were launched, captured and read; two layout defects
  were found by looking at the captures and fixed.
- **Keychain sharing between app and extension** — verified at runtime by the app's own probe.
- **Byte-range playback at the AVFoundation layer** — a real encoded file served only through ranged
  reads reaches `readyToPlay` and decodes after a seek.
- **Persistence across an app relaunch** — quit and relaunch keeps the domain mounted and served by
  the same build, without re-registering.

## What is not verified — and is not claimed

Full list with reasons in `docs/KNOWN_LIMITATIONS.md`; the headline items:

- **Anything needing a signed-in Google account.** No credential exists on the build machine, so no
  Drive object has ever been listed, downloaded, uploaded, or synced from this build. The 14
  live-API tests have never run.
- **Video from real Drive in the built-in player** — the player sheet is built, the range loader is
  tested, but no row ever existed to press Play on.
- **Quick Look / the preview sheet** — never opened.
- **A machine reboot** with the domain mounted — only app relaunches were done.
- **`fileproviderd`'s side of the contract** (pagination of the materialized set, eviction codes in
  practice, partial-materialization requests) — the logic is tested against real files and scripted
  system answers; the system's own behaviour was only observed through the read-only smoke tests.

## Distribution status — stated plainly

The bundle in `dist/` is signed with an **Apple Development** certificate only. It is **not
notarized** and `spctl` rejects it: it is a development artifact, not a shippable product. It runs
normally on the machine that built it. What a real release additionally needs — Developer ID
certificate, notarytool, consent-screen verification for the `drive` scope — is listed with commands
in `docs/RELEASE_CHECKLIST.md`.

## How to take it from here

1. Follow `docs/OAUTH_SETUP.md` to put a test account on the consent screen.
2. Install `dist/CloudDisk.dmg` on the build machine and run the manual checklist in
   `docs/TESTING.md` — that checklist is the difference between "compiles and its tests pass" and
   "works".
3. Anything it fails, `docs/KNOWN_LIMITATIONS.md` predicts honestly; anything it passes upgrades a
   row there from unverified to verified.
