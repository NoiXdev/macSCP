# M5g — Design-Polish Browser-Hauptansicht Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Browser-Hauptansicht (Dateiliste, Paneheads, Pane-Trenner) übernimmt Flächen, Haarlinien, Typo-Rhythmus und Radien exakt aus dem CI-Mockup — reiner View-Layer, null Verhaltensänderung.

**Architecture:** Neue appearance-aware Design-Tokens (NSColor-Basis + SwiftUI-Wrapper, Muster der bestehenden Duo-Farben); die AppKit-Dateiliste bekommt eine eigene `NSTableHeaderCell`- und `NSTableRowView`-Subclass (versale Header, remote-soft-Selektion) plus Grid-/Row-Konfiguration; die Paneheads werden auf die Mockup-Maße umgestellt. Der HSplitView-Systemsteg bleibt (Ziehbarkeit > Optik; er ist auf macOS 15 bereits ~1 pt).

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, SwiftUI + AppKit (`NSTableView`), macOS 15+. Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5g-browser-polish-design.md` — bindend, inkl. der Mockup-Wertetabelle.
- KEINE Verhaltensänderung: Sortierung, Auswahl-Logik/-Callbacks, Doppelklick (Ordner-cd + `onOpenFile`), Kontextmenüs, Drag-Quellen/File-Promise, Drop-Ziel, Symlink-„ →"-Suffix bleiben exakt wie heute. `RemoteFileTableView.Coordinator`-Logik unangetastet.
- Beide Appearances: alle neuen Farben als dynamische Tokens (`NSColor(name:dynamicProvider:)`-Muster), keine statischen Farben in Views.
- CI-Regeln (`docs/design/ci.md`): Bernstein nur lokal, Blau = Auswahl/Remote/Primär, Phosphor nur Status; Zeilen-Auswahl in BEIDEN Panes `remoteSoft`.
- Lokalisierung: Spaltentitel bleiben Katalog-Keys; Versal-Darstellung ist Anzeige-Transformation (`uppercased(with: .current)` bzw. `.uppercased()` in SwiftUI).
- Pfade/Zahlenspalten in Mono bzw. `monospacedDigit` (CI: SF Mono für Pfade und Zahlenspalten).
- Code + Kommentare NUR Englisch; Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` und volle `swift test` (295) müssen nach jedem Task grün sein.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 → T3 → T4 sequenziell (T2/T3 konsumieren T1-Tokens; T3 teilt keine Datei mit T2, ist aber klein — Parallelisierung lohnt nicht).

---

### Task 1: Design-Tokens erweitern

**Files:**
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (aktuell 31 Zeilen)

**Interfaces:**
- Consumes: bestehendes Muster `NSColor(name: nil) { appearance in … }`.
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `DesignTokens.hairlineNS: NSColor` / `hairline: Color` — hell `#DAE3EB`, dunkel `#24374A`
  - `DesignTokens.hairlineFaintNS: NSColor` — wie `hairline`, aber Alpha 0.45 IM Provider (Zeilen-Hairlines)
  - `DesignTokens.inkNS: NSColor` / `ink: Color` — hell `#14212E`, dunkel `#E8EFF5`
  - `DesignTokens.inkSecondaryNS: NSColor` / `inkSecondary: Color` — hell `#4A5B6B`, dunkel `#A7B7C5`
  - `DesignTokens.inkTertiaryNS: NSColor` / `inkTertiary: Color` — hell `#7E8FA0`, dunkel `#6E8093`
  - `DesignTokens.remoteSoftNS: NSColor` / `remoteSoft: Color` — hell `#E3EEF9`, dunkel `#142C42`
  - `DesignTokens.localSoft: Color` — hell `#FBF1DF`, dunkel `#2C2415` (nur SwiftUI-Konsument)

- [ ] **Step 1: Implementieren** — in `DesignTokens.swift` unter den bestehenden Tokens ergänzen (Helfer zuerst, damit kein Hex-Copy-Paste-Fehler passiert):

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

- [ ] **Step 2: Build + Suite** — `swift build` fehlerfrei, `swift test` 295/295 (reine Konstanten, keine Konsumenten geändert).
- [ ] **Step 3: Commit** — `git add Sources/MacSCPApp/DesignTokens.swift && git commit -m "feat: add mockup surface and typography design tokens"` (+ Footer).

---

### Task 2: Dateiliste im Mockup-Rhythmus (RISK — AppKit)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (aktuell 161 Zeilen; NUR `makeNSView`, `tableView(_:viewFor:row:)` und neue private Subclasses — die übrige Coordinator-Logik bleibt byte-identisch)

**Interfaces:**
- Consumes: T1-Tokens (`hairlineNS`, `hairlineFaintNS`, `inkNS`, `inkSecondaryNS`, `inkTertiaryNS`, `remoteSoftNS`).
- Produces: nichts Neues nach außen — `RemoteFileTableView`s öffentliche Parameter bleiben unverändert.

Bindende Werte (Spec-Tabelle): Header 10,5 pt semibold versal, Laufweite ~0,8 pt, `inkTertiary`, Höhe ~22 pt, 12 pt Einzug, Hairline unten · Zeilen 24 pt hoch, 12 pt seitliches Zellen-Padding, Hairline (`hairlineFaint`) zwischen Zeilen, KEIN Zebra · Name in `ink` 12,5 pt, Größe/Datum `inkSecondary` 12,5 pt `monospacedDigit`, Größe rechtsbündig · Auswahl rechteckig `remoteSoft` in beiden Panes, auch ohne Fenster-Fokus.

