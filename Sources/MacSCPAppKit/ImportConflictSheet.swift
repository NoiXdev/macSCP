import SwiftUI
import macSCPCore

/// The continuation bridge both import flows present this sheet through
/// (`ImportConflictBridge`, with `ImportConflictPromptItem`) lives in Core,
/// next to the arbiter it feeds — it is pure state machine, and the app
/// target has no tests to hold its resumption rules honest. See
/// `Sources/macSCPCore/Presentation/ImportConflictBridge.swift`; the
/// presentation contract both presenters must honour is
/// `importConflictSheet(bridge:)` at the bottom of this file.

/// Shared conflict-resolution sheet (M19/T7) for BOTH import flows — session
/// imports and login-set imports each route their naming collisions through
/// the same `ImportConflictArbiter`/`ImportConflict` (Core, M19/T3), so this
/// is the ONE sheet both present, instead of two near-identical inventions.
///
/// Shape mirrors the M5b transfer conflict sheet (`ConflictSheetView` in
/// `ContentView.swift`) on purpose, so imports read as a sibling of
/// transfers: same padding/spacing/frame, the same "apply to all" toggle,
/// the same button order (Cancel first with `role: .cancel`, then the
/// non-destructive actions, then the destructive one last carrying
/// `.keyboardShortcut(.defaultAction)`), and the same
/// `.interactiveDismissDisabled(true)` contract — Escape/click-outside must
/// never resolve the prompt on their own; only the buttons call `onResolve`/
/// `onCancel`. Whatever wires this sheet in (M19/T8, a continuation-based
/// bridge like `ConflictPromptBridge`) depends on that contract to avoid
/// ever leaving its continuation unfulfilled.
///
/// Two deliberate differences from the transfer sheet, both real
/// consequences of what an import conflict actually is:
/// - `kindLabel` arrives from Core as a stable identifier
///   (`LoginSetImportPlanner.kindLabel` / `SessionImportPlanner.kindLabel`),
///   not display text — Core has no UI language. `kindText` below maps it to
///   localized text, falling back to a neutral generic noun (never the raw
///   identifier) for any value neither planner currently sets.
/// - `Replace` here also destroys secret material (the stored password or
///   key passphrase for whatever it overwrites), which a mere file overwrite
///   never does — the sheet says so explicitly via `replaceNote` rather than
///   leaving it implicit the way the transfer sheet's plain "Overwrite" can.
///
/// Both import flows present it through `ImportConflictBridge` above:
/// `ContentView` for sessions, `LoginSetsSheet` for logins.
///
/// `private` (M19/T8 review, leftover 3): the implementer's own worry when
/// this was still `internal` was that a third import flow could hand-roll
/// its own `.sheet` around this type and reintroduce the Critical dismissal
/// bug the bridge exists to prevent. Marking it `private` closes that
/// structurally rather than by convention — the ONLY way to present this
/// view from outside this file is `importConflictSheet(bridge:)` below,
/// which is where the presentation contract that keeps the bridge honest
/// actually lives.
private struct ImportConflictSheet: View {
    let conflict: ImportConflict
    let onResolve: (ImportConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.headline)
            Text(messageText)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(L10n.string("info.kind", "Kind"))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text(kindText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(L10n.string(
                "import.conflict.replaceNote",
                "Replacing also overwrites the stored password or key passphrase."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                L10n.string("import.conflict.applyToAll", "Apply to all remaining conflicts"),
                isOn: $applyToAll)
            Text(L10n.string("import.conflict.cancelNote", "Cancelling imports nothing."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("import.conflict.cancel", "Cancel Import"), role: .cancel) {
                    onCancel()
                }
                Button(L10n.string("import.conflict.rename", "Rename")) {
                    onResolve(.rename, applyToAll)
                }
                Button(L10n.string("import.conflict.skip", "Skip")) {
                    onResolve(.skip, applyToAll)
                }
                Button(L10n.string("import.conflict.replace", "Replace"), role: .destructive) {
                    onResolve(.replace, applyToAll)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/click-outside must NOT resolve the prompt without fulfilling
        // whatever continuation the wiring task (T8) hangs off `onCancel` —
        // same reasoning `ConflictSheetView` documents for the M5b transfer
        // sheet. Resolution happens exclusively through the buttons above.
        .interactiveDismissDisabled(true)
    }

    /// `ImportConflict.reason` says which collision actually happened
    /// (M23/P3 T3): a login set collides on its NAME, a session on its
    /// CONNECTION, and those are different keys with different keys' worth
    /// of copy — reusing `import.conflict.title`/`.message` for both would
    /// reintroduce the exact defect this type exists to prevent (a session
    /// conflict claiming a NAME is taken when what collided is the
    /// endpoint).
    private var titleText: String {
        switch conflict.reason {
        case .name:
            return L10n.string("import.conflict.title", "Name Already Exists")
        case .sameConnection:
            return L10n.string("import.conflict.connection.title", "Connection Already Exists")
        }
    }

    /// See `titleText` above. The `.sameConnection` message names the STORED
    /// (or earlier-in-file) connection's own display summary, never the
    /// incoming item's name — that is the whole point of the case.
    private var messageText: String {
        switch conflict.reason {
        case .name:
            return String(format: L10n.string(
                "import.conflict.message", "“%@” already exists."), conflict.itemName)
        case .sameConnection(let existing):
            return String(format: L10n.string(
                "import.conflict.connection.message",
                "“%@” points at the same server as “%@”."), conflict.itemName, existing)
        }
    }

    /// Maps Core's stable `kindLabel` identifier to localized display text.
    /// `LoginSetImportPlanner.kindLabel` ("loginSet"),
    /// `SessionImportPlanner.kindLabel` ("session") and
    /// `SnippetImportPlanner.kindLabel` ("snippet", P3b/T4) are the only
    /// values any import flow currently sets; anything else — a hypothetical
    /// future planner, or a value that drifted — falls back to a neutral
    /// generic noun instead of surfacing the raw identifier to the user.
    private var kindText: String {
        switch conflict.kindLabel {
        case LoginSetImportPlanner.kindLabel:
            return L10n.string("import.conflict.kind.loginSet", "login set")
        case SessionImportPlanner.kindLabel:
            return L10n.string("import.conflict.kind.session", "session")
        case SnippetImportPlanner.kindLabel:
            return L10n.string("import.conflict.kind.snippet", "snippet")
        default:
            return L10n.string("import.conflict.kind.other", "item")
        }
    }
}

extension View {
    /// The ONE way either import flow presents `ImportConflictSheet` —
    /// `ContentView` (sessions) and `LoginSetsSheet` (logins) both call this
    /// and nothing else, so the presentation contract below cannot drift
    /// apart between them or be reinvented by a third flow.
    ///
    /// Three deliberate choices, each of which the bridge's exactly-once
    /// argument depends on:
    ///
    /// 1. **The binding's setter is inert.** SwiftUI writes `nil` to it when
    ///    it decides the sheet should go away — but that write says nothing
    ///    about WHICH prompt it refers to, and by the time it lands the
    ///    (I/O-free) planner may already be asking the next question.
    ///    Answering "whatever is current" there cancelled imports the user had
    ///    just answered. The getter alone is what drives presentation, and
    ///    `resolve` clearing `currentPrompt` is what dismisses the sheet.
    /// 2. **The safety net names its prompt.** `onDisappear` fires on the
    ///    content view being torn down, which is the only hook that still has
    ///    `item` — so the net can say "the sheet for THIS prompt went away"
    ///    and `dismiss(promptID:)` can ignore it unless that prompt is still
    ///    the open, unanswered one. There is no `onDismiss:` here for exactly
    ///    that reason: it carries no item.
    /// 3. **Every button routes into the bridge NAMING ITS OWN PROMPT**, and
    ///    the sheet itself is `.interactiveDismissDisabled(true)`, so
    ///    Escape/click-outside cannot strand a continuation for the net to
    ///    have to catch. The buttons pass `item.id` for the same reason the
    ///    net does: a tap delivered twice (double click, or a repeated press
    ///    of `Replace`'s `.defaultAction` shortcut) while this sheet animates
    ///    out would otherwise answer the NEXT question — the planner has no
    ///    I/O between two conflicts and has already asked it.
    func importConflictSheet(bridge: ImportConflictBridge) -> some View {
        sheet(item: Binding(
            get: { bridge.currentPrompt },
            set: { _ in /* see 1. above — deliberately inert */ })
        ) { item in
            ImportConflictSheet(
                conflict: item.conflict,
                onResolve: { resolution, applyToAll in
                    bridge.resolve(
                        promptID: item.id, (resolution: resolution, applyToAll: applyToAll))
                },
                onCancel: { bridge.dismiss(promptID: item.id) }
            )
            .onDisappear { bridge.dismiss(promptID: item.id) }
        }
    }
}
