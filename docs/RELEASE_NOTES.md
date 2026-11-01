# CloudDisk — final report

**Version 1.0 (1)** · macOS 14+ · arm64 · the bundle in `dist/` was built on the night of
31 October 2026 from Phase 8 (`c669a3f`), Phase 9 packaging, and the acceptance-phase fixes that run
produced. `HEAD` at the time of writing is `6c2498a` and those later fixes are uncommitted.

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
| Docs | `docs/` — architecture, implementation plan, known limitations, install, OAuth setup, testing, the real-account acceptance report, release checklist |

## What is verified, and by what

- **The Drive layer's wire behaviour** — 344 package tests, 0 failures, against a scripted transport
  that records the exact requests: pagination, anchors, ranges, multipart and resumable upload,
  mutation and conflict handling, Workspace exports, retry and the 401 path, plus a generated schema
  table that checks every field selection this build sends against Google's own discovery document.
  (`swift test --package-path CloudDiskKit`; the 14 live-API cases skip unless the live credentials
  are passed in the environment.)
- **The same paths against a real Google account** — `docs/ACCEPTANCE_TEST_REPORT.md` records a
  continuous 21:40 → 00:20 run on this machine: sign-in, the domain, Finder browsing of 52 real root
  objects and a nested folder, PDF and JPEG previews, MP4 playback over byte ranges, download on
  demand, create/write/rename/move/duplicate/delete through the mount, out-of-band sync measured five
  ways, and pinning with eviction. It found eleven defects, all fixed in the tested binary.
- **The Finder location on this machine** — the app registered the domain, Finder shows it at
  `~/Library/CloudStorage/CloudDisk-CloudDisk`, the extension answering the heartbeat
  lives inside this build, and the 14 hosted tests in `CloudDiskTests` assert the domain identity,
  its uniqueness, the mounted path, the served-by-this-build fact and the real keychain save path on
  every run (`xcodebuild -scheme CloudDisk test`).
- **The app's screens** — all three sections launched, captured and read with a signed-in account; two
  layout defects were found by looking at the captures and fixed.
- **Keychain sharing between app and extension** — the app's own probe, and a real refresh token saved
  by the app and used by the extension for every live Drive read.
- **Byte-range playback at the AVFoundation layer** — a real encoded file served only through ranged
  reads reaches `readyToPlay` and decodes after a seek — and the same behaviour observed on the mount
  with a live MP4 that never left `dataless`.
- **Persistence across an app relaunch** — quit and relaunch keeps the domain mounted and served by
  the same build, without re-registering; the credential and the sync cursor survive, and the system
  spawns the extension on demand when the app is killed.

## What is not verified — and is not claimed

Full list with reasons in `docs/KNOWN_LIMITATIONS.md`; the headline items:

- **A machine reboot** with the domain mounted — the app-not-running half is verified, the reboot is
  not, because performing it would have destroyed the acceptance session.
- **Sync from a second device** — the only out-of-band changes available to make were CloudDisk's own
  app commands, which do bypass File Provider. A brand-new object created elsewhere was not measured.
- **Third-party clients of the mount** — VLC/IINA seeking, opening a file into another application,
  and Finder's own "Keep Downloaded", which writes File Provider's preference rather than CloudDisk's
  pin set.
- **Pinning a folder**, and the eviction codes the run did not produce (`.unsyncedEdits`, `EBUSY`).
- **`fileproviderd`'s side of the contract** in the cases the run did not reach: pagination of the
  materialized set, a partially materialized object's allocated bytes, and replay after the daemon is
  killed mid-write.
- **Distribution** — see the next section; nothing here has been tested on a second Mac.

## Distribution status — stated plainly

The bundle in `dist/` is signed with an **Apple Development** certificate only. It is **not
notarized** and `spctl` rejects it: it is a development artifact, not a shippable product. It runs
normally on the machine that built it. What a real release additionally needs — Developer ID
certificate, notarytool, consent-screen verification for the `drive` scope — is listed with commands
in `docs/RELEASE_CHECKLIST.md`.

## How to take it from here

1. Restart the Mac with the location mounted and confirm it still serves without the app running and
   without re-registration or re-consent — acceptance item T15, the one manual test left undone.
2. Work down the rows still marked unverified in `docs/TESTING.md`'s checklist: a second Drive client
   making a change, a third-party player, pinning a folder, opening a pinned file with the network off.
3. Note that the acceptance fixes are **uncommitted** as of this writing (`HEAD` is `6c2498a`, the
   keychain repair); `dist/CloudDisk.app` contains the later code, so the bundle and the tree differ
   until they are committed.
4. For a real release, the Developer ID and notarization steps in `docs/RELEASE_CHECKLIST.md` remain,
   and the `drive` scope still needs Google's consent-screen verification (`docs/OAUTH_SETUP.md`).