- [ ] **Step 1: Subclasses implementieren** — am Dateiende (nach dem Coordinator) einfügen:

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

- [ ] **Step 2: `makeNSView` umstellen** — den Konfigurationsblock ersetzen (Spalten-Schleife bleibt, bekommt nur die Header-Cell):

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

  (Rest der Methode — dataSource/delegate/doubleAction/Drag-Maske/ScrollView — unverändert.)

- [ ] **Step 3: Delegate erweitern** — im Coordinator NUR ergänzen (nichts Bestehendes ändern):

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

- [ ] **Step 4: Zellen-Styling in `tableView(_:viewFor:row:)`** — beim Anlegen des Feldes 12-pt-Insets, danach spaltenabhängige Typo (nach `cell.textField?.stringValue = text`):

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

- [ ] **Step 5: Build + volle Suite** — `swift build`, `swift test` 295/295.
- [ ] **Step 6: Eigen-Smoke (nur Bauen/Starten, keine GUI-Automation)** — App bauen; wenn ein Wrapper-Start ohne GUI-Automation möglich ist, Sichtprüfung, sonst dem Koordinator überlassen (T4 verifiziert vollständig).
- [ ] **Step 7: Commit** — `feat: restyle the file table to the mockup rhythm`.

---

### Task 3: Paneheads auf Mockup-Maße + Hairline

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift:22-56` (Header-HStack + Divider)
- Modify: `Sources/MacSCPApp/ContentView.swift` (BrowserPane-Aufrufe: neuer Parameter `softTint`)

**Interfaces:**
- Consumes: T1-Tokens (`localSoft`, `remoteSoft`, `inkTertiary`, `hairline`).
- Produces: `BrowserPane` erhält einen neuen Parameter `let softTint: Color` direkt nach `tint`; ContentView übergibt `softTint: DesignTokens.localSoft` (lokal) bzw. `DesignTokens.remoteSoft` (remote).

- [ ] **Step 1: Header umbauen** — in `BrowserPane.body` den HStack + Divider ersetzen:

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

  und die Property-Liste um `let softTint: Color` (nach `tint`) ergänzen.

- [ ] **Step 2: ContentView-Aufrufe** — beide `BrowserPane(...)`-Initialisierungen (ContentView, detail-Zweig) um den Parameter ergänzen: lokal `softTint: DesignTokens.localSoft`, remote `softTint: DesignTokens.remoteSoft`.

- [ ] **Step 3: Pane-Trenner — Entscheidung dokumentieren, kein Umbau:** Der `HSplitView`-Systemsteg bleibt unverändert (er ist auf macOS 15 ~1 pt breit und bleibt ziehbar; Spec: Funktion > Optik). KEIN Code-Schritt; T4 prüft visuell, ob die Steg-Farbe neben den Hairlines störend abweicht — falls ja, wird das als Punkt für die Folgerunde notiert, nicht in M5g gefixt.

- [ ] **Step 4: Build + volle Suite** — `swift build`, `swift test` 295/295.
- [ ] **Step 5: Commit** — `feat: align the pane headers with the mockup metrics`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [ ] `swift test` gesamt; danach Rig hoch (`docker compose -f docker/test-server/compose.yml start`, Container existiert gestoppt — `start`, NICHT `up`/`down`, damit die Host-Keys bleiben) und `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` voll grün.
- [ ] **Visueller Smoke, Seite an Seite mit dem Mockup, in HELL und DUNKEL** (Appearance umschaltbar per `defaults write -g AppleInterfaceStyle`/System-Toggle oder Fenster-Screenshots in beiden Modi):
  - Dateiliste: versale Spaltenköpfe (10,5 pt, Laufweite, inkTertiary, Hairline unter dem Header), 24-pt-Zeilen mit Hairline-Trennern statt Zebra, Name in Volltinte / Größe+Datum in inkSecondary mit Tabellenziffern, Größe rechtsbündig, 12-pt-Einzüge bündig Header↔Zellen.
  - Auswahl: `remoteSoft`-Rechteck in BEIDEN Panes, identisch mit/ohne Fensterfokus, Text lesbar in beiden Appearances.
  - Paneheads: 7×12-Maße, Badge auf Soft-Grund (bernstein-soft lokal, blau-soft remote), Pfad 11,5 pt mono in inkTertiary mit Mitte-Ellipsis, Hairline statt Divider.
  - Steg-Farbe HSplitView neben den Hairlines beurteilen (nur notieren).
  - **Verhaltens-Regression:** Ordner-Doppelklick (cd), Datei-Doppelklick remote (Editor öffnet), Auswahl → Upload/Download-Buttons, Drag lokal→remote (Drop-Upload) und remote→Finder (Promise), Kontextmenü Sidebar unangetastet, Symlink-Suffix „ →" sichtbar.
- [ ] Checkboxen im Plan abhaken, Commit `docs: mark M5g plan tasks as completed` (+ Footer).

## Ausblick

Folgerunden (je eigener Mini-Milestone, gleiche Blaupause): Sidebar-Fläche & Rhythmus · Transfer-Leiste (Pillen-Progress) & Terminal-Strip · Formular-Grid & Button-Radien. Danach M6 — Release.
