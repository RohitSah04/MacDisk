# CloudDisk

Google Drive as a native Finder location on macOS: browse, preview, stream, upload, download, and
keep files offline — through the system's own File Provider replication engine, not a private cache.

- One-time setup: launch the app, connect a Google account, CloudDisk appears under Finder →
  *Locations*.
- Docs live in `docs/`:
  - [INSTALL.md](docs/INSTALL.md) — installing, what the app touches, uninstalling
  - [OAUTH_SETUP.md](docs/OAUTH_SETUP.md) — the Google Cloud console side
  - [ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it is built
  - [TESTING.md](docs/TESTING.md) — the automated suites and the human checklist
  - [KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) — what is verified and what is not, per feature
  - [IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) — the phase-by-phase build record
  - [RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) / [RELEASE_NOTES.md](docs/RELEASE_NOTES.md)
- Build: `xcodebuild -scheme CloudDisk -destination 'platform=macOS' build`
- Test: `swift test --package-path CloudDiskKit` and
  `xcodebuild -scheme CloudDisk -destination 'platform=macOS' test`
- Release artifacts: `dist/CloudDisk.app`, `dist/CloudDisk.dmg` — development-signed, **not
  notarized**; read [RELEASE_NOTES.md](docs/RELEASE_NOTES.md) before handing them to anyone.

Requires macOS 14+ on Apple silicon. No Google credential exists on the build machine, so every
path that needs a signed-in account is marked unverified in the limitations doc rather than claimed.
