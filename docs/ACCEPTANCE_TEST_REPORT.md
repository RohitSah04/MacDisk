# CloudDisk acceptance test report

Real-world acceptance run against a live Google Drive account. Every verdict below comes from an
observation of the running system — `ls` on the mounted folder, a Finder window, `os_log` emitted by
the extension itself, `fileproviderctl dump`, crash reports, or the app's own screens. Nothing here
is inferred from unit tests: those are reported separately in `docs/TESTING.md`.

| | |
| --- | --- |
| Run | 2026-10-31 21:40 → 2026-11-01 00:20 (IST), continuous |
| Machine | macOS 26.2 (26B123), Apple Silicon, File Provider version 4838.41.1 |
| Build under test | Release bundle at `/Users/rohitsah/Documents/pro/dist/CloudDisk.app`, `codesign --verify --deep --strict` clean |
| Serving bundle | `fileproviderctl dump` → `bundle URL: ~/Documents/pro/dist/CloudDisk.app/Contents/PlugIns/CloudDiskProvider.appex`, `available system wide: 1`, exactly one LaunchServices claimant for `dev.rohitsah.clouddisk` |
| Account | the signed-in Google account, reported by the app as 69.7 GB used of 5.5 TB |
| Drive content | a real My Drive with 52 root objects, nested folders, PDFs, JPEGs and MP4s — no demo data was created beyond the probes named below |

Automated suites at the end of the run: **344 package tests, 14 skipped, 0 failures** and
**14 app-hosted tests, 0 failures**. The 14 skips are `LiveDriveSmokeTests`, which need real
credentials and only run on demand; the ground truth they would have measured — listing, fetching,
partial ranges, the changes feed — is what this report measures directly against the live account.

## Verdicts

| # | Test | Verdict |
| --- | --- | --- |
| T1 | Install and launch the Release build | PASSED, after clearing a blocker |
| T2 | Interactive Google sign-in | PASSED, after finding a credential-store defect |
| T3 | Credential persists securely | PASSED |
| T4 | File Provider domain registration | PASSED |
| T5 | Finder → Locations → CloudDisk | PASSED |
| T6 | Root shows real Drive contents | PASSED, after finding a parenting defect |
| T7 | Nested folders list correctly | PASSED, after finding a folder-mode defect |
| T8 | Image and PDF preview | PASSED, after finding two defects |
| T9 | Streaming in CloudDisk's player | PASSED, after finding a crash |
| T10 | Finder Quick Look | PASSED, after finding a dataless-item defect |
| T11 | Download on demand | PASSED, after finding a blocking defect |
| T12 | Upload / rename / move / copy / delete | PASSED |
| T13 | Sync after changes made outside File Provider | PASSED, after finding a sync gap |
| T14 | Offline pinning and eviction | PASSED, after finding a false-promise defect |
| T15 | Persistence across a Mac restart | **NOT TESTED** — needs a restart; the app-not-running half is verified |
| T16 | This report | DELIVERED |

---

## T1 — Install and launch

**Action.** Build Release, `ditto` it to `dist/CloudDisk.app`, `codesign --verify --deep --strict`,
`lsregister -f -R -trusted`, `open`.

**Observed.** The window rendered, but the Finder location was dead: `ls` on
`~/Library/CloudStorage/CloudDisk-CloudDisk` hung, `fileproviderd` logged
`could not resolve URL while initializing a bundle record!`, and both `addDomain` and `removeDomain`
failed with "The application cannot be used right now."

**Cause.** LaunchServices held claims on `dev.rohitsah.clouddisk` from two bundles that no longer
exist — a `MyApp.app` from an unrelated project that reused both our bundle ID and our extension ID,
and a parked stale copy. Every `xcodebuild` run re-registers a fresh copy, so the daemon had bound the
domain to a path that had been deleted.

