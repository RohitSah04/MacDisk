# CloudDisk — project audit

Audit performed on the repository as of checkpoint commit `157479f` ("Checkpoint: existing CloudDisk
prototype before production work"), before any production change.

## Toolchain actually installed

| Item | Value |
| --- | --- |
| Xcode | 27.1 (Build 27A9275) |
| Swift | 6.4 (swiftlang-6.4.0.34.1) |
| macOS SDK | MacOSX27.0.sdk |
| Deployment target (both targets) | `MACOSX_DEPLOYMENT_TARGET = 27.0` |
| Signing identity available | `Apple Development: rohitsumit0231@gmail.com (KH9867DZLR)` — development only, no Developer ID |
| Development team | `59YP46BFR2` (automatic signing) |

Baseline build command that succeeds today:

```
xcodebuild -project pro.xcodeproj -scheme MyApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

Result: `** BUILD SUCCEEDED **`, 1 unrelated warning (`Metadata extraction skipped, no
AppIntents.framework dependency found`).

## Repository contents

```
pro.xcodeproj                 project + 2 shared schemes (MyApp, CloudDiskProvider) + GoogleSignIn SPM pin
pro/                          app target "pro" (synchronized folder group)
  MyApp.swift                 @main, registers File Provider domain
  ContentView.swift           522 lines, SwiftUI sidebar UI + Google Sign-In, demo file list
  Info.plist                  GIDClientID + reversed client ID URL scheme
  pro.entitlements            app group, keychain access group
  Assets.xcassets             AccentColor only, no app icon
CloudDiskProvider/            app-extension target "CloudDiskProvider" (synchronized folder group)
  FileProviderExtension.swift NSFileProviderReplicatedExtension
  FileProviderEnumerator.swift NSFileProviderEnumerator
  FileProviderItem.swift      NSFileProviderItem
  GoogleDriveService.swift    Drive v3 list + get only
  Info.plist                  NSExtension dictionary
  CloudDiskProvider.entitlements  app group only
```

There is **no test target**, **no CI**, **no README**, and **no docs/** in the audited tree.
`.DS_Store` was tracked; a `.gitignore` for `build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`
was added in the checkpoint commit.

## Verified configuration (read from the project, not assumed)

Verified from `project.pbxproj` and from the signed build products:

- App target name is `pro`, `productName = MyApp`, `PRODUCT_NAME = $(TARGET_NAME)` → product is
  `pro.app`, **not** `CloudDisk.app`.
- `PRODUCT_BUNDLE_IDENTIFIER = dev.rohitsah.clouddisk`
- Extension `PRODUCT_BUNDLE_IDENTIFIER = dev.rohitsah.clouddisk.CloudDiskProvider`
- App Group `group.dev.rohitsah.clouddisk` on both targets (`REGISTER_APP_GROUPS = YES`).
- Extension is embedded: `pro.app/Contents/PlugIns/CloudDiskProvider.appex` exists in the built
  bundle, `NSExtensionPrincipalClass` resolves to `CloudDiskProvider.FileProviderExtension`, and
  `NSExtensionFileProviderDocumentGroup` matches the app group.
- Signed entitlements of the built app: sandbox, app group, network client,
  `keychain-access-groups = [59YP46BFR2.dev.rohitsah.clouddisk]`, user-selected files read-only.
- Signed entitlements of the built appex: sandbox, app group, network client,
  **no `keychain-access-groups` at all**.
- App target `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"` with
  `SDKROOT = auto`; extension target is `SDKROOT = macosx` only.
- App target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the extension target does not, so
  the same shared code would compile under different default isolation rules in each target.
- Swift package dependencies (resolved in `Package.resolved`): GoogleSignIn-iOS 10.1.0, plus
  AppAuth 3.0.0, GTMAppAuth 6.0.0, gtm-session-fetcher 5.3.1, app-check 12.0.0,
  GoogleUtilities 8.1.5, interop-ios-for-google-sdks 101.0.0. Only the app target links them.
- Domain identifier used at runtime: `primary-google-drive`, display name `CloudDisk`.
- OAuth client ID is committed in `pro/Info.plist`
  (`265151445816-ftndevk4ofq4bhasv77f3cujij41si4n.apps.googleusercontent.com`). A Google iOS
  client ID is not a secret, but the value is now in Git history and there is no template
  mechanism to change it per build.

## Functional defects found

These were confirmed by reading the code, not inferred.

1. **Downloads do not work at all.** `fetchContents(for:version:request:completionHandler:)`
   immediately returns `NSFeatureUnsupportedError`
   (`CloudDiskProvider/FileProviderExtension.swift:66-84`). Every attempt to open a file in Finder
   fails. This is the single most serious defect: the product can list files and nothing else.
2. **`createItem` reports success without doing anything.** It calls
   `completionHandler(itemTemplate, [], false, nil)` (`FileProviderExtension.swift:86-102`). Finder
   is told a file was uploaded when no Drive request was ever made. This is silent data loss.
3. **`modifyItem` and `deleteItem` return `NSFeatureUnsupportedError`**
   (`FileProviderExtension.swift:104-150`) while the product goal claims rename/move/copy/delete.
4. **`enumerateChanges` lies about synchronization.** `FileProviderEnumerator.swift:10-12, 60-68`
   returns a hard-coded anchor built from the constant string `"CloudDisk-v1"` and reports
   "no changes" for every anchor. Remote edits, renames and deletions are never propagated, and
   the working set is permanently stale.
5. **Pagination is parsed but discarded.** `GoogleDriveListResponse.nextPageToken` is decoded
   (`GoogleDriveService.swift:21-24`) and never used; `listFiles` returns one page (≤1000 items)
   and `finishEnumerating(upTo: nil)` ends enumeration. Any folder with more than 1000 children is
   silently truncated.
6. **Credentials are stored in App Group `UserDefaults`.** `ContentView.swift:441-465` writes the
   access token and its expiry into `UserDefaults(suiteName: "group.dev.rohitsah.clouddisk")`.
   `GoogleDriveService.accessToken()` reads it back. This is plaintext-on-disk token storage, and
   it directly contradicts the security requirement in the brief.
7. **The extension cannot refresh tokens.** Only the *access* token is shared. When it expires
   (~1 hour) the extension keeps sending an expired bearer token and every Drive call returns
   401; nothing recovers until the user re-signs-in in the app. There is no handling of
   `NSFileProviderErrorNotAuthenticated`.
8. **OAuth scope is read-only.** `ContentView.swift:24-25` requests
   `https://www.googleapis.com/auth/drive.readonly`, so upload/rename/delete would be rejected by
   Google even if the code existed.
9. **`DriveError` has no HTTP semantics.** `GoogleDriveService.swift:206-237` collapses every
   non-200 into `apiError(statusCode:message:)` with the raw body as the message. No distinction
   between 401 (auth), 404 (deleted remotely), 403/429 (rate limit), 5xx (retryable). Nothing can
   map to the File Provider error codes the system expects.
10. **No retry, no backoff, no timeout policy, no cancellation.** Every call uses
    `URLSession.shared` with default settings; the `Progress` objects returned by the extension are
    never observed for cancellation and the completion handlers in `item(for:)` still fire after
    cancellation.
11. **Item metadata is incomplete.** `FileProviderItem.swift` provides no `creationDate`, no
    `isUploaded`/`isDownloaded`, no `childItemCount`, and derives `contentType` with
    `UTType(mimeType:) ?? .data`, which maps every Google Workspace native type
    (`application/vnd.google-apps.document`, `.spreadsheet`, `.presentation`) to generic `.data`.
    `contentModificationDate` uses `ISO8601DateFormatter()` which does **not** parse the fractional
    seconds Google returns (`2026-10-29T23:12:04.500Z`), so modification dates silently become nil.
12. **Folders whose Drive ID is not `root` are fine, but shared-drive and "My Drive root" edge cases
    are not handled**: the query is built by raw string interpolation of the parent ID
    (`GoogleDriveService.swift:70-76`) with no escaping of `'` — a Drive ID cannot contain a quote
    today, but the query builder is not safe by construction, and `q` is not the right tool for
    pagination of large trees.
13. **Trashed files**: filtered out at query level (`and trashed = false`), so a file deleted in the
    web UI keeps its Finder copy until the (broken) change enumeration would have removed it —
    i.e. never.
14. **Duplicated dead code**: `MyApp.swift:44-45` prints the same line twice;
    `registrationMessage` is assigned but never read by any view (`MyApp.swift:8`, dead `@State`);
    `ContentView`'s sidebar sections "Starred"/"Trash" are hard-coded empty and the file table is
    five fabricated rows (`ContentView.swift:28-69`) with a footer that says
    "Preview mode · Sample files only" (`ContentView.swift:284`).
15. **Extension identity collision**: the extension's `Info.plist` is excluded from target
    membership via `membershipExceptions` and used as `INFOPLIST_FILE`, while
    `GENERATE_INFOPLIST_FILE = YES`. That works, but it means the two mechanisms overlap and any
    new `INFOPLIST_KEY_*` setting is silently ignored. Worth keeping in mind before adding keys.

## What already works and must be preserved

- The Xcode project builds for macOS with automatic signing, and the extension is embedded and
  signed correctly.
- `NSFileProviderManager.add(domain)` is called on launch and the existing-file case is handled
  (`MyApp.swift:49-62`), so re-registration is already idempotent-tolerant.
- Google Sign-In through the macOS `NSWindow` presentation path compiles and is wired to the
  `GIDClientID` + reversed-client-ID URL scheme pair; `onOpenURL` handles the callback.
- The app group is correctly configured on both sides, which is what lets the extension read
  shared state at all.

## Risks for the production work

- File Provider semantics cannot be exercised without a signed, launched app on a real Mac and a
  Google account; unit tests can cover the Drive layer and the item/anchor logic, but Finder
  behaviour needs a live run and must be reported as such.
- Google's `drive` (full) scope is a *sensitive* scope. An unverified OAuth consent screen limits
  sign-in to test users and shows an "unverified app" interstitial. This is a Google Cloud Console
  task the user must perform; it cannot be coded around.
- Only an Apple Development certificate exists, so a notarized Developer ID distribution is not
  possible from this machine. Any statement about signing/notarization must stay conditional.
