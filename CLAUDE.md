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

## Comments that describe other code

Two rules, measured in the comment audit of 2026-08-19
(`docs/superpowers/specs/2026-08-19-p4-kommentar-audit.md`): 15% of the
statements about callers were wrong — but only in files that had recently
been restructured. In a file untouched since a milestone: none.

1. **Extracting a function, renaming it, or changing who calls it means
   searching, in the same pass, for comments that name those callers —
   including in files the diff does not touch.** That is exactly where the
   damage happens: the comment becomes wrong without ever showing up in the
   diff.

2. **Writing a number or an enumeration of call sites into a comment means
   counting them in that same moment.** Across four correction rounds,
   *every* follow-on error sat in a number or a list; prose without
   cardinality stayed correct. "Three call sites" is a claim about the rest
   of the project, and it always sounds plausible while you write it.

Applies to reviews too: a number in a comment is something to verify, not
evidence.

## Git

- Conventional Commits (enforced by CI); commit messages in English.
- Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Commit/push only on explicit request; the coordinator pushes per milestone
  after the final whole-branch review and watches CI (`gh run watch`).
