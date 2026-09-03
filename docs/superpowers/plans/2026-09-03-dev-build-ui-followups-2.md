# Dev-Build Follow-ups 2: S3 Host With Port, and the Diagnostics Footer — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two things the maintainer hit in the dev build (2026-09-03):
(1) an S3 connection fails when the host field carries a port
(`host:9000`); (2) the diagnostics panel's footer is too cramped — the
Run button wraps letter by letter, the scope picker's label eats the
width, "Copy report" and "Close" truncate.

**Architecture:** (1) is measured before it is touched: a unit test
feeds the S3 endpoint parser every spelling a user types (`host`,
`host:9000`, `http://host:9000`, `https://host`, `host/`) and records
what each yields today; the fix is one parse (the diagnostics plan
already funnelled the app's S3 endpoint parsing into one function —
find it by the error text "Invalid S3 endpoint") that accepts `host:port`
with and without a scheme, plus a form validation message that names
what was understood, and the Cyberduck importer's S3 mapping writes the
same spelling that parse expects. (2) is a layout fix: the footer's
controls in an `HStack` that cannot wrap the button (`fixedSize()` on
the buttons, the picker's label hidden with the accessibility label kept,
a minimum panel width, and the footer wrapping to two rows below it).

**Tech Stack:** Swift Testing, SwiftUI; guards on `SwiftSource` views.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- Red first: the S3 parse table as a parameterised test, the failing spellings red before the fix; no wall-clock ceilings; no `#require` on non-optionals (CI's compiler is Swift 6.1.2).
- No secret in any message: a validation message names the host and port it understood, never the key.
- Display strings through `L10n.string(_:_:)`, four catalogs, German du.

---

### Task 1: The S3 endpoint accepts a port, and says what it read

**Files:**
- Modify: the one S3 endpoint parse in `Sources/macSCPCore/S3/` (grep `Invalid S3 endpoint`), `S3FieldSchema.swift` (the endpoint field's validation and its help text), the Cyberduck importer's S3 mapping in `Sources/macSCPCore/Sessions/ExternalImport/ImportPreviewPlanner.swift` (writes `host:port` for a custom endpoint, or the scheme form — whichever the parse's canonical spelling is), four App catalogs if a validation key is added
- Test: `S3EndpointParsingTests` (the table: `host`, `host:9000`, `http://host:9000`, `https://host`, `https://host:8443/`, `[::1]:9000`, `s3.amazonaws.com`; each → scheme, host, port, path-style expectation), `ImportPreviewPlannerTests` (a Cyberduck S3 bookmark with `Port 9000` produces an endpoint the parse accepts — assert through the parse, not a literal)

- [ ] Measure first (the table red where it fails today; record each outcome in the report), fix, commit `fix(s3): an endpoint with a port connects, and the form says what it understood`.

### Task 2: The diagnostics footer fits

**Files:**
- Modify: `Sources/MacSCPAppKit/DiagnosticsPanel.swift` (the footer: buttons `fixedSize(horizontal: true, vertical: false)`, the scope picker `labelsHidden()` with `accessibilityLabel` from the existing `diagnostics.scope` key, a `minWidth` on the panel that fits the four controls at the default font, and a `ViewThatFits` that puts the picker on its own row when the width is short)
- Test: the doors guard (`DiagnosticsDoorsGuardTests`) gains anchors: Run carries `fixedSize`, the picker keeps its accessibility label while its visible label is hidden, the panel declares a minimum width (a named constant the guard reads)

- [ ] Red first, implement, commit `fix(diagnostics): the panel's footer keeps its buttons whole`.
