# M5j — Design-Polish Transfer-Leiste & Terminal-Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer-Leiste und Terminal-Panel übernehmen Maße, Typo und die Pillen-Progress-Form aus dem CI-Mockup — reiner View-Layer, null Verhaltensänderung.

**Architecture:** `TransferQueueBar` bekommt Hairline-Top, 8×14-Maße, 12-pt-Typo mit ink/inkSecondary und eine neue private `PillProgress`-Capsule (Form vom Mockup, Füllung semantisch amber/blau per CI-Regel); das `terminalPanel` in `ContentView` bekommt eine Hairline-Oberkante und der „Shell beendet"-Zustand die Strip-Maße. Alle Tokens existieren bereits (M5g/M5h).

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-m5j-transferbar-terminal-polish-design.md` — bindend, inkl. Wertetabelle und Farbentscheidung (Pillen-FÜLLUNG semantisch `localAmber` Upload / `remoteBlue` Download; nur die FORM — 5-pt-Capsule r99, Track in Hairline — kommt vom Mockup).
- KEINE Verhaltensänderung: Queue-Status-Semantik (queued/running/finished/failed/cancelled/skipped/interrupted), Aufräumen-Button-Logik, Rate/ETA-Label-Logik, Resume-Banner, Konflikt-Sheet, Terminal-Lifecycle/⌘T/Replay — exakt wie heute. Fehler bleiben System-Rot, „interrupted" bleibt `.orange`.
- Beide Appearances über vorhandene dynamische Tokens (`hairline`, `ink`, `inkSecondary`, `localAmber`, `remoteBlue`); keine neuen statischen Farben.
- Code + Kommentare NUR Englisch; Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` und volle `swift test` (295) nach jedem Task grün.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 → T3 sequenziell (T1 und T2 teilen keine Datei, sind aber je klein; sequenziell ist einfacher).

---

### Task 1: Transfer-Leiste im Mockup-Rhythmus + PillProgress

**Files:**
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (aktuell 109 Zeilen; Struktur/Status-Zweige bleiben, nur Styling + der determinate Progress-Zweig ändern sich)

**Interfaces:**
- Consumes: `DesignTokens.hairline`, `.ink`, `.inkSecondary`, `.localAmber`, `.remoteBlue` (alle vorhanden).
- Produces: private `PillProgress(fraction: Double, fill: Color)`-View in derselben Datei — kein API-Export.

- [ ] **Step 1: Styling umstellen** — exakte Änderungen:

a) `Divider()` (Zeile 18) →

```swift
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
```

b) Kopfzeile: Titel-Modifier `.font(.caption.weight(.semibold)).foregroundStyle(.secondary)` → `.font(.system(size: 12, weight: .semibold)).foregroundStyle(DesignTokens.inkSecondary)`; Kopf-Padding `.padding(.horizontal, 12).padding(.vertical, 4)` → `.padding(.horizontal, 14).padding(.vertical, 8)`.

c) Listen-Container: `.padding(.horizontal, 12).padding(.bottom, 6)` → `.padding(.horizontal, 14).padding(.bottom, 8)`.

d) Zeile: `HStack(spacing: 8)` → `HStack(spacing: 12)`; am Zeilen-Ende `.font(.callout)` → `.font(.system(size: 12))`; Dateiname-`Text(item.fileName)` bekommt zusätzlich `.foregroundStyle(DesignTokens.ink)`; ALLE `.foregroundStyle(.secondary)`-Vorkommen in den Status-Zweigen (queued/Rate-Label/cancelled/skipped) → `.foregroundStyle(DesignTokens.inkSecondary)`; die `.font(.caption)`-Vorkommen in den Status-Zweigen bleiben `.caption` (11 pt — sekundär kleiner als die 12-pt-Zeile, wie im Mockup-Verhältnis). Fehler-Zweig (rot) und interrupted-Zweig (orange) NUR die Schriftgröße betreffend unverändert lassen.

