# M5k — Design polish form & buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The connection form adopts the mockup field grid (110pt labels) and the mockup button style (r7, primary filled in remote blue) — pure view layer, zero behavior change; this completes the design-polish series.

**Architecture:** New file `PolishedButtonStyle` (ButtonStyle, two variants via a `prominent` flag, convenience `.polished`/`.polishedProminent`); in `ConnectionFormView` a private `FormRow` helper view replaces the SwiftUI `Form` (system text fields stay → tab chain/focus native), `errorHighlight` moves onto the rows, all form buttons switch to the new style. System chrome (toolbar, alerts, sheets, settings) stays untouched.

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, SwiftUI, macOS 15+. No new unit tests (view layer); the existing 295 stay green.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-25-m5k-form-polish-design.md` — binding, including the value table (label 110pt right-aligned 12.5pt `inkSecondary`, gap 10, row spacing 10; button r7, 5×14, 12.5pt; secondary `card`+`hairline`+`inkSecondary`; primary `remoteBlue`+white semibold, pressed opacity 0.85).
- NO behavior change: validation/alert flow, edit-mode semantics (empty password = "unchanged"), TOFU flow, fileImporter, `keyboardShortcut(.defaultAction)` assignments, `disabled` logic, tab order Host→Port→Username→Password. TextField label parameters STAY (accessibility labels), even though the visible label will now come from `FormRow`.
- Both appearances via existing tokens; white on `remoteBlue` is deliberately static (mockup `#fff` on brand blue).
- NOT converted: toolbar, alerts, sheets, settings, sidebar (system chrome, M5f line).
- Code + comments English ONLY; Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` and the full `swift test` (295) green after every task.
- Environment note: bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and retry identically.

## Schedule

T1 → T2 → T3 sequential.

---

### Task 1: PolishedButtonStyle

**Files:**
- Create: `Sources/MacSCPApp/PolishedButtonStyle.swift`

**Interfaces:**
- Consumes: `DesignTokens.remoteBlue`, `.card`, `.hairline`, `.inkSecondary` (all existing).
- Produces: `PolishedButtonStyle: ButtonStyle` with `let prominent: Bool`; `ButtonStyle` extension with `static var polished` / `static var polishedProminent`.

- [x] **Step 1: Create the file** — full content:

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

- [x] **Step 2: Build + suite** — `swift build` error-free, `swift test` 295/295 (no consumers yet).
- [x] **Step 3: Commit** — `feat: add the mockup polished button style`.

---

### Task 2: Form grid + button application

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (currently 241 lines; `formContent`, the button rows in `formContent` and `hostKeyPromptView`, plus new private `FormRow` — structure/callbacks/alert/fileImporter/`errorHighlight` extension stay)

**Interfaces:**
- Consumes: T1 (`.polished`/`.polishedProminent`), `DesignTokens.inkSecondary`.
- Produces: private `FormRow<Content: View>` in the same file.

- [x] **Step 1: Insert `FormRow`** — before the `errorHighlight` extension:

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

- [x] **Step 2: Replace `formContent`** — the `Form { … } .disabled(isConnecting)` (lines 79–152) becomes:

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

  Notes: `Passphrase (optional)` is long as a 110pt label — `Text` wraps to two lines when needed, which is accepted (the mockup column is fixed). `Button("…")` already gets `.polished` here.

- [x] **Step 3: Convert the buttons** — in `formContent`'s button HStack: "Back" and "Save" get `.buttonStyle(.polished)`, "Save & Connect" replaces `.buttonStyle(.borderedProminent)` with `.buttonStyle(.polishedProminent)`, likewise "Connect"; in `hostKeyPromptView`: "Back" `.buttonStyle(.polished)`, "Trust & Connect" `.buttonStyle(.polishedProminent)`. `keyboardShortcut`/`disabled` unchanged, in place.

- [x] **Step 4: Build + full suite** — `swift build` error-free, `swift test` 295/295.
- [x] **Step 5: Commit** — `feat: adopt the mockup form grid and button style in the connection form`.

---

### Task 3: Closing verification (coordinator)

- [x] `swift test` overall; bring the rig up (`docker compose -f docker/test-server/compose.yml start`) and `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` fully green.
- [x] **Visual smoke test in LIGHT and DARK** (light app-only via `NSRequiresAquaSystemAppearance` in the wrapper, then REMOVE it):
  - Grid: 110pt labels right-aligned flush above one another, 10pt gap, fields line up; auth segmented control and group picker without a double label.
  - Buttons: "Connect" filled blue r7; secondary buttons with a hairline border on card; edit mode (context menu "Edit…"): Back/Save secondary, "Save & Connect" primary; pressed state visible.
  - Validation: connect while empty → alert + red row border (look unchanged from before).
  - **Tab chain:** click into the host field → tab → tab → tab types in order Host→Port→Username→Password (regression from the Form's removal!).
  - TOFU prompt: remove the pin for 127.0.0.1 from `known_hosts.json` → connect → prompt with the new buttons → "Trust & Connect" connects.
  - Toggle "Save as session" lines up on the field column; enabling it reveals session name + group.
- [x] Check off the checkboxes in the plan, commit `docs: mark M5k plan tasks as completed` (+ footer).

## Outlook

Design-polish series complete. Next up M6 — Release: app icon (variant A), DMG (lproj marker + both SPM bundles!), notarization decision, README/docs (EN, without stack terms), polish backlog from the ledger.
