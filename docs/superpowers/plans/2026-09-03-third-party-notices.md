# Third-Party Notices, Generated — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `THIRD_PARTY_NOTICES.md` at the repository root lists every
dependency pinned in `Package.resolved` with its licence text, generated
by a script and pinned by a test, so a new dependency cannot land
without its notice. Decided by the maintainer 2026-09-02 after
`_CryptoExtras` (swift-crypto's vendored BoringSSL) became a direct link.

**Architecture:** `scripts/third-party-notices` (a `swift` script or
`bash`+`python3`, whichever the repository's `scripts/` already uses —
read `scripts/release` for the convention) reads `Package.resolved`
(v2 or v3 format: `pins[].identity`, `location`, `state.version`/`revision`),
locates each checkout under `.build/checkouts/<name>` (after
`swift package resolve`), finds its licence file (`LICENSE*`,
`LICENCE*`, `COPYING*`, `NOTICE*` — all of them, BoringSSL's own notice
inside swift-crypto's `Sources/CCryptoBoringSSL` included: search the
checkout for `LICENSE` files at every depth and keep each with its
relative path), and writes one Markdown file: a table (identity, version,
licence name guessed from the first line, URL) and then every licence's
full text under a heading naming the dependency and the file's path.

  Corrected 2026-09-03: measured on the pinned swift-crypto 3.15.1, no
  standalone LICENSE or NOTICE exists under `Sources/CCryptoBoringSSL`;
  the vendored sources carry per-file Apache-2.0 headers, and the notices
  file holds swift-crypto's own LICENSE.txt and NOTICE.txt.

The generator is deterministic (sorted by identity) so the file diffs
only when a dependency changes. The test
(`Tests/macSCPCoreTests/ThirdPartyNoticesTests.swift`) reads
`Package.resolved` and the notices file and asserts every identity has
a heading — a positive check that fails the day a dependency is added
without regenerating; it does not run the generator (CI has the
checkouts but the test must not write to the tree).

**Tech Stack:** `Package.resolved`, `.build/checkouts`, Swift Testing;
the forks: for `NoiXdev/swift-nio-ssh` and `NoiXdev/Citadel` the notice
names the fork URL AND the upstream project (Apple's swift-nio-ssh under
Apache-2.0; Citadel's licence as in its `LICENSE`), so the provenance is
readable.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Copied, not rendered:** licence texts go in verbatim; the generator
  never edits them.
- **Every pinned identity appears** — pinned by the test, which reads
  both files and nothing else.
- The script is idempotent and runs from the main checkout; a `--check`
  mode regenerates to a temp file and diffs, for CI later (not wired
  into CI in this plan).
- No network in the script beyond what `swift package resolve` does.
- Swift 6; warning budget 1; do not push.

---

### Task 1: The generator and the file

**Files:**
- Create: `scripts/third-party-notices`, `THIRD_PARTY_NOTICES.md`
- Modify: `README.md` (one line under the licence/credits section
  pointing at the file; if no such section exists, add two lines)

- [x] Run it; read the result once by eye (every dependency in
  `Package.resolved` has a section; BoringSSL's notice present under
  swift-crypto; the two forks name upstream); commit —
  `build(notices): third-party notices generated from Package.resolved`

### Task 2: The test

**Files:**
- Create: `Tests/macSCPCoreTests/ThirdPartyNoticesTests.swift` (bundle-
  relative path to the repo root like the CLI tests; parse
  `Package.resolved`'s `pins[].identity`; assert each has a `## <identity>`
  heading; positive anchor: the pin count is > 5; red first by removing
  one section in a temp copy — or by asserting against a fixture pin
  that is not in the file)

- [x] Commit — `test(notices): every pinned dependency has a notice`

### Task 3: Closeout

- [x] `docs/superpowers/specs/2026-08-20-backlog-dependencies.md` ("Done"
  under the notices decision), `docs/BACKLOG.md` row; commit
  `docs(backlog): third-party notices, generated and pinned`.
  (committed as `a96c6f79` `docs(notices): the notices are generated,
  tested, and BoringSSL's terms are measured, not assumed`)

## What is explicitly not in this plan

- No CI step (the `--check` mode is ready for one).
- No licence COMPATIBILITY judgment — the file lists, it does not rule.
