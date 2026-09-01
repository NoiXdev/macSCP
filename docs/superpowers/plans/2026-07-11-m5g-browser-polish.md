# M5g — Design Polish Browser Main View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The browser main view (file list, pane heads, pane divider) takes over surfaces, hairlines, type rhythm and radii exactly from the CI mockup — pure view layer, zero behavior change.

**Architecture:** New appearance-aware design tokens (NSColor base + SwiftUI wrapper, pattern of the existing duo colors); the AppKit file list gets its own `NSTableHeaderCell` and `NSTableRowView` subclass (uppercase header, remote-soft selection) plus grid/row configuration; the pane heads are switched to the mockup dimensions. The HSplitView system divider stays (draggability > look; it is already ~1 pt on macOS 15).

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, SwiftUI + AppKit (`NSTableView`), macOS 15+. No new unit tests (view layer); the existing 295 stay green.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5g-browser-polish-design.md` — binding, including the mockup value table.
- NO behavior change: sorting, selection logic/callbacks, double-click (folder cd + `onOpenFile`), context menus, drag sources/file promise, drop target, symlink " →" suffix stay exactly as they are today. `RemoteFileTableView.Coordinator` logic untouched.
- Both appearances: all new colors as dynamic tokens (`NSColor(name:dynamicProvider:)` pattern), no static colors in views.
- CI rules (`docs/design/ci.md`): amber local only, blue = selection/remote/primary, phosphor status only; row selection in BOTH panes `remoteSoft`.
- Localization: column titles stay catalog keys; uppercase display is a display transform (`uppercased(with: .current)` resp. `.uppercased()` in SwiftUI).
- Paths/number columns in mono resp. `monospacedDigit` (CI: SF Mono for paths and number columns).
- Code + comments English ONLY; Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` and the full `swift test` (295) must be green after every task.
- Environment note: Bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and retry identically.

## Schedule

T1 → T2 → T3 → T4 sequentially (T2/T3 consume T1 tokens; T3 shares no file with T2, but is small — parallelizing is not worth it).

---

### Task 1: Extend design tokens

**Files:**
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (currently 31 lines)

**Interfaces:**
- Consumes: existing pattern `NSColor(name: nil) { appearance in … }`.
- Produces (T2/T3 rely on this exactly):
  - `DesignTokens.hairlineNS: NSColor` / `hairline: Color` — light `#DAE3EB`, dark `#24374A`
  - `DesignTokens.hairlineFaintNS: NSColor` — like `hairline`, but alpha 0.45 IN the provider (row hairlines)
  - `DesignTokens.inkNS: NSColor` / `ink: Color` — light `#14212E`, dark `#E8EFF5`
  - `DesignTokens.inkSecondaryNS: NSColor` / `inkSecondary: Color` — light `#4A5B6B`, dark `#A7B7C5`
  - `DesignTokens.inkTertiaryNS: NSColor` / `inkTertiary: Color` — light `#7E8FA0`, dark `#6E8093`
  - `DesignTokens.remoteSoftNS: NSColor` / `remoteSoft: Color` — light `#E3EEF9`, dark `#142C42`
  - `DesignTokens.localSoft: Color` — light `#FBF1DF`, dark `#2C2415` (SwiftUI consumer only)

- [x] **Step 1: Implement** — add in `DesignTokens.swift` below the existing tokens (helper first, so no hex copy-paste error happens):

```swift
    /// Appearance-aware color from two sRGB hex values (light/dark) — the
    /// mockup's CSS custom properties, one Swift constant each.
    private static func dynamicNS(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255,
             CGFloat((hex >> 8) & 0xFF) / 255,
             CGFloat(hex & 0xFF) / 255)
        }
        return NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(dark) : rgb(light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
    }

    // Mockup surface/typography tokens (spec table, M5g). NS variants exist
    // because the AppKit file table consumes NSColor directly.
    static let hairlineNS = dynamicNS(light: 0xDAE3EB, dark: 0x24374A)
    static let hairline = Color(nsColor: hairlineNS)
    /// Row separators: the hairline at 45% opacity, baked into the provider
    /// so it stays a single dynamic color (withAlphaComponent on a dynamic
    /// color is avoided deliberately).
    static let hairlineFaintNS = dynamicNS(light: 0xDAE3EB, dark: 0x24374A, alpha: 0.45)
    static let inkNS = dynamicNS(light: 0x14212E, dark: 0xE8EFF5)
    static let ink = Color(nsColor: inkNS)
    static let inkSecondaryNS = dynamicNS(light: 0x4A5B6B, dark: 0xA7B7C5)
    static let inkSecondary = Color(nsColor: inkSecondaryNS)
    static let inkTertiaryNS = dynamicNS(light: 0x7E8FA0, dark: 0x6E8093)
    static let inkTertiary = Color(nsColor: inkTertiaryNS)
    static let remoteSoftNS = dynamicNS(light: 0xE3EEF9, dark: 0x142C42)
    static let remoteSoft = Color(nsColor: remoteSoftNS)
    static let localSoft = Color(nsColor: dynamicNS(light: 0xFBF1DF, dark: 0x2C2415))
```