**Fix and result.** Unregistered the dead claims, rebuilt, redeployed, re-registered only `dist/`.
Status screen green on all three rows; the mount carries the `com.apple.file-provider-domain-id`
extended attribute. This also exposed two genuine product defects, both fixed in the tested binary:
`AppCore` could not reach its own repair path when `addDomain` failed, and
`CloudDiskDomain.unregister` refused to act on an unlisted domain — which is exactly the poisoned
record case.

**Recurrence, and why it matters.** During this run the same hazard returned twice, from two different
directions, and each time it silently moved the domain off the shipped bundle:

- `xcodebuild -scheme CloudDisk test` re-registers the **Debug** copy under
  `~/Library/Developer/Xcode/DerivedData/…`, and the daemon rebound to it. `fileproviderctl dump`
  showed `bundle URL: ~/Library/Developer/Xcode/DerivedData/…/Debug/CloudDisk.app/…`.
- `xcodebuild -derivedDataPath build/dd build` registers the **build/dd Release** copy, which is
  byte-identical to `dist/` but a different path, and the daemon bound to that instead.

Both were repaired with `lsregister -u <competing copy>` followed by
`lsregister -f -R -trusted dist/CloudDisk.app` and a relaunch. The final state is the one in the table
above: one claimant, `dist/` serving. **The shipped bundle is only the bundle the daemon names**, so
any acceptance run must check `fileproviderctl dump` rather than assume the copy it launched is the
copy in use. That check is now written down: `docs/INSTALL.md` has a section for it, *Checking which
copy is actually serving the location*, and `docs/TESTING.md` repeats it after the hosted-test command.

## T2 — Interactive Google sign-in

**Action.** Press *Connect…*, approve the ASWebAuthenticationSession hand-off, complete Google's
account chooser and the full-Drive consent in the browser.

**Observed.** The first attempt failed **inside our process**, after Google returned the code:
`OSStatus -25303`. OAuth itself had succeeded — the consent screen showed "to continue to CloudDisk
macOS", our client ID and a fresh PKCE challenge.

**Cause.** `KeychainCredentialStore.save()` passed the whole query template as `SecItemUpdate`'s
attributes dictionary. `-25303` is `errSecNoSuchAttr`: the data-protection keychain refuses a class,
service, account, access group and the `kSecUseDataProtectionKeychain` option as *updatable*
attributes — and, crucially, answers that even when no item exists, where it must answer
`errSecItemNotFound`. So the insert branch that would have stored the token never ran, and every real
sign-in failed.

**Why the app did not see it.** The status screen's `probe()` writes a bare item and never calls
`SecItemUpdate`, so "Credential sharing" stayed green while every credential save failed. Three hosted
tests (`CloudDiskTests/KeychainPersistenceTests.swift`) now reproduce the real path; they are hosted
because a plain binary has no keychain access group and answers `-34018` to every data-protection
call. Red before the fix, green after. Committed as `6c2498a`.

**Result after the fix.** Sign-in completed and the app immediately read live data: 69.7 GB of 5.5 TB,
account identified.

## T3 — Credential persists securely

**Action.** Quit the app and the extension, relaunch, read the account state. Separately, search the
system log for token material.

**Observed.** The cold start reads the account straight from the keychain — no consent page, no
"Connect" prompt — and this held across more than six full app+extension restarts during this run,
including deploys that replaced the binary underneath a running session. `log show` over 15 minutes of
activity contains **no token-shaped strings**. `~/Library/Application Support` and the App Group
container were checked for plaintext leftovers from the prototype's `UserDefaults` token store; the
migration deletes them on launch.

## T4 / T5 — Domain registration and the Finder location

**Action.** Inspect the daemon's own record and open the location from Finder's sidebar.

**Evidence.** `fileproviderctl dump`:

```
dev.rohitsah.clouddisk.CloudDiskProvider
  + available system wide: 1
  + supports enumeration: 1
  + supports FPFS: 1
  + read-only: 0
  + document group name: group.dev.rohitsah.clouddisk
  + bundle URL: ~/Documents/pro/dist/CloudDisk.app/Contents/PlugIns/CloudDiskProvider.appex
domain: …
  + features: repl,syncTrash
  + alive (33525) via ExtensionKit for:
     enumerator of …/root … name=Finder
      enabled:      yes
      needs-auth:   no
```

