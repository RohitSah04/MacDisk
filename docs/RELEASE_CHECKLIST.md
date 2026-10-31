# Release checklist for CloudDisk

The steps that produce `dist/CloudDisk.app` and `dist/CloudDisk.dmg` again, and the steps that a
real distribution would still need. Run from the repo root.

## Build and package

```sh
# 1. Tests first — both surfaces; a red suite is not a releasable state.
swift test --package-path CloudDiskKit
xcodebuild -scheme CloudDisk -destination 'platform=macOS' test

# 2. Release build (warning-free; two AppIntents metadata-processor notices are expected).
xcodebuild -scheme CloudDisk -configuration Release -destination 'platform=macOS' build

# 3. Copy the app out of DerivedData and make the disk image.
APP=$(xcodebuild -scheme CloudDisk -configuration Release -destination 'platform=macOS' \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}' | head -1)/CloudDisk.app
mkdir -p dist && rm -rf dist/CloudDisk.app dist/CloudDisk.dmg
ditto "$APP" dist/CloudDisk.app
mkdir dist/dmgroot && ditto dist/CloudDisk.app dist/dmgroot/CloudDisk.app \
  && ln -s /Applications dist/dmgroot/Applications
hdiutil create -volname CloudDisk -srcfolder dist/dmgroot -ov -format UDZO dist/CloudDisk.dmg
rm -rf dist/dmgroot
```

## Verify before shipping

- [ ] `codesign --verify --deep --strict dist/CloudDisk.app` passes, and the **extension** inside
      (`Contents/PlugIns/CloudDiskProvider.appex`) verifies too — the strict check covers it, but
      run it explicitly once.
- [ ] `codesign -dv` shows the intended identity and team.
- [ ] Launch the app from `dist/` (not DerivedData) on the build machine: status screen all green,
      Finder location mounted, and the *extension serving this build* row points at this bundle.
- [ ] Quit any other copy of the app first — two running copies fight over one domain.

## Known blockers on this machine — state them, do not paper over them

- Only an **Apple Development** certificate exists (`59YP46BFR2`). The shipped bundle is
  development-signed and **not notarized**; `spctl` rejects it. It installs on the build machine and,
  with an explicit Gatekeeper override, on Macs that trust nothing else — it is not a supported
  distribution. Say this in the release notes; never imply the build is notarized.
- The Google OAuth client's consent screen is in *Testing* mode with sensitive `drive` scope: only
  accounts on its test-user list can sign in (`docs/OAUTH_SETUP.md`).

## To turn this into a real distribution (needs assets this machine does not have)

1. Apple Developer Program membership with a **Developer ID Application** certificate, and the
   matching **Developer ID Installer** if a pkg is wanted.
2. An **App Store Connect API key** or app-specific password for notarytool:
   `xcrun notarytool submit CloudDisk.dmg --key ... --wait`, then `xcrun stapler staple`.
3. A notarized DMG plus the `sparkle`-style appcast if updates are wanted — none of that is built.
4. Google OAuth consent screen through verification review for the `drive` scope, so users outside
   the test list can sign in.

## Version bookkeeping

The bundle version lives in the generated `Info.plist` values (`MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` in the project). Bump both before building a release meant for anyone
else, and record the change in `docs/IMPLEMENTATION_PLAN.md`'s phase log — the plan doc is the
project's changelog.
