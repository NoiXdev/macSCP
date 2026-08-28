# macSCP — Project Rules

## Language policy (maintainer decision, 2026-07-10)

- **Code and comments: English only.** All identifiers, doc comments, inline
  comments, test names, and log/error `reason:` strings in Core are written in
  English. No German in source files.
- **App UI: localized.** User-facing strings live in
  `Resources/<locale>.lproj/Localizable.strings` under both localized
  targets, `MacSCPAppKit` and `macSCPCore`, in **four languages**: `en` —
  the default, and the source text every other catalog is measured against —
  plus `de`, `fr`, `pl`. Plural forms sit beside them in
  `Localizable.stringsdict`. The German catalogs address the user as **du**;
  `GermanAddressFormTests` holds them to it.
- Never hardcode a display string. Look it up through `L10n.string(_:_:)` /
  `L10n.text(_:_:)` in the App, `CoreL10n.string(_:)` in Core. Core-layer
  user-facing messages (e.g. transfer error texts) live in Core's own
  catalog where they must; prefer mapping raw errors to localized text at
  the App layer.
- **Not `String(localized:)`, not `LocalizedStringKey`, not a String Catalog
  (`.xcstrings`), not `Bundle.module`** — this paragraph used to prescribe
  all four, and the tree has never used any of them. Counted 2026-08-28:
  zero occurrences of the first two, no `.xcstrings` anywhere, and
  `Bundle.module` only inside the comments explaining why both helpers avoid
  it — SwiftPM's generated accessor calls `fatalError` when it cannot find
  the resource bundle, which a stripped launch really can. `L10n` and
  `CoreL10n` search a wider candidate list and fall back to the key text
  instead of trapping. Adding a String Catalog is a migration to design, not
  a file to drop in: the plural categories differ per language (`pl` carries
  `few`/`many` where `de`, `en` and `fr` carry only `one`/`other`). The
  localization checks read `.xcstrings` since `cb624e5`, so one would at
  least not go unexamined.
- Internal docs (`docs/`, plans, specs, ledger) may remain German.
- Public-facing texts (README intro, taglines, landing copy) contain **no
  tech-stack terms** (see global user CLAUDE.md) and exist in English first.
- Migration status: the German-comment and hardcoded-string sweep completed
  2026-07-10 (milestone M5i). The format described above was corrected on
  2026-08-28 to match the tree — it had prescribed a String Catalog and two
  SwiftUI lookup APIs that no code here has ever used, which is how a rule
  file quietly instructs the next contributor to build something the rest of
  the project does not speak.

## Build & test

- Swift Package Manager, swift-tools 6.0, **all targets
  `.swiftLanguageMode(.v6)`**, minimum macOS 15.
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

## Guards that name what they watch

Measured on 2026-08-27, across a tab-menu wiring guard that survived five
correction rounds and a prefill guard that went silent without anyone
noticing.

Source-scanning guards are subject to the rule above, and to one of their
own:

1. **Only a NEGATIVE check can go stale in silence.** A check that requires
   something present (`contains`, a count that must match, a whole-body
   equality) fails loudly the moment the thing it names moves. A check that
   requires something ABSENT — `!contains`, or a filter expected to come
   back empty — starts matching nothing and passes. It reads exactly like a
   check that is satisfied.

   `replacedSession` was renamed to `nameConflict` in the same commit that
   left the guard's no-blocking filter naming the old symbol. The filter
   matched nothing, the suite stayed green, and the violation it existed to
   catch — a disabled Save button — could be planted freely. Every other
   negative check in that suite was pinned by a positive check nearby; this
   was the one that was not, which is precisely why it was the one that
   went stale.

   **So: a negative check needs a positive check beside it**, asserting that
   the thing it scans is there at all. Without one it is not a guard, it is
   a comment that runs.

2. **A guard that spells a symbol it could read instead is waiting for a
   rename.** Walk the name back from a call site, derive a catalogue key
   from the type that owns it. A literal is a second copy of a name, and
   this project's rule about second copies applies to tests as much as to
   comments.

3. **Mutation testing verifies a guard's sensitivity, never its scope.**
   Probes derived from the author's own enumeration test the places the
   author already thought of. Across five rounds on one guard, every hole
   was found by a fresh reader planting a violation the enumeration did not
   contain — and none by the author's own battery. When a scan keeps buying
   one spelling and revealing another, that is the evidence that the
   property wants a structural boundary (a type that will not compile the
   violation) rather than another anchor.

## Git

- Conventional Commits (enforced by CI); commit messages in English.
- Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Commit/push only on explicit request; the coordinator pushes per milestone
  after the final whole-branch review and watches CI (`gh run watch`).