- [x] **Step 2: Build + suite** — `swift build` error-free, `swift test` 295/295 (pure constants, no consumers changed).
- [x] **Step 3: Commit** — `git add Sources/MacSCPApp/DesignTokens.swift && git commit -m "feat: add mockup surface and typography design tokens"` (+ footer).

---

### Task 2: File list in the mockup rhythm (RISK — AppKit)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (currently 161 lines; ONLY `makeNSView`, `tableView(_:viewFor:row:)` and new private subclasses — the rest of the coordinator logic stays byte-identical)

**Interfaces:**
- Consumes: T1 tokens (`hairlineNS`, `hairlineFaintNS`, `inkNS`, `inkSecondaryNS`, `inkTertiaryNS`, `remoteSoftNS`).
- Produces: nothing new externally — `RemoteFileTableView`'s public parameters stay unchanged.

Binding values (spec table): header 10.5 pt semibold uppercase, tracking ~0.8 pt, `inkTertiary`, height ~22 pt, 12 pt indent, hairline below · rows 24 pt tall, 12 pt lateral cell padding, hairline (`hairlineFaint`) between rows, NO zebra striping · name in `ink` 12.5 pt, size/date `inkSecondary` 12.5 pt `monospacedDigit`, size right-aligned · selection rectangular `remoteSoft` in both panes, even without window focus.

- [x] **Step 1: Implement subclasses** — insert at the end of the file (after the coordinator):

```swift
/// Mockup-style column header: versal 10.5pt semibold with tracking in
/// inkTertiary, 12pt leading inset, hairline bottom border (spec M5g).
private final class PolishedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Flat background matching the enclosing window chrome.
        NSColor.controlBackgroundColor.setFill()
        cellFrame.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: DesignTokens.inkTertiaryNS,
            .kern: 0.8,
        ]
        let text = NSAttributedString(
            string: stringValue.uppercased(with: .current), attributes: attributes)
        let size = text.size()
        let textRect = NSRect(
            x: cellFrame.minX + 12,
            y: cellFrame.midY - size.height / 2,
            width: cellFrame.width - 16,
            height: size.height)
        text.draw(in: textRect)

        DesignTokens.hairlineNS.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1,
               width: cellFrame.width, height: 1).fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Everything happens in draw(withFrame:in:) — keep AppKit from
        // painting the default title on top.
    }
}

/// Mockup-style row: rectangular remoteSoft selection in BOTH panes (blue is
/// the selection color per CI), identical with and without key focus.
private final class PolishedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        DesignTokens.remoteSoftNS.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false } // never fall back to the vibrant system blue
        set {}
    }
}
```

- [x] **Step 2: Switch over `makeNSView`** — replace the configuration block (the column loop stays, it just gets the header cell):

```swift
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Mockup row separators: hairline at 45% between rows.
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = DesignTokens.hairlineFaintNS
        table.headerView = NSTableHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: 22))

        for (identifier, title, width) in [
            ("name", L10n.string("filetable.column.name", "Name"), 260.0),
            ("size", L10n.string("filetable.column.size", "Size"), 90.0),
            ("modified", L10n.string("filetable.column.modified", "Modified"), 160.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            let header = PolishedHeaderCell(textCell: title)
            column.headerCell = header
            column.width = width
            table.addTableColumn(column)
        }
        …
```

  (the rest of the method — dataSource/delegate/doubleAction/drag mask/scrollView — unchanged.)

- [x] **Step 3: Extend delegate** — in the coordinator ONLY add (do not change anything existing):

```swift
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let reuseID = NSUserInterfaceItemIdentifier("polished-row")
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil)
                as? PolishedRowView {
                return reused
            }
            let rowView = PolishedRowView()
            rowView.identifier = reuseID
            return rowView
        }
```