Finder lists CloudDisk under *Locations*, the window opens, and the daemon reports a live root
enumerator *held by Finder itself*. `needs-auth: no` while signed in, and the same field read
`needs-auth: yes` while signed out during the T1 phase — the daemon's own view of the session matches
the app's.

## T6 — Root shows real Drive contents

**Action.** Compare the app's own Drive listing against `ls` on the mount.

**Observed.** First result: the app reported **52** objects, Finder showed **1**. The daemon's database
contained exactly one child of root, and a fresh domain re-registration imported exactly one item
again — so the extension was genuinely returning one item, not the daemon dropping 51.

**Cause.** Drive reports every My Drive child's parent as the real folder id
`0AI…9PVA` (elided), while the provider addresses that same container as `root`. 51 of 52 items were
therefore parented to a container that does not exist in the replica and were discarded silently.
Fixed by aliasing the observed root folder id to the root container
(`ProviderIdentity`/`ProviderServices.observeRootListing`), with regression tests.

**Result.** `ls -1 | wc -l` on the mount returns 52, matching Drive item for item.

**Also found here, before the parenting fix, and worth keeping in mind:** the extension was sending
seven field names that Drive v3 does not define — `removes`, `picture`, `newPageToken`, `mutationId`
among them — and Google answered the very first enumeration with `HTTP 400: Invalid field selection
removes`. The unit tests had encoded those fictional names as the expected contract, so the whole suite
was green against an API that had never accepted the request. A generated schema table
(`DriveV3FieldSelectionTests`) now validates every production field selection against Google's own
discovery document.

## T7 — Nested folders

**Action.** Enter `Family` (18 children) in Finder and in the app.

**Observed.** The folder existed but would not list. `ls -l` on the mount showed the directory node at
mode `--x`: traversable, unreadable — while root and Trash were `rwx`. The FPFS database already held
all 18 children, so the extension's data was fine; the *mode* the replica gave the directory was not.

**Cause.** Folder items were reported with `fileSystemFlags: []` while files reported
`.userReadable`, and FPFS renders an empty flag set on a directory as `--x`. Fixed by giving folders
the readable flag. Folders materialised by the older build keep the stale mode, so the app now offers
the supported recovery (evict and re-import / *Rebuild*), which was used and verified here.

## T8 — Image and PDF preview

**Action.** Preview a PDF and a JPEG from the app's Files screen and from Finder.

**Observed.** Two distinct defects:

1. `Sandbox: CloudDisk(22136) deny(1) file-read-data ~/Library/CloudStorage/…/<personal filename>.pdf` and the
   same denial inherited by `QuickLookUIService`. The pin had worked (`fetch done bytes=2006256`, 1.9 MB
   on disk) yet the preview stayed a placeholder, because the sandboxed app could not read its own
   Finder location. The sandbox/network/user-selected keys come from Xcode build settings merged with
   `pro/pro.entitlements`, so a narrow exception was added there rather than opening the sandbox up.
2. With the read fixed, Quick Look's helper still gave up on a **dataless** item instead of waiting for
   File Provider to fetch it — Finder's space bar does wait, the helper does not. Fixed by having the
   preview path request the bytes itself.

**Result.** A dataless PDF: waited, fetched **279,946 bytes**, rendered the real page. The JPEG renders
with real pixels once bytes are on disk.

## T9 — Streaming in CloudDisk's player

**Action.** Right-click `<personal recording>.mp4` → *Play*, then screenshot at intervals and
watch disk usage of the mount.

**Observed.** The app crashed on the first attempt (`CloudDisk-2026-10-31-230039.ips`). Cause: SwiftUI's
`VideoPlayer(player:)` renders through `AVPlayerView`, which lives in AVKit — and the app target never
linked AVKit, so the class was absent at runtime. Fixed by adding `-framework AVKit` to
`OTHER_LDFLAGS` in the project, verified with `otool -L` on the built binary.

