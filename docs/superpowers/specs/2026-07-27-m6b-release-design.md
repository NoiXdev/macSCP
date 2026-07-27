# macSCP M6b — Release (Design-Spec)

**Datum:** 2026-07-27
**Status:** vom Maintainer freigegeben (Block 1 + Block 2)
**Kontext:** Zweiter Teil des Release-Meilensteins M6 (nach M6a Polish-Backlog).
Entscheidungen aus dem M6-Split (Maintainer, 2026-07-26): Verteilung
**signiert + notarisiert**; **release-fertig, Repo bleibt privat** (den
public-Schalter legt der Maintainer selbst um); Release-Mechanik als
**lokales Skript** (kein Zertifikat in CI/GitHub-Secrets).

## Entscheidungen (Maintainer, 2026-07-27)

- Lizenz: **MIT**, Copyright „© 2026 Tim Rösner".
- Erste Version: **1.0.0** (Build 1).
- Bundle-Identifier: `dev.noix.macscp` (der Dev-Wrapper nutzte
  `dev.noix.macscp.dev` — der Release-Bundle-Id ist neu und final).

## Ziel

Ein reproduzierbar gebautes, Developer-ID-signiertes, notarisiertes und
gestapeltes DMG von macSCP 1.0.0 mit App-Icon, vollständiger Info.plist,
funktionierender EN/DE-Lokalisierung, MIT-Lizenz und englischem README —
plus die vier M6a-Backlog-Härtungen und die zwei vom M6a-Final-Review
auferlegten Live-Beweise.

## Task 0 — Backlog-Härtungen (Code)

1. **Konflikt-Sheet-Label für Ordner-Transfers:** `TransferConflict`
   erhält `isPartOfFolderTransfer: Bool` (Queue setzt es, wenn das Item
   einer Gruppe angehört). Das Sheet zeigt bei `true` statt des
   generischen Abbrechen-Buttons „Cancel folder transfer" / „Ordner-
   Übertragung abbrechen" plus eine Hinweiszeile, dass damit die gesamte
   Ordner-Übertragung endet (bereits kopierte Dateien bleiben). Neue
   Katalog-Keys EN/DE; Einzeldatei-Fall unverändert.
2. **`updatedBucket`-Ordering:** Generation-Counter — die Queue zählt
   pro Richtung eine Generation hoch und übergibt sie an
   `setRate(bytesPerSecond:generation:)`; der Actor ignoriert Aufrufe
   mit älterer Generation als der zuletzt angewandten. Damit kann ein
   überholter Fire-and-forget-Hop keine neuere Rate überschreiben.
3. **Sweep-Root injizierbar:**
   `sweepOrphanedTempDirectories(root: URL = …/macscp-edit)`; der Test
   nutzt einen isolierten Root, `.serialized` auf der Suite entfällt
   (inkl. Anpassung des Suite-Kommentars).
4. **FIFOGate-Determinismus:** internes `waiterCount` auf `FIFOGate` +
   internal Sicht auf der Queue; der queueRule-Gate-Test wartet auf
   `waiterCount == 1` statt auf Yield-Schleifen.

## Icon

- `scripts/make-icon`: rendert `docs/design/assets/icon.svg` per
  `rsvg-convert` in alle `.iconset`-Größen (16, 16@2x, 32, 32@2x, 128,
  128@2x, 256, 256@2x, 512, 512@2x) und baut mit `iconutil` die
  `Resources/AppIcon.icns`.
- Die fertige `.icns` wird EINGECHECKT (Builds/Packaging brauchen kein
  rsvg); das Skript dient der Regenerierung bei Icon-Änderungen und
  bricht mit klarer Meldung ab, wenn `rsvg-convert` fehlt.

## Bundle-Assembly

- `scripts/package-app`: baut aus einem `swift build -c release` das
  Bundle `dist/macSCP.app`:
  - `Contents/MacOS/macSCP` (Release-Binary),
  - `Contents/Info.plist` mit: `CFBundleIdentifier dev.noix.macscp`,
    `CFBundleName macSCP`, `CFBundleDisplayName macSCP`,
    `CFBundleShortVersionString 1.0.0`, `CFBundleVersion 1`,
    `CFBundleExecutable macSCP`, `CFBundleIconFile AppIcon`,
    `CFBundlePackageType APPL`, `LSMinimumSystemVersion 15.0`,
    `NSHumanReadableCopyright © 2026 Tim Rösner`,
    `NSPrincipalClass NSApplication`,
  - `Contents/Resources/`: `AppIcon.icns`, BEIDE SPM-Ressourcen-Bundles
    (`macSCP_MacSCPApp.bundle`, `macSCP_macSCPCore.bundle`) und **leere
    `en.lproj`/`de.lproj`-Marker** (M5i-Lektion: macOS wählt die
    App-Sprache über die Lokalisierungen des MAIN-Bundles — ohne Marker
    bleibt die App englisch).
- `dist/` kommt in `.gitignore`.

## Signierung, DMG, Notarisierung (`scripts/release`)

Ablauf (jeder Schritt bricht bei Fehler ab, Exit-Codes sind die Beweise):

1. Vorbedingungs-Checks: sauberer Git-Stand, Identität
   `Developer ID Application: Tim Rösner (5V8ZCK434F)` im Keychain,
   Keychain-Profil `macscp-notary` vorhanden (sonst Abbruch mit
   Anleitung: `xcrun notarytool store-credentials macscp-notary …` —
   das richtet der MAINTAINER einmalig selbst ein; Skript und Repo
   sehen nie Secrets).
2. `scripts/package-app` (frischer Release-Build).
3. `codesign --force --options runtime --timestamp` mit der
   Developer-ID-Identität: erst die eingebetteten Ressourcen-Bundles,
   dann das App-Bundle; Verifikation `codesign --verify --deep
   --strict` + `codesign -dv`.
