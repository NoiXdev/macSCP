# Session Overview — Design

Decided 2026-09-04 with the maintainer, from feedback given during the
diagnostics dev-build session and re-raised today: a single click on a
session in the sidebar shows an overview of that session in the detail
area instead of the empty "New connection" form. Approved on the mockup
(artifact 29db6db2, "Sitzungsübersicht"), read-only, with the actions
Connect / Edit / Diagnose, the recent connections and the snippets, and
one added requirement: it must stay usable when the window is resized.

## What a click does

Today a single click selects the row (`SessionSidebar.moveSelection`),
a double click or Return connects (`connectFromSidebar`), and the detail
area of a not-yet-connected tab shows `ConnectionFormView` regardless.
After this design:

- A single click on a stored session selects it AND the detail area of
  the active not-connected tab shows `SessionOverviewView` for it.
- "New connection" in the sidebar, or no selection, shows the form as
  today. Double click and Return keep connecting.
- The overview is read-only. **Edit** opens the existing form prefilled
  through the one fill both callers already share (`editStored(_:)`),
  **Connect** runs `connectFromSidebar(_:)`, **Diagnose** opens the
  diagnostics panel for the stored session (`showDiagnostics(for:
  .stored(session))`). No fourth way to do any of the three exists
  afterwards: the overview hands over the same effects the sidebar
  holds, through the same `SessionRowConnectEffect` discipline.

## What the overview shows

Head: name, kind badge, endpoint text (host:port, or the S3 endpoint, or
the WebDAV base URL — the descriptor's own `endpoint(_:)`), the three
actions with Connect as the default action (Return).

Facts, from the stored record and the descriptor's field vocabulary,
never from a secret store's value: user (SSH), bucket or start at the
bucket list (S3), base URL (WebDAV); authentication kind and key path
(SSH), login set name where one owns the credential; whether a secret
is stored — answered by a metadata-only keychain query (no
`kSecReturnData`, the shape `CyberduckSecretReader` already uses), so
the overview never holds the value; jump host; host-key status from
`KnownHostsStore.find(host:port:)` — known with type and fingerprint, or
not yet known; group; tags; start path; pane visibility; import
provenance (`importSource`, `importedAt`).

Recent connections, derived from the session's audit log
(`AuditLogStore.events(for:)`): `connected` … `disconnected` pairs
become rows with start, duration and the transfers counted between
them (`transferFinished`/`transferFailed` with their bytes where the
detail carries them); a new audit kind `connectFailed` records a failed
connect with the fixed sentence the diagnostics module already produces
for that error (`DialSupport.reason(for:)` — no free error text), and
its row offers "Open diagnosis". The list shows the last 10; the audit
sheet remains the full record.

Snippets: every stored snippet with its command line; **Run** connects
(the same effect), waits for the terminal to be open, then sends through
`runSnippet` — snippets with declared variables ask first, through the
existing dry-run sheet. A failed connect stops there and shows the
failed-connect surface; nothing is sent.

## Responsive

The maintainer's added requirement. The overview is a `ScrollView` under
a pinned head (name and actions), the same split the connection form
got on 2026-09-04 (fields scroll, buttons stay). The actions row uses
`ViewThatFits` (one row, else two, as the diagnostics footer does). The
facts are a two-column `Grid` that becomes one column through
`ViewThatFits` when the pane is narrow; the snippets use a
`LazyVGrid(columns: [GridItem(.adaptive(minimum: 260))])`; the recent
connections table drops its transfers column below the same threshold.
The detail pane's minimum width stays what it is (420).

## Never in the overview

A secret value, a passphrase, a private key's contents, an endpoint's
userinfo. Every text the overview renders comes from the stored record,
the known-hosts store, the audit log's fixed sentences and the snippet
store; the guard suite scans the view for the secret field ids and for
`String(describing:)` the way the diagnostics guard does.

## Tests

A view model (`SessionOverviewModel`) derives everything the view shows
from a `StoredSession`, a `KnownHostKey?`, a `[AuditEvent]` and
`[Snippet]` — unit-tested without a keychain or a network: the facts per
kind, the recent-connections pairing (an unpaired `connected` is an
open session, not a row; a `connectFailed` is a failed row), the
duration and transfer sums, the last-10 cut. The keychain presence
query is a seam (`SecretPresence` protocol) with a fake in tests and
the metadata query in the app. Guards: the sidebar's single-click path
reaches the overview and the three actions reach the three existing
effects (source scans with positive companions, the shape of
`DiagnosticsDoorsGuardTests`); the responsive split (head outside the
scroll region, `ViewThatFits` present) the shape of
`ConnectionFormScrollGuardTests`. Localization keys in all four
catalogs, German du.

## Not in this design

Inline editing (Edit opens the form); a per-session history store
beyond the audit log; running a snippet on an already-open terminal
from the overview (the terminal's own snippet menu does that);
reordering or grouping from the overview.
