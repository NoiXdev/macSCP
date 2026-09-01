# macSCP M6b — Release (design spec)

**Date:** 2026-07-27
**Status:** approved by the maintainer (block 1 + block 2)
**Context:** Second part of the release milestone M6 (after M6a polish
backlog). Decisions from the M6 split (maintainer, 2026-07-26):
distribution **signed + notarized**; **release-ready, repo stays private**
(the maintainer flips the public switch himself); release mechanics as a
**local script** (no certificate in CI/GitHub secrets).

## Decisions (maintainer, 2026-07-27)

- License: **MIT**, copyright "© 2026 Tim Rösner".
- First version: **1.0.0** (build 1).
- Bundle identifier: `dev.noix.macscp` (the dev wrapper used
  `dev.noix.macscp.dev` — the release bundle ID is new and final).

## Goal

A reproducibly built, Developer ID–signed, notarized, and stapled DMG of
macSCP 1.0.0 with an app icon, complete Info.plist, working EN/DE
localization, MIT license, and English README — plus the four M6a backlog
hardenings and the two live proofs required by the M6a final review.

## Task 0 — backlog hardenings (code)

1. **Conflict-sheet label for folder transfers:** `TransferConflict`
   gains `isPartOfFolderTransfer: Bool` (the queue sets it when the item
   belongs to a group). When `true`, the sheet shows "Cancel folder
   transfer" / "Ordner-Übertragung abbrechen" instead of the generic
   cancel button, plus a note that this ends the entire folder transfer
   (already-copied files remain). New catalog keys EN/DE; the single-file
   case unchanged.
2. **`updatedBucket` ordering:** a generation counter — the queue counts
   up a generation per direction and passes it to
   `setRate(bytesPerSecond:generation:)`; the actor ignores calls with an
   older generation than the last one applied. This way a stale
   fire-and-forget hop cannot overwrite a newer rate.
3. **Sweep root injectable:**
   `sweepOrphanedTempDirectories(root: URL = …/macscp-edit)`; the test
   uses an isolated root, `.serialized` on the suite is dropped
   (including an update to the suite comment).
4. **FIFOGate determinism:** internal `waiterCount` on `FIFOGate` +
   internal visibility on the queue; the queueRule gate test waits for
   `waiterCount == 1` instead of yield loops.

## Icon

- `scripts/make-icon`: renders `docs/design/assets/icon.svg` via
  `rsvg-convert` into all `.iconset` sizes (16, 16@2x, 32, 32@2x, 128,
  128@2x, 256, 256@2x, 512, 512@2x) and builds
  `Resources/AppIcon.icns` with `iconutil`.
- The finished `.icns` is CHECKED IN (builds/packaging need no rsvg); the
  script is for regenerating it on icon changes and aborts with a clear
  message if `rsvg-convert` is missing.

## Bundle assembly

- `scripts/package-app`: builds the bundle `dist/macSCP.app` from a
  `swift build -c release`:
  - `Contents/MacOS/macSCP` (release binary),
  - `Contents/Info.plist` with: `CFBundleIdentifier dev.noix.macscp`,
    `CFBundleName macSCP`, `CFBundleDisplayName macSCP`,
    `CFBundleShortVersionString 1.0.0`, `CFBundleVersion 1`,
    `CFBundleExecutable macSCP`, `CFBundleIconFile AppIcon`,
    `CFBundlePackageType APPL`, `LSMinimumSystemVersion 15.0`,
    `NSHumanReadableCopyright © 2026 Tim Rösner`,
    `NSPrincipalClass NSApplication`,
  - `Contents/Resources/`: `AppIcon.icns`, BOTH SPM resource bundles
    (`macSCP_MacSCPApp.bundle`, `macSCP_macSCPCore.bundle`) and **empty
    `en.lproj`/`de.lproj` markers** (M5i lesson: macOS chooses the app
    language via the localizations of the MAIN bundle — without markers
    the app stays English).
- `dist/` goes into `.gitignore`.

## Signing, DMG, notarization (`scripts/release`)

Flow (every step aborts on error, exit codes are the proof):

1. Precondition checks: clean git state, identity
   `Developer ID Application: Tim Rösner (5V8ZCK434F)` in the keychain,
   keychain profile `macscp-notary` present (otherwise abort with
   instructions: `xcrun notarytool store-credentials macscp-notary …` —
   the MAINTAINER sets this up himself, once; the script and repo never
   see secrets).
