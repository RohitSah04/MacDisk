# Google OAuth setup for CloudDisk

CloudDisk signs in with Google through the official Google Sign-In SDK for macOS
(`GoogleSignIn`), which opens the user's browser and returns the tokens — CloudDisk never sees or
asks for a Google password. This page is what has to exist on the Google side for that to work.

## The client this build uses

The OAuth client id is a build setting, not a runtime question, so the same value is compiled into
the app and its extension:

```
CLOUDDISK_GOOGLE_CLIENT_ID  = 265151445816-ftndevk4ofq4bhasv77f3cujij41si4n.apps.googleusercontent.com
CLOUDDISK_GOOGLE_URL_SCHEME = com.googleusercontent.apps.265151445816-ftndevk4ofq4bhasv77f3cujij41si4n
```

`GIDClientID` in the app's `Info.plist` reads the first; `CFBundleURLSchemes` reads the second, which
is how the browser redirect gets back into the app. Both Debug and Release configurations carry the
same pair (`pro.xcodeproj/project.pbxproj`).

That client must exist as an **iOS / macOS** type OAuth client (the `com.googleusercontent.apps.…`
URL-scheme form is what that type produces) in a Google Cloud project you control.

## Console checklist

1. **Google Cloud Console** → create or pick a project → *APIs & Services → Library* → enable the
   **Google Drive API**.
2. *APIs & Services → OAuth consent screen*: choose External, fill in the app name
   (`CloudDisk`), support email, and developer contact. Add the scope
   `https://www.googleapis.com/auth/drive` — it is a **sensitive scope**, so Google requires review
   before the consent screen can be published for arbitrary users.
3. While the consent screen is in *Testing* (the only state this project's build has ever been in):
   **Testing → Test users → add every Google account that will sign in.** An account that is not on
   that list gets `access_denied` at the consent screen — this is the single most common failure.
4. *Credentials → Create credentials → OAuth client ID → iOS*: use the bundle identifier of the app,
   `dev.rohitsah.clouddisk`. (The Google Sign-In SDK for macOS matches on the client id and the URL
   scheme, not a bundle-id check, but keeping the record aligned avoids surprises.) The generated
   client id replaces the value in both build settings if you are using your own project.
5. Nothing else is secret here: this is a *native* client, so there is **no client secret** anywhere
   in the repo, and refresh tokens live only in the keychain.

## What CloudDisk asks for at sign-in

- Scope: `https://www.googleapis.com/auth/drive` (read/write Drive) plus the profile/email scope the
  Google Sign-In SDK adds so the app can show which account is connected.
- The grant is stored as one keychain item (access token, refresh token, expiry, account) in the
  group `dev.rohitsah.clouddisk`, shared with the File Provider extension; tokens refresh
  automatically inside `TokenProvider` and are never logged.
- **Sign out** revokes the grant at Google's token endpoint and deletes the keychain item — the app
  does not keep a copy, so signing back in means going through the browser consent again.

## If sign-in fails

| Symptom | Cause on the Google side |
| --- | --- |
| Browser opens, consent shows `access_denied` | The account is not a test user of the consent screen (step 3) |
| App opens but reports `invalid_grant` on first Drive call | The client id in the build settings does not match a client in the project you are signed into |
| Consent screen warns the app is unverified | Expected while the `drive` scope is unreviewed; click through *Advanced → Go to CloudDisk* as a test user |

## Live-API smoke tests (optional)

`CloudDiskKit/Tests/CloudDiskKitTests/LiveDriveSmokeTests.swift` can exercise the real Drive API
with a refresh token instead of a browser sign-in. Set both environment variables before
`swift test --package-path CloudDiskKit`:

```
export CLOUDDISK_LIVE_CLIENT_ID=<your client id>
export CLOUDDISK_LIVE_REFRESH_TOKEN=<a refresh token for a test user>
```

The 14 live cases report **skipped**, not passed, without them — no credentials exist on the build
machine, so none of them has ever been run here.
