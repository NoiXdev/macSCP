# M5h — Design-Polish Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Sessions-Sidebar übernimmt Fläche (getönter Mischton + rechte Hairline), Zeilen-Rhythmus und Label-Typo aus dem CI-Mockup — reiner View-Layer, null Verhaltensänderung.

**Architecture:** Drei neue Flächen-Tokens (`paper`, `card`, `sidebarSurface`) über den bestehenden `dynamicNS`-Helper; `SessionSidebar` bekommt die getönte Container-Fläche mit Hairline-Kante, die drei Abschnitts-Label-Stellen die exakte Mockup-Typo, `SessionRow` die 5×10-Maße mit `remoteSoft`-Aktiv-Fill. Ein Koordinator-Abschlusstask verifiziert visuell in beiden Appearances und darf die Listen-Fluchtung um wenige Punkte feinjustieren.

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5h-sidebar-polish-design.md` — bindend, inkl. Wertetabelle.
- KEINE Verhaltensänderung: Kontextmenüs, Inline-Rename (Enter/Escape/Blur-Cancel), Drag & Drop, Lösch-Dialog, Neue-Gruppe-Alert, Collapse-State, `interactionsDisabled`, Fehlertext-Bereich — exakt wie heute. Alle Callbacks/State-Maschinen in `SessionSidebar`/`SessionRow` unangetastet.
- Beide Appearances über dynamische Tokens; keine statischen Farben in Views.
- CI-Regeln: Blau = aktiv/Auswahl (`remoteSoft`/`remoteBlue`), Phosphor nur Status.
- Code + Kommentare NUR Englisch; Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` und volle `swift test` (295) nach jedem Task grün.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 → T3 sequenziell.

---

### Task 1: Flächen-Tokens

**Files:**
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (unter den M5g-Tokens ergänzen)

**Interfaces:**
- Consumes: bestehender privater Helper `dynamicNS(light:dark:alpha:)`.
- Produces (T2 verlässt sich exakt hierauf):
  - `DesignTokens.paper: Color` — hell `#F4F7FA`, dunkel `#0D1720`
  - `DesignTokens.card: Color` — hell `#FFFFFF`, dunkel `#14212E`
  - `DesignTokens.sidebarSurface: Color` — hell `#FCFDFE`, dunkel `#121E2A`

- [x] **Step 1: Implementieren** — nach `localSoft` einfügen:

```swift
    // Surface hierarchy (mockup: paper ground, card content surface).
    // `paper`/`card` are staged for the transfer-bar and form polish
    // rounds; M5h consumes only `sidebarSurface`.
    static let paper = Color(nsColor: dynamicNS(light: 0xF4F7FA, dark: 0x0D1720))
    static let card = Color(nsColor: dynamicNS(light: 0xFFFFFF, dark: 0x14212E))
    /// The mockup's sidebar tint: color-mix(card 70%, paper), precomputed
    /// per appearance so it stays a single deterministic dynamic color.
    static let sidebarSurface = Color(nsColor: dynamicNS(light: 0xFCFDFE, dark: 0x121E2A))
```

- [x] **Step 2: Build + Suite** — `swift build` fehlerfrei, `swift test` 295/295.
- [x] **Step 3: Commit** — `feat: add surface hierarchy design tokens`.

---

### Task 2: Sidebar-Fläche, Label-Typo, Zeilen-Maße

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (aktuell 368 Zeilen; NUR die unten gezeigten Styling-Stellen — sämtliche Logik, Callbacks, Menüs, Rename-/Drop-/Alert-Maschinerie bleiben byte-identisch)

**Interfaces:**
- Consumes: T1 `sidebarSurface` + M5g-Tokens `hairline`, `inkTertiary`, `remoteSoft`.
- Produces: keine neuen APIs.

- [x] **Step 1: Container-Fläche + Hairline-Kante** — am äußeren `VStack` (nach `.disabled(interactionsDisabled)`, vor `.alert`):

```swift
        .padding(.top, 12)
        .background(DesignTokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(width: 1)
        }
```

  (Das 12-pt-Top-Padding ist das Container-Padding der Spec-Tabelle; die
  horizontalen ~8 pt liefern List-Insets + Label-/Zeilen-Padding, kein
  zusätzlicher Modifier nötig.)

- [x] **Step 2: Label-Typo an drei Stellen** — identischer Stil, jeweils ersetzen:

„SESSIONS"-Label (Zeilen 39–44), alt `.font(.caption2.weight(.semibold)) .tracking(0.8) .foregroundStyle(.secondary) .padding(.horizontal, 12) .padding(.vertical, 6)` → neu:

```swift
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(DesignTokens.inkTertiary)
                .padding(.top, 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
```

`groupHeader`-Text (Zeilen 168–172) und „IMPORTIERT"-Header (Zeilen 210–213): dieselben drei Modifier (`font`/`tracking(1.0)`/`foregroundStyle(DesignTokens.inkTertiary)`) anstelle von `.font(.caption2.weight(.semibold)) .tracking(0.8) .foregroundStyle(.secondary)`; die Header liegen in der List und behalten ihre List-Insets (kein zusätzliches Padding), Kontextmenü/Drop/Rename unverändert.

- [x] **Step 3: Zeilen-Maße in `SessionRow`** — Padding und Aktiv-Fill (Zeilen 323–330) ersetzen:

```swift
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? DesignTokens.remoteSoft
                      : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
```

  und in `sessionRows(_:)` auf die `SessionRow` anwenden: `.listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 6))` (2 pt effektiver Zeilenabstand; leading 0, weil die Zeile ihr 10-pt-Innenpadding selbst trägt und mit dem 10-pt-Label-Padding fluchtet).

- [x] **Step 4: Build + volle Suite** — `swift build`, `swift test` 295/295.
- [x] **Step 5: Commit** — `feat: tint the sidebar surface and align rows with the mockup rhythm`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [x] `swift test` gesamt; Rig hoch (`docker compose -f docker/test-server/compose.yml start` — Container existiert gestoppt, `start` behält Host-Keys) und `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` voll grün.
- [x] **Visueller Smoke in HELL und DUNKEL** (hell app-only via `NSRequiresAquaSystemAppearance` im Wrapper-Info.plist erzwingen, danach ENTFERNEN):
  - Getönte Sidebar-Fläche hebt sich von der Pane-Fläche ab; 1-pt-Hairline an der rechten Kante sichtbar.
  - Labels („SESSIONS", Gruppenname, „IMPORTIERT") 10,5 pt versal mit Laufweite in inkTertiary; Fluchtung Labels ↔ Zeilen (beide 10 pt vom Rand) — bei Abweichung darf der Koordinator die `listRowInsets`-Werte um ±2 pt nachjustieren (als eigener `fix:`-Commit).
  - Aktive Zeile: `remoteSoft`-Pille (r6) + blaue semibold-Schrift + Phosphor-Punkt; Hover dezent.
  - Verhaltens-Regression: Verbinden-Klick, Kontextmenü (Session + Gruppe + Hintergrund), Inline-Rename Enter/Escape, Gruppe ein-/ausklappen, Lösch-Dialog (Abbrechen).
- [x] Checkboxen im Plan abhaken, Commit `docs: mark M5h plan tasks as completed` (+ Footer).

## Ausblick

Runde 3: Transfer-Leiste (5-pt-Pillen-Progress r99, 8×14-Maße) & Terminal-Strip · Runde 4: Formular-Grid (110-pt-Labels) & Button-Radien r7. Danach M6 — Release.
