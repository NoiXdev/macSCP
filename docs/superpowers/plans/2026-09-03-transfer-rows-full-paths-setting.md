# Transfer Rows Always Show Their Full Paths — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A setting under Settings → Transfers, "Always show full paths",
default off. When on, every transfer row shows its full source and
destination paths in a second line (source → destination, the same
qualified strings the hint shows), so the maintainer no longer has to
hover or open the context menu (maintainer request 2026-09-03, after
trying the dev build).

**Architecture:** one `Bool` on `SettingsStore` (`transfersShowFullPaths`,
persisted like `showHiddenFiles`), one toggle in the Transfers section of
`SettingsView` beside the S3 share-link expiry, and one conditional
second line in `TransferQueueBar`'s row built from the existing
`TransferRowPaths` fold (no second spelling of the paths). The hint and
"Copy paths" stay as they are.

**Tech Stack:** SwiftUI, `SettingsStore` (`@Observable`, JSON-backed),
Swift Testing; the row guards on `SwiftSource` views.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; zero warnings; do not push.
- Display strings through `L10n.string(_:_:)`; four App catalogs (`en`/`de`/`fr`/`pl`), German du; keys `settings.transfers.showFullPaths` (toggle label) and, if a header is needed, none new — the toggle sits under the existing Transfers section.
- The second line renders `TransferRowPaths`'s display strings (source, destination) — never a decorated `fileName`, never a raw path assembled in the view.
- Guards: `TransferQueueBarPathsGuardTests` gains a positive anchor that the row reads the setting and renders the fold's strings when it is on; no wall-clock ceilings; no `#require` on non-optionals (CI's compiler is Swift 6.1.2).

---

### Task 1: The setting, the toggle, the second line

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`public var transfersShowFullPaths: Bool`, default `false`, persisted under the key `transfersShowFullPaths`), `Sources/MacSCPAppKit/SettingsView.swift` (a `Toggle` in the Transfers section), `Sources/MacSCPAppKit/TransferQueueBar.swift` (the row's second line when the setting is on: `source → destination` in secondary style, truncating in the middle), four catalogs
- Test: `SettingsStoreTests` (round trip, default false, legacy JSON without the key loads false); `TransferQueueBarPathsGuardTests` (the row's second line is wired to the setting and to `TransferRowPaths`, positive anchor + a negative that no decorated name is rendered there); `SettingsViewGuardTests` or the existing settings wiring guard (the toggle exists, bound to the store's property, labelled through the key); catalogs complete (`swift test --filter Localiz`, `GermanAddressForm`).

- [ ] Red first, implement, `swift test` full once, zero warnings; commit `feat(transfers): a setting shows every row's full paths without hovering`.