**After the fix.** CoreMedia frame scheduling shows decoded frames reaching the display continuously —
`PTS 7.792 s … displayed at layer time 7.793 s … on glass for 49.998 ms`, then 7.833 s, 7.875 s,
7.917 s — and three screenshots taken ~6 s apart differ by content hash, so the picture is moving.
The 48,723,878-byte MP4 still reads `compressed,dataless` with `du -k` reporting **0** blocks after
playback: streaming consumed byte ranges, never the file. The extent path is logged on the fetch side
(`fetch done … extent=0..<1048576`) and covered by `StreamingPlaybackTests` (3 tests).

**Not covered.** Third-party players (VLC, IINA) seeking the same file — that exercises a different
byte-range client and remains on the manual list in `docs/TESTING.md`.

## T10 — Finder Quick Look

**Action.** Select a PDF, then a JPEG, press space in the open Finder window.

**Observed.** Both render real content; the extension logged the fetches Quick Look's demand caused:
`fetch done 1uTSV0FR5zkrl… bytes=293336` (image, 286 KB) and
`fetch done 1ymYwzZT5dQWC… bytes=279946` (PDF). Screenshots `t10a-quicklook.png` and
`t10b-quicklook-image.png` captured from the window show the rendered page and the rendered photo.

## T11 — Download on demand

**Action.** `cp` a dataless JPEG out of the mount and hash it; open a file that has never been fetched.

**Observed.** This was the most serious defect of the run. The copy failed outright:
`cp: … fcopyfile failed: Operation timed out`, leaving a 0-byte file whose hash is the empty-string
SHA-1 (`e3b0c442…`) while the source still read `compressed,dataless`. Nothing could be downloaded, so
nothing beyond listing was reachable.

**Cause.** Two wrongs stacked in `HTTPTransport`. The file-transfer path did an unconditional
`removeItem(at: destination)` before moving URLSession's temporary file into place — and the
destination is *not* expected to exist, so the ordinary case threw. The catch-all then wrapped anything
that was not a `DriveError` as `DriveError.network`, and the provider's error bridge maps that code to
`NSFileProviderError.serverUnreachable` (`ProviderErrorMapper.swift:47`) — so a local file-management
failure reached the system as a network outage, and on that code the system marks the domain offline
and backs off instead of retrying.

**Fix.** `DownloadedFile.place(from:to:)` removes the destination only when it exists, and only
`URLError`s may be reported as network failures — a local error stays local so the user can retry.

**Result.** The same command completes: `cp exit=0` in 2 s, `/tmp/t11-downloaded.jpg` at 293,336 bytes,
`file` identifying a real 780×1040 baseline JPEG, and the extension logging
`fetch begin 1uTSV0FR5zkrl… whole` → `fetch done … bytes=293336`. The source item loses its
`dataless` flag.

## T12 — Upload, rename, move, copy, delete

**Action.** Through the mount only: create `ZZ CD T12 A` and `ZZ CD T12 B`, write `t12-note.txt`
(26 bytes), rename it to `t12-renamed.txt`, move it between the folders, copy it, delete it; read the
app's Activity list afterwards.

**Observed.** Each step landed where the shell said it had — `A` empty after the move, `B` holding the
renamed file, the copy present with the same 26-byte content
(`CloudDisk T12 write probe`). The app's own activity log records each as a separate Drive operation:
`Created — ZZ CD T12 A`, `Uploaded — t12-note.txt`, `Renamed — t12-renamed.txt`,
`Created — ZZ CD T12 B`, `Moved — t12-renamed.txt`, `Uploaded — t12-copy.txt`, plus the downloads the
reads provoked. Writes that Drive will not honour are refused with a sentence rather than attempted;
the refusal rules (`WritePolicy`) were built against the discovery document's two parent-dependent move
flags, and the honest rule is "refuse only when neither flag allows any move" — refusing on
`canMoveItemOutOfDrive` alone produced false refusals.

## T13 — Sync after changes made outside File Provider