- [x] **Step 4: Cell styling in `tableView(_:viewFor:row:)`** — when creating the field, 12 pt insets, then column-dependent typography (after `cell.textField?.stringValue = text`):

```swift
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
```

```swift
            cell.textField?.stringValue = text
            switch columnID {
            case "name":
                cell.textField?.font = .systemFont(ofSize: 12.5)
                cell.textField?.textColor = DesignTokens.inkNS
                cell.textField?.alignment = .natural
            case "size":
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .right
            default: // "modified"
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
                cell.textField?.textColor = DesignTokens.inkSecondaryNS
                cell.textField?.alignment = .natural
            }
            return cell
```

- [x] **Step 5: Build + full suite** — `swift build`, `swift test` 295/295.
- [x] **Step 6: Self smoke test (build/launch only, no GUI automation)** — build the app; if a wrapper launch without GUI automation is possible, visual check, otherwise leave it to the coordinator (T4 verifies fully).
- [x] **Step 7: Commit** — `feat: restyle the file table to the mockup rhythm`.

---

### Task 3: Pane heads to mockup dimensions + hairline

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift:22-56` (header HStack + divider)
- Modify: `Sources/MacSCPApp/ContentView.swift` (BrowserPane call sites: new parameter `softTint`)

**Interfaces:**
- Consumes: T1 tokens (`localSoft`, `remoteSoft`, `inkTertiary`, `hairline`).
- Produces: `BrowserPane` gets a new parameter `let softTint: Color` right after `tint`; ContentView passes `softTint: DesignTokens.localSoft` (local) resp. `DesignTokens.remoteSoft` (remote).

- [x] **Step 1: Rebuild header** — in `BrowserPane.body` replace the HStack + divider:

```swift
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.9)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(softTint, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                Text(viewModel.currentPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help(L10n.string("browser.pane.goUpHelp", "Parent directory"))

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help(L10n.string("browser.pane.refreshHelp", "Refresh"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
```

  and add `let softTint: Color` to the property list (after `tint`).

- [x] **Step 2: ContentView call sites** — add the parameter to both `BrowserPane(...)` initializations (ContentView, detail branch): local `softTint: DesignTokens.localSoft`, remote `softTint: DesignTokens.remoteSoft`.

- [x] **Step 3: Pane divider — document the decision, no rebuild:** The `HSplitView` system divider stays unchanged (it is ~1 pt wide on macOS 15 and stays draggable; spec: function > look). NO code step; T4 checks visually whether the divider color clashes noticeably next to the hairlines — if so, it is noted as a point for the follow-up round, not fixed in M5g.

- [x] **Step 4: Build + full suite** — `swift build`, `swift test` 295/295.
- [x] **Step 5: Commit** — `feat: align the pane headers with the mockup metrics`.

---

### Task 4: Final verification (coordinator)

- [x] `swift test` overall; then bring up the rig (`docker compose -f docker/test-server/compose.yml start`, container exists stopped — `start`, NOT `up`/`down`, so the host keys stay) and `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` fully green.
- [x] **Visual smoke test, side by side with the mockup, in LIGHT and DARK** (appearance switchable via `defaults write -g AppleInterfaceStyle`/system toggle or window screenshots in both modes):
  - File list: uppercase column heads (10.5 pt, tracking, inkTertiary, hairline below the header), 24 pt rows with hairline separators instead of zebra striping, name in full ink / size+date in inkSecondary with tabular figures, size right-aligned, 12 pt indents flush header↔cells.
  - Selection: `remoteSoft` rectangle in BOTH panes, identical with/without window focus, text readable in both appearances.
  - Pane heads: 7×12 dimensions, badge on soft ground (amber-soft local, blue-soft remote), path 11.5 pt mono in inkTertiary with middle ellipsis, hairline instead of divider.
  - Judge HSplitView divider color next to the hairlines (note only).
  - **Behavior regression:** folder double-click (cd), remote file double-click (editor opens), selection → upload/download buttons, drag local→remote (drop upload) and remote→Finder (promise), sidebar context menu untouched, symlink suffix " →" visible.
- [x] Check off checkboxes in the plan, commit `docs: mark M5g plan tasks as completed` (+ footer).

## Outlook

Follow-up rounds (each its own mini-milestone, same blueprint): sidebar surface & rhythm · transfer bar (pill progress) & terminal strip · form grid & button radii. After that M6 — release.
