# M5k — Design-Polish Formular & Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Verbindungsformular übernimmt das Mockup-Feld-Grid (110-pt-Labels) und den Mockup-Button-Stil (r7, primär gefüllt in Remote-Blau) — reiner View-Layer, null Verhaltensänderung; damit ist die Design-Polish-Serie komplett.

**Architecture:** Neue Datei `PolishedButtonStyle` (ButtonStyle, zwei Varianten über `prominent`-Flag, Convenience `.polished`/`.polishedProminent`); in `ConnectionFormView` ersetzt eine private `FormRow`-Helper-View die SwiftUI-`Form` (System-TextFields bleiben → Tab-Kette/Fokus nativ), `errorHighlight` wandert auf die Zeilen, alle Formular-Buttons wechseln auf den neuen Stil. System-Chrome (Toolbar, Alerts, Sheets, Settings) bleibt unangetastet.

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-25-m5k-form-polish-design.md` — bindend, inkl. Wertetabelle (Label 110 pt rechtsbündig 12,5 pt `inkSecondary`, Gap 10, Zeilenabstand 10; Button r7, 5×14, 12,5 pt; sekundär `card`+`hairline`+`inkSecondary`; primär `remoteBlue`+Weiß semibold, gedrückt Opacity 0.85).
- KEINE Verhaltensänderung: Validierung/Alert-Fluss, Edit-Modus-Semantik (Passwort leer = „unverändert"), TOFU-Fluss, fileImporter, `keyboardShortcut(.defaultAction)`-Zuordnungen, `disabled`-Logik, Tab-Reihenfolge Host→Port→Benutzer→Passwort. TextField-Label-Parameter BLEIBEN (Accessibility-Labels), auch wenn das sichtbare Label künftig die `FormRow` liefert.
- Beide Appearances über vorhandene Tokens; Weiß auf `remoteBlue` ist bewusst statisch (Mockup `#fff` auf Markenblau).
- NICHT umgestellt: Toolbar, Alerts, Sheets, Settings, Sidebar (System-Chrome, M5f-Linie).
- Code + Kommentare NUR Englisch; Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` und volle `swift test` (295) nach jedem Task grün.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 → T3 sequenziell.

---

### Task 1: PolishedButtonStyle

**Files:**
- Create: `Sources/MacSCPApp/PolishedButtonStyle.swift`

**Interfaces:**
- Consumes: `DesignTokens.remoteBlue`, `.card`, `.hairline`, `.inkSecondary` (alle vorhanden).
- Produces: `PolishedButtonStyle: ButtonStyle` mit `let prominent: Bool`; `ButtonStyle`-Extension mit `static var polished` / `static var polishedProminent`.

- [ ] **Step 1: Datei anlegen** — vollständiger Inhalt:

```swift
import SwiftUI