**Action.** The app's own *Rename* and *Move to Trash* commands write straight to Drive and never pass
through File Provider, which makes them genuine out-of-band changes. Five were performed and the mount
plus an open Finder window were polled:

| Change | Made at | What the provider log shows | Landed | Latency |
| --- | --- | --- | --- | --- |
| root rename → `…MOVED.txt` | 23:48 | polls began `anchor=44950` at 23:48:36, 23:49:29 and 23:50:31; the 23:52:31 poll began at `anchor=44951` — Drive entered the edit into the feed between those two polls | 23:54 | ~6 min, most of it Drive's feed |
| root rename → `…SYNC.txt` | 23:57:13 | `23:57:14 changes done workingSet returned=0 updated=0 deleted=0 anchor=44951 more=false` (feed had not caught up) → `23:58:57 changes done workingSet returned=1 updated=1 deleted=0 anchor=44952 more=false` | 23:59:14, **in the already-open Finder window, without reopening** | 2 min |
| trash `…SYNC.txt` | ~00:00:21 | `00:00:21 changes done workingSet returned=1 updated=1 deleted=0 anchor=44953 more=false`, then the daemon enumerated the trash container: `00:00:22 items done trash returned=7 published=7 more=false` | gone from root by 00:00:59, present in the domain's `.Trash` | ~38 s |
| nested rename → `…NESTED.txt` | 00:03:37 | `00:03:38 changes done workingSet returned=1 updated=1 deleted=0 anchor=44955 more=false` | 00:03:50, after the folder's own `items begin/end container(1aFz…)` | 13 s |
| nested rename → `…FINAL.txt` | 00:12:40 | `00:12:42 changes done workingSet returned=1 updated=1 deleted=0 anchor=44961 more=false` | 00:12:48 | 8 s |

One `changes done` line per poll is not the whole story: the first row above is timed by *which anchor
each poll started with*, because the build running at 23:48 emitted only a bare `changes done workingSet`
and could not say whether Drive had returned the edit. The token also moves unevenly — `44953 → 44955`
carried one change — because Drive's change IDs count feed entries, not our edits.

The trash is carried as an **update whose item reports `trashed`**, not as `deleted=1`: Drive's feed
still returns the file object with its trash flag, and File Provider moves the row into the domain's
own `.Trash` rather than dropping it. `publish` sends `didDeleteItems` only for records that arrive
with `removed` set or that Drive then answers with 404.

