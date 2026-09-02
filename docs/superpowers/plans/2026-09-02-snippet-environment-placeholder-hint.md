# Snippet Editor: a `{{NAME}}` for an Environment Variable Is Named — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The editor's placeholder notice stops being silent about the one
case one click away from the case it already names: a `{{NAME}}` whose
variable IS declared, but with placement "environment variable" — nothing
is substituted there either, and today nothing says so.

**Architecture:** `snippetUndeclaredPlaceholderHint(command:variables:)`
(`Sources/MacSCPAppKit/SnippetsPresentation.swift`) gets a sibling that
answers for declared-as-environment names, and the view shows whichever
sentences apply — both may. The new sentence says what it is (declared,
but as an environment variable), what happens (nothing is filled in; the
text goes to the shell as it stands) and what the author probably meant
(`$NAME`). A display, not a gate: `SnippetVariableSubstitution` and
`SnippetSendPlan` do not change.

**Tech Stack:** Swift 6, Swift Testing (`Tests/macSCPAppKitTests/SnippetPlaceholderHelpTests.swift`
is the suite that covers the sibling function), four App catalogs via
`L10n.string(_:_:)`, `SnippetVariable.Placement.environment`.

**Source:** `docs/superpowers/specs/2026-08-21-backlog-snippet-editor-interaction.md`,
"What was left open here — a design question, not a bug": "declared, but
as an environment variable — nothing gets substituted here". This plan is
that sentence.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- User-visible text in **all four App catalogs**
  (`Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`),
  German addresses the user as **du**; `LocalizationParityTests` and
  `GermanAddressFormTests` guard.
- **A display, not a gate.** No change to `SnippetVariableSubstitution`,
  `SnippetSendPlan`, or `SnippetCommandSurvey`. The dry run and the send
  path behave exactly as before.
- **The inserted value never reaches the notice**: the sentence names the
  placeholder NAME only, never a value (the existing sentence's rule).
- Every name at once, declaration order, no repeats — the same shape as
  the undeclared list (read `snippetUndeclaredPlaceholders` and mirror it).
- `.swiftLanguageMode(.v6)`; warning budget 1 on a fresh scratch path.
- TDD red first. Commit per task. Do not push.

---

### Task 1: The sentence

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsPresentation.swift` (beside
  `snippetUndeclaredPlaceholders` / `snippetUndeclaredPlaceholderHint`)
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift` (~line 726, where the
  hint is shown — show both sentences when both apply; read how the view
  lays the existing one out and follow it)
- Modify: the four App catalogs
- Test: `Tests/macSCPAppKitTests/SnippetPlaceholderHelpTests.swift`

**Interfaces:**
- Produces: `func snippetEnvironmentPlaceholders(in command: String, variables: [SnippetVariable]) -> [String]`
  — the names written as `{{NAME}}` whose declaration has
  `placement == .environment`, declaration order, no repeats — and
  `func snippetEnvironmentPlaceholderHint(command:variables:) -> String?`.

- [ ] **Step 1: Red.** Tests, each with hand-built `SnippetVariable`s (the
  suite has a `variable(...)` helper): (a) `{{DB}}` with `DB` declared as
  `.environment` → `["DB"]`; (b) `{{DB}}` declared as `.placeholder` →
  `[]`; (c) undeclared `{{DB}}` → `[]` here (that is the OTHER sentence's
  job — and a test that the two lists are disjoint for a command carrying
  one of each); (d) repeats collapse, order is declaration order when two
  environment names appear; (e) the hint's text names every such name and
  contains the literal `$DB` form for the first one (compute the Bool
  first); (f) no environment placeholders → `nil`.
- [ ] **Step 2: Strings**, `en` exact:

```
"snippets.variables.environmentPlaceholder %@" = "Declared as an environment variable, not a placeholder: %@. Nothing is filled in there either — write it as $NAME to use the exported value.";
```

  German (du), French, Polish rendered from it. Keep the existing
  `snippets.variables.quotedName %@` for the quoting.
- [ ] **Step 3: Implement** the two functions (mirror the undeclared pair;
  doc comment says: a display, not a gate; why "declared" is the wrong
  word for this case, which is why it is a second sentence and not a
  reworded first one).
- [ ] **Step 4: The view.** Where `snippetUndeclaredPlaceholderHint` is
  shown, show this one too when non-nil — two sentences, not one merged
  string, so each catalog entry stays a whole sentence. A source-scanning
  guard exists for the snippets sheet? `grep -rn "snippetUndeclaredPlaceholderHint" Tests` —
  if a guard anchors on the call, extend it for the sibling (positive
  anchor beside the negative).
- [ ] **Step 5: Run** `swift test --filter "SnippetPlaceholderHelpTests|LocalizationParityTests|GermanAddressFormTests"` and any guard from Step 4; then the full unit suite; warnings on a fresh scratch path.
- [ ] **Step 6: Commit** — `feat(snippets): name a placeholder that is declared as an environment variable`

---

### Task 2: The entry closes its open item

**Files:**
- Modify: `docs/superpowers/specs/2026-08-21-backlog-snippet-editor-interaction.md`, `docs/BACKLOG.md` (row "Snippet editor: usability")

- [ ] **Step 1:** Append "Done 2026-09-0x — the environment-variable
  sentence": what it says, that it is a display, what stays open (the two
  named limits: row insert appends at the end; foreign `{{foo}}` flagged).
  Index row to match.
- [ ] **Step 2: Commit** — `docs(backlog): the snippet editor names an environment-variable placeholder`

## What is explicitly not in this plan

- No change to substitution, the send plan, or the survey.
- No auto-rewrite of `{{NAME}}` to `$NAME` — a hint, not a fix-up.
- The other two named limits stay as they are.