4. DMG: `hdiutil create` (UDZO, Volume „macSCP") aus einem Staging-Dir
   mit `macSCP.app` + Symlink `Applications`; Ergebnis
   `dist/macSCP-1.0.0.dmg`; DMG signieren.
5. `xcrun notarytool submit dist/macSCP-1.0.0.dmg --keychain-profile
   macscp-notary --wait` (bei Ablehnung: Log via `notarytool log`
   ausgeben und abbrechen).
6. `xcrun stapler staple` auf App UND DMG.
7. Abschluss-Verifikation: `spctl --assess --type open --context
   context:primary-signature` auf dem DMG bzw. `spctl --assess --type
   execute` auf der App, `stapler validate` — Ausgabe im Skript-Log.

Kein Sandbox-Opt-in, keine zusätzlichen Entitlements (Hardened Runtime
ohne Ausnahmen genügt; die App nutzt kein JIT, keine unsignierten
Plugins). CI bleibt Test-only.

## Docs

- `LICENSE`: MIT-Text, „Copyright (c) 2026 Tim Rösner".
- `README.md` (Englisch):
  - Tagline + Intro **ohne Tech-Stack-Begriffe** (Policy): „A native
    macOS SFTP client …" — Features aus Nutzersicht (Zwei-Fenster-
    Browser, gespeicherte Sessions, SSH-Key-Auth, Host-Key-Pinning,
    integriertes Terminal, Transfer-Queue mit Pause/Resume-Verhalten,
    Bandbreiten-Limits, Editor-Integration, EN/DE).
  - Screenshot (dunkler Browser-Screenshot, `docs/design/assets/`).
  - Install: DMG laden → App nach `/Applications` ziehen; Hinweis
    macOS 15+.
  - „Building from source": HIER dürfen technische Begriffe stehen
    (`swift build`, Test-Rig-Hinweis) — technischer Abschnitt, keine
    Landing-Copy.
  - Lizenz-Abschnitt (MIT).
- Kein CHANGELOG in M6b (YAGNI — kommt mit dem zweiten Release).

## Abschluss-Smoke (bindend, inkl. M6a-Final-Review-Bedingungen)

Mit dem NOTARISIERTEN DMG:
1. Mounten, App nach `/Applications` kopieren, Erststart OHNE
   Gatekeeper-Warnung (Quarantäne-Attribut vorhanden, Start trotzdem
   sauber — der Kern-Beweis der Notarisierung).
2. Deutsche UI auf deutschem System (Lokalisierungs-Marker-Beweis) und
   `-AppleLanguages (en)`-Gegenprobe.
3. Icon sichtbar in Finder + Dock; Version 1.0.0 im About-Fenster.
4. Funktions-Kurztest gegen das Docker-Rig (Verbinden, Transfer,
   Trennen).
5. **Edit-Roundtrip-Livebeweis** (M6a-Bedingung): Textdatei per
   Doppelklick öffnen, im Editor speichern, Auto-Upload auf dem Rig
   verifiziert. Mit einem Editor, der getrieben werden darf; falls
   keiner verfügbar ist, übernimmt der Maintainer den einen
   Save-Schritt.
6. **FKA-Fokus-Ring-Check** (M6a-Bedingung): Full Keyboard Access an,
   Tab durch die Formular-Buttons — System-Ring sichtbar.
7. Konflikt-Sheet-Ordner-Label (Task 0) einmal live gesichtet.

## Invarianten

- Sicherheits-Invarianten unangetastet; keine Secrets in Repo/Skripten
  (Notarisierung ausschließlich über das Keychain-Profil des
  Maintainers).
- Code + Kommentare + Skripte Englisch; neue UI-Texte katalogisiert
  EN/DE.
- Öffentliche Texte (README-Intro/Tagline) ohne Stack-Begriffe.
- Bestehende Suite (320) bleibt grün; Task-0-Logik TDD.

## Bewusst NICHT in M6b

- GitHub-Release/Tag-Automatik und Repo-auf-public (macht der
  Maintainer, wenn er bereit ist).
- Sparkle/Auto-Update, CHANGELOG, Menüleisten-Icon (Variante B bleibt
  Reserve).
- App Store / Sandbox-Migration.

## Update (Maintainer, 2026-07-27 — nach Task 6)

- **Bundle-ID/Branding:** `dev.noidee.macscp` → **`dev.noix.macscp`**
  (Angleich an die NoiXdev-Org; Keychain-Service und Logger-Subsystem
  ziehen mit — lokal gespeicherte Dev-Secrets unter dem alten Service
  müssen einmalig neu gespeichert werden).
- **Release-Mechanik erweitert:** zusätzlich zum lokalen Skript ein
  **CI-Release-Workflow** (`.github/workflows/release.yml`) nach dem
  Vorbild des s3Manager-Repos derselben Org: Tag `v*.*.*` →
  Changelog-Job (conventional-changelog, CHANGELOG.md-Commit auf main,
  GitHub-Release mit Release-Notes) → macOS-Build-Job (Zertifikat-Import
  + App-Store-Connect-API-Key aus den org-weiten Secrets
  `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`) → `scripts/release` im
  CI-Modus → DMG als Release-Asset. `scripts/release` ist zweigleisig:
  API-Key-Env (CI) oder Keychain-Profil (lokal); `MACSCP_VERSION` kommt
  aus dem Tag. Damit sind „CI bleibt Test-only", „kein CHANGELOG" und
  „GitHub-Release-Automatik nicht in M6b" aus der ursprünglichen Spec
  REVIDIERT. Das Repo wird dafür public gestellt (Audit 2026-07-27:
  0 Critical, Härtungen committet).