/// Mockup button style (M5k): radius 7, 5x14 padding, 12.5pt type.
/// `prominent` fills with the CI primary blue (white semibold label);
/// the secondary variant sits on the card surface with a hairline border.
/// System chrome (toolbar, alerts, sheets) deliberately keeps the system
/// button styles — this style is for in-content forms only.
struct PolishedButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : DesignTokens.inkSecondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? DesignTokens.remoteBlue : DesignTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(DesignTokens.hairline, lineWidth: prominent ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension ButtonStyle where Self == PolishedButtonStyle {
    /// Secondary form button: card surface, hairline border.
    static var polished: PolishedButtonStyle { .init(prominent: false) }
    /// Primary form button: filled in the CI remote blue.
    static var polishedProminent: PolishedButtonStyle { .init(prominent: true) }
}
```

- [ ] **Step 2: Build + Suite** — `swift build` fehlerfrei, `swift test` 295/295 (noch keine Konsumenten).
- [ ] **Step 3: Commit** — `feat: add the mockup polished button style`.

---

### Task 2: Formular-Grid + Button-Anwendung

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (aktuell 241 Zeilen; `formContent`, die Button-Zeilen in `formContent` und `hostKeyPromptView`, plus neue private `FormRow` — Struktur/Callbacks/Alert/fileImporter/`errorHighlight`-Extension bleiben)

**Interfaces:**
- Consumes: T1 (`.polished`/`.polishedProminent`), `DesignTokens.inkSecondary`.
- Produces: private `FormRow<Content: View>` in derselben Datei.

- [ ] **Step 1: `FormRow` einfügen** — vor der `errorHighlight`-Extension:

```swift
/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters purely for
/// accessibility.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .frame(width: 110, alignment: .trailing)
            content
        }
    }
}
```

- [ ] **Step 2: `formContent` ersetzen** — die `Form { … } .disabled(isConnecting)` (Zeilen 79–152) wird zu:

```swift
            VStack(alignment: .leading, spacing: 10) {
                FormRow(label: L10n.string("connection.field.host", "Host")) {
                    TextField(
                        L10n.string("connection.field.host", "Host"), text: $viewModel.host,
                        prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                    )
                }
                .errorHighlight(failedField == .host)

                FormRow(label: L10n.string("connection.field.port", "Port")) {
                    TextField(L10n.string("connection.field.port", "Port"), text: $viewModel.port)
                }
                .errorHighlight(failedField == .port)

                FormRow(label: L10n.string("connection.field.username", "Username")) {
                    TextField(L10n.string("connection.field.username", "Username"), text: $viewModel.username)
                }
                .errorHighlight(failedField == .username)

                FormRow(label: L10n.string("connection.field.authMethod", "Authentication")) {
                    Picker(L10n.string("connection.field.authMethod", "Authentication"), selection: Binding(
                        get: { viewModel.authChoice },
                        set: { viewModel.selectAuthChoice($0) }
                    )) {
                        Text(L10n.string("connection.auth.password", "Password"))
                            .tag(ConnectionViewModel.AuthChoice.password)
                        Text(L10n.string("connection.auth.privateKey", "SSH key"))
                            .tag(ConnectionViewModel.AuthChoice.privateKey)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if viewModel.authChoice == .password {
                    FormRow(label: L10n.string("connection.auth.password", "Password")) {
                        SecureField(
                            L10n.string("connection.auth.password", "Password"), text: $viewModel.password,
                            prompt: isEditMode
                                ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                : nil
                        )
                    }
                    .errorHighlight(failedField == .password)
                } else {
                    FormRow(label: L10n.string("connection.field.keyPath", "Key path")) {
                        HStack(spacing: 6) {
                            TextField(
                                L10n.string("connection.field.keyPath", "Key path"), text: $viewModel.keyPath,
                                prompt: Text(L10n.string(
                                    "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519"))
                            )
                            // "…" is a pure symbol (ellipsis "browse" affordance), not
                            // natural-language text — identical in every locale, so it
                            // stays a literal rather than a catalog key.
                            Button("…") { showKeyImporter = true }
                                .buttonStyle(.polished)
                                .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                        }
                    }
                    .errorHighlight(failedField == .keyPath)

                    FormRow(label: L10n.string("connection.field.passphrase", "Passphrase (optional)")) {
                        SecureField(
                            L10n.string("connection.field.passphrase", "Passphrase (optional)"),
                            text: $viewModel.password,
                            prompt: isEditMode
                                ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                : nil
                        )
                    }
                    .errorHighlight(failedField == .password)
                }

                if !isEditMode {
                    FormRow(label: "") {
                        Toggle(
                            L10n.string("connection.saveToggle", "Save as session"),
                            isOn: $viewModel.shouldSaveSession)
                    }
                }

                if isEditMode || viewModel.shouldSaveSession {
                    FormRow(label: L10n.string("connection.field.saveName", "Session name")) {
                        TextField(
                            L10n.string("connection.field.saveName", "Session name"), text: $viewModel.saveName,
                            prompt: Text(L10n.string("connection.field.saveName.placeholder", "e.g. hetzner-web"))
                        )
                    }
                    .errorHighlight(failedField == .saveName)

                    FormRow(label: L10n.string("connection.field.group", "Group")) {
                        Picker(
                            L10n.string("connection.field.group", "Group"),
                            selection: $viewModel.selectedGroupID
                        ) {
                            Text(L10n.string("sidebar.noGroup", "No group")).tag(UUID?.none)
                            ForEach(groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isConnecting)
```

  Hinweise: `Passphrase (optional)` ist als 110-pt-Label lang — `Text` bricht bei Bedarf zweizeilig um, das ist akzeptiert (Mockup-Spalte ist fix). Der `Button("…")` bekommt bereits hier `.polished`.

- [ ] **Step 3: Buttons umstellen** — in der Button-HStack von `formContent`: „Zurück" und „Speichern" erhalten `.buttonStyle(.polished)`, „Speichern & verbinden" ersetzt `.buttonStyle(.borderedProminent)` durch `.buttonStyle(.polishedProminent)`, „Verbinden" ebenso; in `hostKeyPromptView`: „Zurück" `.buttonStyle(.polished)`, „Vertrauen & verbinden" `.buttonStyle(.polishedProminent)`. `keyboardShortcut`/`disabled` unverändert an Ort und Stelle.

- [ ] **Step 4: Build + volle Suite** — `swift build` fehlerfrei, `swift test` 295/295.
- [ ] **Step 5: Commit** — `feat: adopt the mockup form grid and button style in the connection form`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] `swift test` gesamt; Rig hoch (`docker compose -f docker/test-server/compose.yml start`) und `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` voll grün.
- [ ] **Visueller Smoke in HELL und DUNKEL** (hell app-only via `NSRequiresAquaSystemAppearance` im Wrapper, danach ENTFERNEN):
  - Grid: 110-pt-Labels rechtsbündig bündig übereinander, 10-pt-Gap, Felder fluchten; Auth-Segmented und Gruppen-Picker ohne Doppel-Label.
  - Buttons: „Verbinden" gefüllt blau r7; Sekundär-Buttons mit Hairline-Rand auf Card; Edit-Modus (Kontextmenü „Bearbeiten…"): Zurück/Speichern sekundär, „Speichern & verbinden" primär; gedrückt-Zustand sichtbar.
  - Validierung: leer verbinden → Alert + roter Zeilen-Rahmen (Optik wie zuvor).
  - **Tab-Kette:** Klick ins Host-Feld → Tab → Tab → Tab tippt der Reihe nach Host→Port→Benutzer→Passwort (Regression des Form-Wegfalls!).
  - TOFU-Prompt: Pin für 127.0.0.1 aus `known_hosts.json` entfernen → verbinden → Prompt mit neuen Buttons → „Vertrauen & verbinden" verbindet.
  - Toggle „Als Session speichern" fluchtet auf der Feldspalte; Aktivieren blendet Session-Name+Gruppe ein.
- [ ] Checkboxen im Plan abhaken, Commit `docs: mark M5k plan tasks as completed` (+ Footer).

## Ausblick

Design-Polish-Serie komplett. Danach M6 — Release: App-Icon (Variante A), DMG (lproj-Marker + beide SPM-Bundles!), Notarisierungs-Entscheidung, README/Docs (EN, ohne Stack-Begriffe), Polish-Backlog aus dem Ledger.