2. `scripts/package-app` (fresh release build).
3. `codesign --force --options runtime --timestamp` with the
   Developer ID identity: first the embedded resource bundles, then the
   app bundle; verification `codesign --verify --deep
   --strict` + `codesign -dv`.
4. DMG: `hdiutil create` (UDZO, volume "macSCP") from a staging dir with
   `macSCP.app` + symlink `Applications`; result
   `dist/macSCP-1.0.0.dmg`; sign the DMG.
5. `xcrun notarytool submit dist/macSCP-1.0.0.dmg --keychain-profile
   macscp-notary --wait` (on rejection: print the log via
   `notarytool log` and abort).
6. `xcrun stapler staple` on BOTH the app AND the DMG.
7. Final verification: `spctl --assess --type open --context
   context:primary-signature` on the DMG and `spctl --assess --type
   execute` on the app, `stapler validate` — output in the script log.

No sandbox opt-in, no additional entitlements (hardened runtime with no
exceptions suffices; the app uses no JIT, no unsigned plugins). CI stays
test-only.

## Docs

- `LICENSE`: MIT text, "Copyright (c) 2026 Tim Rösner".
- `README.md` (English):
  - Tagline + intro **without tech-stack terms** (policy): "A native
    macOS SFTP client …" — features from a user perspective (dual-pane
    browser, saved sessions, SSH key auth, host-key pinning, integrated
    terminal, transfer queue with pause/resume behavior, bandwidth
    limits, editor integration, EN/DE).
  - Screenshot (dark browser screenshot, `docs/design/assets/`).
  - Install: download DMG → drag app to `/Applications`; note macOS 15+.
  - "Building from source": technical terms ARE allowed HERE
    (`swift build`, test-rig note) — a technical section, not landing
    copy.
  - License section (MIT).
- No CHANGELOG in M6b (YAGNI — comes with the second release).

## Final smoke (binding, including the M6a final-review conditions)

With the NOTARIZED DMG:
1. Mount, copy the app to `/Applications`, first launch WITHOUT a
   Gatekeeper warning (quarantine attribute present, launch still clean
   — the core proof of notarization).
2. German UI on a German system (localization-marker proof) and an
   `-AppleLanguages (en)` counter-check.
3. Icon visible in Finder + Dock; version 1.0.0 in the About window.
4. Short functional test against the Docker rig (connect, transfer,
   disconnect).
5. **Edit-roundtrip live proof** (M6a condition): open a text file via
   double-click, save it in the editor, verify the auto-upload on the
   rig. With an editor that can be driven; if none is available, the
   maintainer takes over the one save step.
6. **FKA focus-ring check** (M6a condition): Full Keyboard Access on,
   tab through the form buttons — system ring visible.
7. Conflict-sheet folder label (Task 0) sighted live once.

## Invariants

- Security invariants untouched; no secrets in repo/scripts
  (notarization exclusively via the maintainer's keychain profile).
- Code + comments + scripts English; new UI texts cataloged EN/DE.
- Public-facing texts (README intro/tagline) without stack terms.
- The existing suite (320) stays green; Task 0 logic TDD.

## Deliberately NOT in M6b

- GitHub release/tag automation and repo-to-public (the maintainer does
  this when he is ready).
- Sparkle/auto-update, CHANGELOG, menu-bar icon (variant B stays in
  reserve).
- App Store / sandbox migration.

## Update (maintainer, 2026-07-27 — after Task 6)

- **Bundle ID/branding:** `dev.noidee.macscp` → **`dev.noix.macscp`**
  (alignment with the NoiXdev org; the keychain service and logger
  subsystem move with it — locally stored dev secrets under the old
  service need to be re-saved once).
- **Release mechanics extended:** in addition to the local script, a
  **CI release workflow** (`.github/workflows/release.yml`) modeled on
  the s3Manager repo of the same org: tag `v*.*.*` →
  changelog job (conventional-changelog, CHANGELOG.md commit on main,
  GitHub release with release notes) → macOS build job (certificate
  import + App Store Connect API key from the org-wide secrets
  `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`) → `scripts/release` in
  CI mode → DMG as a release asset. `scripts/release` runs two ways:
  API-key env (CI) or keychain profile (local); `MACSCP_VERSION` comes
  from the tag. This REVISES "CI stays test-only," "no CHANGELOG," and
  "GitHub release automation not in M6b" from the original spec. The
  repo is made public for this (audit 2026-07-27: 0 critical,
  hardenings committed).