**Found first: there was no sync at all.** Nothing polled Drive while the app was open — a change made
elsewhere appeared only when Finder happened to re-enumerate. Added
`AppCore.startLocationSyncWatch()` (a 120-second nudge for the root container and the working set,
[pro/AppCore.swift:170](file:///Users/rohitsah/Documents/pro/pro/AppCore.swift#L170)), and made the
app's own mutations nudge immediately
([pro/FileBrowser.swift:235](file:///Users/rohitsah/Documents/pro/pro/FileBrowser.swift#L235),
[pro/FileBrowser.swift:251](file:///Users/rohitsah/Documents/pro/pro/FileBrowser.swift#L251)). The
nudge alone does not make a change visible: Drive's changes feed itself lags the mutation, from a few
seconds to several minutes, and the first poll after a rename often returns zero changes (measured:
`returned=0` at 23:57:14 for a rename made at 23:57:13). Propagation is therefore bounded by
Drive's feed latency, not by our timer.

**Then the counters showed what the log could not.** The changes path logged only `changes done`,
which cannot distinguish "Drive had nothing" from "the reply was dropped" from "the anchor did not
move". `DriveEnumerator` now reports what Drive returned and what reached the observer —
`changes done workingSet returned=1 updated=1 deleted=0 anchor=44961 more=false` — and
`ObserverGate.perform` answers whether the gate was still open, so a batch dropped by invalidation is
counted as dropped rather than as published.

**Defect fixed while reading those counters.** An invalidated enumerator could still spend Drive
requests: `track(Task { … })` handed over an already-created task, and a `Task` starts running the
moment it is created, so `cancel()` arrived after the body was in flight — `ProviderCoreTests` measured
1–2 requests for an enumeration the system had already discarded. The work is now created inside the
same lock that `invalidate()` takes (`DriveEnumerator.start(gate:dropped:)`), which makes the order
total: either invalidation wins and no task exists, or the task exists and gets cancelled. The
`requestCount == 0` assertion is deterministic now. The anchor rule was also consolidated into
`anchorAfter(_:fallback:)` so both changes paths take Drive's terminal `newStartPageToken` and fall
back to the resume token only for a truncated drain; `testAQuietChangesFeedStillMovesTheAnchorForward`
guards it.

**Honest boundary.** A change made on another device reaches the mount through the changes feed, and
the feed lags. Rename, trash and nested-folder renames were all observed to propagate (the table
above). A brand-new object created elsewhere was not separately measured, because no second Drive
client was available on this machine: a new item appears when the container next enumerates (folder
open, refresh, or the domain's own re-import), and the working-set update that carries it was verified
only for items File Provider already knows. `docs/KNOWN_LIMITATIONS.md` now carries that distinction as
its own row, together with the related gap: with the app quit, nothing in CloudDisk polls Drive at all,
so the location then updates only when the system or the user causes an enumeration.

## T14 — Offline pinning and eviction

**Action.** *Keep offline* on a PDF, watch bytes arrive, read the Status screen's own inventory, press
*Clear cached files*, then release the pin and clear again.

**Observed.** Pinning downloads for real (`fetch done … bytes=2006256`). The inventory read exactly
**3.9 MB in 3 files**, matching the on-disk block counts, and only one of the three was still pinned.
*Clear cached files* freed one unpinned file and refused the second — which is where the defect was:
**releasing a pin left the file permanently un-evictable**. A pin is provider-side metadata, so the
item's `metadataVersion` has to change with it; without a version change FPFS never re-reads the
policy and keeps treating the file as user-requested. Fixed by flipping the version with the pin state
(covered by the test that asserts `item.itemVersion.metadataVersion` differs from the lazy item's).
Because FPFS only restates the policy on a re-read, the wording users actually see was also corrected
so it no longer promises an immediate release, and the remedy it points to — the Status screen's
*Rebuild* — was run and did release all three stuck copies, leaving the mount healthy and the cache
reading honestly empty.

## T15 — Persistence across a Mac restart

**NOT TESTED as specified**: the test is a restart of macOS, and restarting the machine in the middle
of this run would have destroyed the session and the state under test. What was verified instead is
the property a restart depends on — that neither the container app nor any user action is needed for
the location to serve files:

- **The extension is launched by the system, on demand, with the app dead.** Both processes were
  killed (`pgrep` counts: app 0, provider 0), then a dataless file was read from the mount and `cat`
  returned the real bytes in 2.8 s. The system made the process, not the app:
  `00:13:11.178 … exited due to SIGTERM | sent by pkill[33469], ran for 67578ms`, and nine seconds
  later `00:13:20.376 … Successfully spawned CloudDiskProvider[33490] because launch job demand`. That
  process's first own log line is the read it was launched to serve:
  `00:13:20.445 … fetch begin 1EZXSWoLquMKhSpp… range=0+16384 align=16384 strict=false`. CloudDisk is
  **not** a login item, so this is exactly the state at boot: no app running, location serving.
- **The domain is registered in the system's own store**, not in the app: one provider record, one
  domain, `enabled: yes`, replica under `~/Library/CloudStorage`, root carrying
  `com.apple.file-provider-domain-id`.
- **The credential survives process death** (T3), and the sync cursor survives too. The provider
  process that replaced the killed one began `changes begin workingSet anchor=44955` at 00:11:08 —
  the token its predecessor had been using — and the on-demand process of 00:13:20 continued from
  `44961` at 00:13:45 rather than asking Drive for a fresh start token.

**Remaining risk a real restart would test:** the domain binds to a bundle *path*, and this run showed
the binding moving to whichever copy Xcode registered last (T1). If `build/dd` or a DerivedData copy is
deleted while `dist/CloudDisk.app` stays in place, a clean boot should still mount — that is the single
assertion worth confirming by hand. Restart the Mac, log in, and check that the CloudDisk location
opens without the app running and without any re-registration or re-consent.

## T16 — This report

Delivered as `docs/ACCEPTANCE_TEST_REPORT.md`.

The other documents were then corrected to agree with it, because several of them still described the
pre-run state: `docs/TESTING.md` (344 package + 14 hosted tests, the `fileproviderctl dump` check after
any test run, and each manual checklist item marked done or not done by this run),
`docs/KNOWN_LIMITATIONS.md` (the signed-in rows moved from *unverified* to *verified* with the evidence
that moved them, plus three new rows: out-of-band propagation, the mount being hijacked by another
build, and the stale replica folders this run left behind), `docs/RELEASE_NOTES.md`, `README.md`, and
`docs/INSTALL.md`.

---

## Defects found by this acceptance run

Every one of these was invisible to the automated suites, and two of them made classes of feature
impossible:

1. **Credential save failed on every real sign-in** — `SecItemUpdate` given non-updatable attributes
   (`-25303`), with the status screen's probe too shallow to notice. Three hosted tests added.
2. **Seven Drive v3 field names did not exist** — the first real enumeration answered
   `HTTP 400: Invalid field selection removes`; the unit tests had encoded the fictional names and were
   green against an API that never accepted them. Schema-generated guard test added.
3. **51 of 52 root items were invisible in Finder** — My Drive children are parented to the real folder
   id, not to `root`.
4. **Nested folders were unlistable** — directories with an empty `fileSystemFlags` render as mode
   `--x`.
5. **No file could be downloaded** — the file-transfer path deleted the destination before moving
   bytes into place, and the catch-all relabelled that local failure as a network outage; `cp` timed
   out leaving a 0-byte file.
6. **The app crashed on streaming** — SwiftUI's `VideoPlayer` renders through `AVPlayerView`, which
   lives in AVKit, and the app target never linked that framework.
7. **Previews could not read the app's own Finder location** — sandbox denials inherited by
   `QuickLookUIService`.
8. **Quick Look gave up on dataless items** instead of waiting for the fetch.
9. **Nothing polled for remote changes** — out-of-band edits appeared only when Finder felt like it.
10. **Releasing a pin left a file un-evictable forever** — pin state did not move `metadataVersion`.
11. **An invalidated enumerator kept spending Drive requests** — `Task` starts before it can be
    cancelled; the race was real, not theoretical, and is now impossible by construction.

Defects 1–10 were found while the feature was being tested, which is the point of the run. Defect 11 was
found by a test that had been passing by luck.

## State left behind

Test artifacts are still on the account and on disk, and none of them are automatic — please empty
Drive's trash and delete the folders you do not want:

- Drive probes: `00000 T13 probe*.txt` (one is in Drive's trash), `ZZ CloudDisk probe`,
  `ZZ CD T12 A`, `ZZ CD T12 B`, `t12-copy.txt`, `t12-renamed.txt`, `ZZ T13 before.txt`.
- `~/Library/CloudStorage/` holds **five stale, unmounted** folders of the form
  `CloudDisk-CloudDisk (31-10-26 10:17 PM)`, one per re-registration while the mount point was
  occupied (`31-10-26 9:50 PM`, `10:17 PM`, `11:29 PM`, `11:48 PM`, `01-11-26 12:13 AM`). They are not
  domains — `fileproviderctl dump` lists exactly one — but leftover replicas, and they contain
  materialized copies of real files. They were **not deleted**, because they hold data that looks like
  the user's. `xattr -l` on each distinguishes them: only the live `CloudDisk-CloudDisk` carries
  `com.apple.file-provider-domain-id`.
- Screenshots and scripts used as evidence are under `/tmp/cdt-acceptance/` and are not part of the
  repository.
