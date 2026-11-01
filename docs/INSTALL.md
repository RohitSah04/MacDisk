# Installing CloudDisk

CloudDisk is a native macOS app that mounts your Google Drive as a Finder location under
`~/Library/CloudStorage`. This page covers install, first run, update, and uninstall.

## What is in `dist/`

| Artifact | What it is |
| --- | --- |
| `dist/CloudDisk.app` | The Release build of the app and its File Provider extension |
| `dist/CloudDisk.dmg` | The same app on a disk image that also carries an `/Applications` symlink |

## Signing — read this before installing anywhere but this Mac

The bundle is signed with an **Apple Development** certificate (team `59YP46BFR2`,
`Apple Development: rohitsumit0231@gmail.com`). It is **not** signed with a Developer ID
certificate and **not notarized**, because no Developer ID account exists on the build machine.
`codesign --verify --deep --strict` passes; `spctl -a` **rejects** it. Consequences:

- On the machine that built it, it launches normally (the development certificate is trusted locally).
- On any other Mac, the first launch is blocked by Gatekeeper. There is no supported way to run an
  un-notarized, non-Developer-ID app on another machine beyond right-click → *Open* (which works on
  the same macOS version in practice but is an explicit user override, not a supported distribution
  channel). For real distribution, a Developer ID certificate and notarization are required — see
  `docs/RELEASE_CHECKLIST.md`.

## Installing

1. Mount `dist/CloudDisk.dmg` (double-click it) and drag `CloudDisk` into the `Applications` symlink —
   or copy `dist/CloudDisk.app` wherever you want it.
2. Launch CloudDisk once. On first launch it:
   - registers the File Provider domain (this is when the system starts the embedded
     `CloudDiskProvider` extension), and
   - shows the status screen with **Connect a Google account** — no Drive content appears until you
     sign in.
3. Click **Connect**, complete Google's consent screen in your browser, and return to the app.
   Within a few seconds the status screen turns green and `~/Library/CloudStorage/CloudDisk`
   appears in Finder's sidebar under *Locations*.

Requirements: macOS 14 (Sonoma) or later on Apple silicon; the build is `arm64`-only.

## What the app does to your Mac

- Registers one File Provider domain, identifier `CloudDisk-CloudDisk`, visible in Finder as
  **CloudDisk** under *Locations*.
- Stores one Google credential in the keychain, in the access group `dev.rohitsah.clouddisk`,
  readable only by CloudDisk and its extension.
- Writes shared state (pin set, activity log, sync cursor, heartbeat) into
  `~/Library/Group Containers/group.dev.rohitsah.clouddisk`.
- Creates no login item, no background daemon of its own, and no cache outside File Provider's own
  store. File *content* is materialized by the system, not by a CloudDisk cache — "Clear cached
  files" asks the system to evict, it does not delete anything of yours.

## Updating

Drag the new `CloudDisk.app` over the old one and re-launch. The domain is re-registered on launch
and the status screen verifies that the extension answering Finder lives inside the new build; if an
old copy is still running, quit it first (`pgrep -lf CloudDisk.app`).

### Checking which copy is actually serving the location

The system binds a File Provider domain to a bundle *path*, and LaunchServices will hand that binding
to whichever copy of the app registers itself last — including a build directory you never intended
to use. This was observed three times during the acceptance run, once from a `Debug` copy under
`DerivedData` and once from a second Release copy in a different folder. The symptom is not an error
message: the location keeps working and silently serves the other build.

```sh
/usr/bin/fileproviderctl dump | grep -A6 dev.rohitsah.clouddisk.CloudDiskProvider
```

Read the `bundle URL` line. If it does not name the copy you installed, unregister the copy that
claimed it and re-register yours:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -u /path/to/competing/CloudDisk.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f -R -trusted /Applications/CloudDisk.app
```

Re-registering while the old location is still mounted can leave an inert folder behind under
`~/Library/CloudStorage` named `CloudDisk-CloudDisk (31-10-26 10:17 PM)`. Those are not domains —
`fileproviderctl dump` lists exactly one — but they hold materialized copies of your files and keep
disk until you delete them. Only the live folder carries the `com.apple.file-provider-domain-id`
extended attribute, which is what `ls -ld@ ~/Library/CloudStorage` shows.

## Uninstalling

1. Launch CloudDisk and click **Sign out** — this revokes the Google grant and deletes the keychain
   credential.
2. Quit the app, then remove `CloudDisk.app`. Quitting matters: a running copy re-registers its
   domain on launch, and two copies fight over one Finder location.
3. Remove the File Provider domain record and the system's local store for it. This build of the app
   has no "uninstall" button, and the `fileproviderctl` on current macOS has no `remove` verb (it
   offers only dump/diagnose/evaluate/check/repair/obfuscate), so the supported route is the same
   API `CloudDiskDomain.unregister` wraps, run once from a shell:
   ```sh
   swift - 'primary-google-drive' <<'EOF'
   import FileProvider
   import Foundation
   let id = NSFileProviderDomainIdentifier(CommandLine.arguments[1])
   let domain = NSFileProviderDomain(identifier: id, displayName: "CloudDisk")
   NSFileProviderManager.remove(domain) { error in
       print(error.map { "remove failed: \($0)" } ?? "domain removed")
       exit(error == nil ? 0 : 1)
   }
   RunLoop.main.run(until: Date().addingTimeInterval(10))
   EOF
   ```
   **Not run on the build machine** — executing it there would unregister the domain the installed
   build is registered against, so the snippet is written from the API's contract, not from an
   observed run. (The domain identifier is `primary-google-drive`; the folder the system mounts is
   named after the hosting app, `CloudDisk-CloudDisk`.) Removing the domain tells the system to
   delete its replica store; if a leftover folder remains under `~/Library/CloudStorage`, delete it
   too.
4. Delete `~/Library/Group Containers/group.dev.rohitsah.clouddisk` (activity log, pins, sync
   cursor). Relaunch Finder if the sidebar entry lingers.
