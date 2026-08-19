# macSCP — Project Rules

## Language policy (maintainer decision, 2026-07-10)

- **Code and comments: English only.** All identifiers, doc comments, inline
  comments, test names, and log/error `reason:` strings in Core are written in
  English. No German in source files.
- **App UI: localized.** User-facing strings go through a String Catalog
  (`Localizable.xcstrings`) with **English as the default language** and a
  **German translation**. Never hardcode display strings; use
  `String(localized:)` / `LocalizedStringKey`.
- Core-layer user-facing messages (e.g. transfer error texts) are defined as
  localizable strings with `Bundle.module` where they must live in Core;
  prefer mapping raw errors to localized text at the App layer.
- Internal docs (`docs/`, plans, specs, ledger) may remain German.
- Public-facing texts (README intro, taglines, landing copy) contain **no
  tech-stack terms** (see global user CLAUDE.md) and exist in English first.
- Migration status: completed 2026-07-10 (milestone M5i). The pre-existing
  German comments and hardcoded UI strings were swept; all code follows this
  policy.

## Build & test

- Swift Package Manager, swift-tools 6.0, **all targets
  `.swiftLanguageMode(.v5)`**, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green. New logic ships
  with tests; prove regressions red first.
- Unit suite: `swift test`. Gated suites: `MACSCP_ITEST=1` (Docker SSH rig)
  and `MACSCP_KEYCHAIN=1` (writes to the real keychain).
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`
  (127.0.0.1:2222, testuser/testpass). **Always start it from the main
  checkout, never from a git worktree** (the seed mount is relative to the
  compose file). `PerSourcePenalties` is disabled in the rig config.
- Never commit key material or secrets; test keys are generated at runtime
  via `ssh-keygen`. Secrets live exclusively in the macOS Keychain
  (`SecretStore`); JSON stores never contain them.

## Architecture invariants

- TOFU host-key handling is security-critical: a key **mismatch is a hard
  stop** (the user decider is never consulted); unknown keys require explicit
  consent; there is no accept-anything path.
- One SSH connection per window; SFTP and the terminal shell multiplex over
  it as child channels. Connection/session state belongs to the window scope,
  never to an app-wide singleton (multi-window is planned for v2).
- The UI owns lifecycles explicitly (queue `cancelAll` → terminal `shutdown`
  → `disconnect` in `teardownSession`); no `deinit` cleanup.
- Transfer queue invariants: FIFO start order, exactly-once waiter
  continuations, `cancelAll` leaves no orphaned shells/transfers, group
  `onCompleted` fires exactly once.

## Kommentare über anderen Code

Zwei Regeln, gemessen im Kommentar-Audit vom 2026-08-19
(`docs/superpowers/specs/2026-08-19-p4-kommentar-audit.md`): 15 % der
Aussagen über Aufrufer waren falsch — aber nur in Dateien, die zuletzt
umgebaut wurden. In einer seit einem Meilenstein stillen Datei: null.

1. **Wer eine Funktion extrahiert, umbenennt oder ihren Aufruferkreis
   ändert, sucht im selben Zug nach Kommentaren, die diese Aufrufer
   benennen — auch in Dateien, die der Diff nicht berührt.** Genau dort
   entsteht der Schaden: der Kommentar wird falsch, ohne im Diff
   aufzutauchen.

2. **Wer in einem Kommentar eine Zahl oder eine Aufzählung von
   Aufrufstellen schreibt, zählt sie im selben Moment nach.** Über vier
   Korrekturrunden hinweg saß *jeder* Folgefehler in einer Zahl oder einer
   Liste; Prosa ohne Kardinalität blieb fehlerfrei. „Drei Aufrufstellen"
   ist eine Behauptung über den Rest des Projekts und klingt beim
   Schreiben immer plausibel.

Gilt auch für Reviews: eine Zahl in einem Kommentar ist ein Prüfauftrag,
kein Beleg.

## Git

- Conventional Commits (enforced by CI); commit messages in English.
- Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Commit/push only on explicit request; the coordinator pushes per milestone
  after the final whole-branch review and watches CI (`gh run watch`).