e) Determinate-Progress-Zweig (Zeilen 78–81) ersetzen:

```swift
                if let fraction = progress.fraction {
                    PillProgress(fraction: fraction, fill: tint(for: item.direction))
                        .frame(width: 120)
                } else {
```

- [ ] **Step 2: PillProgress anfügen** — am Dateiende:

```swift
/// Mockup-style progress pill: 5pt capsule track in the hairline color,
/// capsule fill in the transfer direction's brand color (CI rule: amber =
/// upload, blue = download — only the SHAPE comes from the mockup).
private struct PillProgress: View {
    let fraction: Double
    let fill: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.hairline)
                Capsule()
                    .fill(fill)
                    .frame(width: max(5, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}
```

  (Die `max(5, …)`-Untergrenze hält die Füll-Capsule rund, solange fraction > 0 klein ist; fraction wird defensiv auf 0…1 geklemmt.)

- [ ] **Step 3: Build + volle Suite** — `swift build` fehlerfrei, `swift test` 295/295.
- [ ] **Step 4: Commit** — `feat: restyle the transfer bar with the mockup pill progress`.

---

### Task 2: Terminal-Panel — Hairline-Oberkante + ended-Maße

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift:404-421` (`terminalPanel`)

**Interfaces:**
- Consumes: `DesignTokens.hairline` (vorhanden).
- Produces: keine neuen APIs.

- [ ] **Step 1: Implementieren** — `terminalPanel` wird zu:

```swift
    @ViewBuilder
    private func terminalPanel(_ session: BrowserSession) -> some View {
        ZStack {
            Color(nsColor: DesignTokens.terminalBackground)
            switch session.terminal.state {
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? L10n.string("terminal.ended", "Shell ended."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button(L10n.string("terminal.reopen", "Reopen")) { session.terminal.openIfNeeded() }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
            case .closed:
                Color.clear
            }
        }
        // Mockup: the terminal strip carries a hairline top border.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
```

  (Einzige Änderungen gegenüber heute: die zwei Padding-Modifier + `font` im ended-Zweig und das Hairline-Overlay; Lifecycle/State-Switch identisch.)

- [ ] **Step 2: Build + volle Suite** — `swift build`, `swift test` 295/295.
- [ ] **Step 3: Commit** — `feat: add the mockup hairline edge to the terminal panel`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] `swift test` gesamt; Rig hoch (`docker compose -f docker/test-server/compose.yml start` — `start`, nicht `up`/`down`, Host-Keys bleiben) und `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` voll grün.
- [ ] **Visueller Smoke in HELL und DUNKEL** (hell app-only via `NSRequiresAquaSystemAppearance`, danach ENTFERNEN):
  - In den Einstellungen das Download-Limit auf ~200 KB/s stellen, eine ~8-MB-Datei remote→lokal ziehen (oder Download-Button) → die Pille füllt sichtbar: 5-pt-Capsule, Track in Hairline-Farbe, Füllung BLAU (Download); danach ein Upload → Füllung BERNSTEIN; Limit wieder auf 0.
  - Hairline über der Transfer-Leiste und als Terminal-Oberkante (⌘T) sichtbar; Kopf-/Zeilen-Maße 8×14; Dateiname in ink, Sekundärtexte inkSecondary.
  - „Shell beendet"-Zustand: im Terminal `exit` tippen → 12-pt-Text mit 8×14-Padding, Reopen funktioniert.
  - Verhaltens-Regression: Transfer läuft durch (✓-Häkchen in Richtungsfarbe), Aufräumen leert, ⌘T auf/zu, Rate/ETA-Label erscheint.
- [ ] Checkboxen im Plan abhaken, Commit `docs: mark M5j plan tasks as completed` (+ Footer).

## Ausblick

Runde 4 (letzte): Formular-Grid (110-pt-Labels) & Button-Radien r7. Danach M6 — Release.
