# M10a — Known-hosts management (design)

Date: 2026-07-28 · Status: approved by the maintainer (mockup frozen:
`docs/design/assets/m10-mockups.html` sections 1+4 — committed with this
spec; design block "yes, go ahead")

## Goal

View and manage all host keys remembered via TOFU: table with
fingerprints, search, copy, remove with confirmation — reachable via a
new "Sessions" menu, the sidebar background menu, and the TOFU prompt.

**Binding from the mockup:** NO editing of entries (making fingerprints
editable would be a security foot-gun); removal is the official tool for
rotated server keys.

## 1. Core: KnownHostKey + KnownHostsStore

- `KnownHostKey.addedAt: Date?` — NEW, optional and decode-compatible:
  existing entries without the field read as `nil` (display "—"); the
  existing normalizing custom decoder remains the ONLY decode path (M3d
  rule) and decodes the field via `decodeIfPresent`. `upsert` stamps
  `Date()` on write (also when replacing an existing entry — the time of
  the last trust decision).
- `KnownHostsStore.allKeys() throws -> [KnownHostKey]` — public, sorted
  by host (case-insensitive, already lowercased) then port.
- `KnownHostsStore.remove(host:port:)` throws — removes exactly the
  (host lowercased, port) match, persists atomically; no-op if not
  present.
- TOFU INVARIANTS UNTOUCHED: find/upsert/validator flow unchanged;
  removal makes the host "unknown" again (next connect = normal TOFU
  prompt); a mismatch remains a hard stop.

## 2. App: KnownHostsSheet

Exactly mockup section 1 (~720 pt wide):

- Table: Host, Port, key type (badge, RemoteBlue-Soft), fingerprint
  (SHA256, monospaced, `inkSecondary`), Added (`dd.MM.yyyy`, "—" for
  nil). Multi-selection. Search over host + fingerprint
  (case-insensitive).
- Footer: counter ("n Hosts" / filtered "n of m"), "Fingerprint kopieren"
  (active only for single selection; NSPasteboard), "Entfernen…"
  (destructive, active only with a selection; confirmation text: "Beim
  nächsten Verbinden wird der Host wie ein unbekannter behandelt (neuer
  TOFU-Prompt)." — with a count for multi-selection), "Schließen".
- Loaded on open; load error ⇒ honest message in the sheet (no silent
  emptiness). After removal: reload the list, clear the selection.

## 3. Entry points (mockup section 4, known-hosts part)

- NEW "Sessions" menu in the menu bar: "Bekannte Hosts…" (⌘⇧K) + the
  import/export entries MIRRORED there ("Alle Sessions exportieren…",
  "Sessions importieren…" — same handlers as in the sidebar menu, the
  sidebar entries stay). "Logins… ⌘⇧L" follows in M10b.
- Sidebar background context menu: "Bekannte Hosts…" (above the
  export/import entries, with a separator).
- TOFU prompt: footnote/link "Bekannte Hosts verwalten…" — opens the
  sheet, the prompt stays open and remains valid.
- Wired through the existing `TabCommands` bridge (menu) or sheet state
  in ContentView; key-window guards as with the tab commands.

## 4. Tests

- Core: allKeys empty/sorted; remove removes exactly the triple match,
  no-op otherwise, persists; addedAt round trip; LEGACY JSON without
  addedAt reads nil (forward compatibility, raw JSON test); upsert
  stamps the date (also when replacing); fingerprint derivation
  unchanged (regression).
- App (sheet, menu, footnote): visual smoke (T3), including proof:
  remove host → reconnect → TOFU prompt appears again.

## 5. Deliberately NOT in M10a

- No manual editing/adding; no known_hosts file import (OpenSSH format)
  — backlog candidate.
- No "Logins" area (M10b), no jump host (M10c).
