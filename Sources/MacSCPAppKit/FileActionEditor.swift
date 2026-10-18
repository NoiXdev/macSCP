import SwiftUI
import macSCPCore

/// New/Edit sheet for one file action: its name, its command (in the snippet
/// editor's command field, so the shell syntax is coloured while it is
/// typed), the selection form as a two-way picker, the two panes it runs in as
/// toggles, and its declared variables.
///
/// **The editor's one job beyond data entry is to refuse, legibly.**
/// `FileActionTemplate.firstProblem(in:)` is asked of the action as it stands,
/// on every change, and its answer is shown as a sentence that says what to
/// do; Save stays disabled while there is one. That is what lets the context
/// menu treat a stored action the gate refuses as a hand-edited file and not
/// as something this editor produces. The same gate runs on an import
/// (`FileActionAuthoring.review`), the other way into the store.
///
/// **What is judged is what would be saved.** The command is normalised by
/// `FileActionAuthoring.normalizedCommand` before the gate sees it, so a
/// command pasted with a trailing newline is not refused for a line feed the
/// author never typed on purpose, and the preview shows the command that will
/// run.
///
/// The preview is `FileActionPlanner`'s own output, drawn by
/// `FileActionPlanDisplay` as the confirmation sheet draws it, for each pane
/// the action runs in. Nothing is run, and the sample files stand for nothing
/// the server said.
///
/// Two kinds of test. What it renders is tested as data:
/// `fileActionProblemText`, `FileActionAuthoring`, and the wiring guard. What
/// it needs in width is measured by hosting it: `BoundedViewLayoutGuardTests`
/// does that per catalogue, for this view and for every other that bounds
/// its own size. It was `FileActionEditorLayoutGuardTests`, which measured
/// this one alone, until that suite was replaced by the registry. This comment used to say "View code, with no test
/// that draws it (this project has no SwiftUI rendering harness)"; the harness
/// is `ViewTestabilitySpike`'s, and the width of this sheet is now measured
/// with it.
struct FileActionEditor: BoundedView {
    let existing: FileAction?
    let store: FileActionStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var perSelection: FileActionPerSelection
    @State private var runsOnRemote: Bool
    @State private var runsOnLocal: Bool
    @State private var variableDrafts: [VariableDraft]
    @State private var commandEditorController = SnippetCommandEditorController()
    @State private var errorMessage: String?

    /// The id the draft is saved under: `existing`'s, or one made once when
    /// this editor opened, so every read of `draftAction` is the same action.
    /// `@State`, because a `View` struct is re-created whenever the presenting
    /// body is re-evaluated, and a plain `let` would mint a new identity then
    /// while the other fields kept their state.
    @State private var draftID: UUID

    init(existing: FileAction?, store: FileActionStore, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.store = store
        self.onSaved = onSaved
        _draftID = State(initialValue: existing?.id ?? UUID())
        _name = State(initialValue: existing?.name ?? "")
        _command = State(initialValue: existing?.command ?? "")
        _perSelection = State(initialValue: existing?.perSelection ?? .oncePerFile)
        let sides = existing?.runsOn ?? [.remote]
        _runsOnRemote = State(initialValue: sides.contains(.remote))
        _runsOnLocal = State(initialValue: sides.contains(.local))
        _variableDrafts = State(
            initialValue: (existing?.variables ?? []).map(VariableDraft.init(variable:)))
    }

    private var isEditing: Bool { existing != nil }

    private var variables: [SnippetVariable] { variableDrafts.map(\.variable) }

    private var runsOn: Set<BrowserPaneSide> {
        Set(BrowserPaneSide.allCases.filter { side in
            switch side {
            case .local: return runsOnLocal
            case .remote: return runsOnRemote
            }
        })
    }

    /// The action as the fields currently stand: what Save would write and
    /// what the gate and the preview judge. One construction for all three.
    private var draftAction: FileAction {
        FileAction(
            id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            command: FileActionAuthoring.normalizedCommand(command),
            variables: variables, runsOn: runsOn, perSelection: perSelection)
    }

    /// The gate's answer for the draft, or `nil`.
    private var problem: FileActionTemplate.Problem? {
        FileActionTemplate.firstProblem(in: draftAction)
    }

    /// Two declarations with one name: a validation error to report, not a
    /// reason to trap, so it blocks Save with its own sentence.
    private var hasDuplicateVariableName: Bool {
        Set(variables.map(\.name)).count != variables.count
    }

    private var isSaveDisabled: Bool {
        draftAction.name.isEmpty || draftAction.command.isEmpty
            || problem != nil || hasDuplicateVariableName
    }

    var body: some View {
        sheetContent
            .sheetBound(Self.bound)
    }

    /// The width the sheet grants its content, in points: `bound.grantedWidth`.
    ///
    /// Fixed, and that is a limit rather than a feature: a fixed frame does
    /// not refuse content that needs more, it lets it overflow and centres
    /// it, clipping both edges. A flexible frame does not help, measured
    /// 2026-10-16 on this content with the German and the Polish catalogue:
    /// `.frame(minWidth:idealWidth:)`, `.frame(idealWidth:)` and a `ZStack`
    /// floor each either reported the frame's own width while the content
    /// (which, asked at 380 pt, answered 411 pt) overflowed it, or opened the
    /// sheet at its widest unwrapped text (843 pt in German). So the width is not
    /// something the layout can negotiate, and what keeps content inside it
    /// is `BoundedViewLayoutGuardTests`, which measures the content per
    /// catalogue against this number — through
    /// `SheetBound.isSuspendedForMeasurement`, because a view that applies
    /// its own bound otherwise reports that bound and nothing else.
    ///
    /// The number was 520 against English alone. The "Runs" choice was a
    /// segmented picker, whose labels sit side by side and cannot wrap; in
    /// Polish that alone needed more than 520. It is a radio group now, which
    /// stacks, so what is widest is one label, not two.
    ///
    /// Every localized control that cannot wrap is `.fixedSize()` — the radio
    /// group, the two checkboxes, the kind picker and the placement menu — so
    /// what the content reports as its minimum width is what it needs. A
    /// compressible control would report a smaller minimum and be squeezed
    /// (its labels cut) without anything overflowing, which no width
    /// measurement can see.
    static let bound: SheetBound = .width(520)

    /// Everything the sheet draws, before any width is imposed on it.
    var sheetContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing
                ? L10n.string("fileAction.editor.titleEdit", "Edit File Action")
                : L10n.string("fileAction.editor.titleNew", "New File Action"))
                .font(.title3.bold())

            let nameLabel = L10n.string("snippets.variables.name", "Name")
            FormRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }

            let commandLabel = L10n.string("snippets.editor.command", "Command")
            FormRow(label: commandLabel) {
                SnippetCommandEditor(
                    text: $command, controller: commandEditorController,
                    accessibilityLabel: commandLabel, variables: variables)
                    .frame(height: SnippetCommandEditor.intrinsicHeight(for: command))
                    .alignmentGuide(.firstTextBaseline) { _ in
                        SnippetCommandEditor.firstBaselineOffset
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(DesignTokens.hairline, lineWidth: 1))
            }

            FormRow(label: L10n.string("fileAction.editor.insert", "Insert")) {
                insertButtons
            }

            let formLabel = L10n.string("fileAction.editor.form", "Runs")
            FormRow(label: formLabel) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(formLabel, selection: $perSelection) {
                        ForEach(FileActionPerSelection.allCases, id: \.self) { form in
                            Text(fileActionFormLabel(form)).tag(form)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .fixedSize()
                    Text(perSelection == .oncePerFile
                        ? L10n.string(
                            "fileAction.editor.form.perFile.hint",
                            "The command runs once for each selected file.")
                        : L10n.string(
                            "fileAction.editor.form.everyPath.hint",
                            "The command runs once, with every selected path."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            FormRow(label: L10n.string("fileAction.editor.where", "Where")) {
                HStack(spacing: 16) {
                    Toggle(
                        L10n.string("fileAction.editor.side.remote", "Remote pane"),
                        isOn: $runsOnRemote)
                    Toggle(
                        L10n.string("fileAction.editor.side.local", "Local pane"),
                        isOn: $runsOnLocal)
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }

            variablesSection

            if let problem {
                Text(fileActionProblemText(for: problem))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if hasDuplicateVariableName {
                Text(L10n.string(
                    "snippets.variables.error.duplicateName", "Two variables share a name."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if problem == nil, !draftAction.command.isEmpty {
                previewSection
            }

            Text(L10n.string(
                "fileAction.editor.credentialsNote",
                "Don't put credentials in a command: it is stored and exported as plain text, and a command line is visible in ps and in the shell history."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) { save() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .textFieldStyle(.roundedBorder)
    }

    // MARK: - Insert

    /// The names the selection supplies under the current form, as buttons
    /// that put `{{NAME}}` at the command field's caret. Read from
    /// `FileActionTemplate.names(fitting:)`, so the offer is the set the gate
    /// accepts for this form and follows the picker.
    private var insertButtons: some View {
        HStack(spacing: 6) {
            ForEach(FileActionTemplate.names(fitting: perSelection).sorted(), id: \.self) { name in
                Button {
                    insert(name)
                } label: {
                    Text(verbatim: "{{\(name)}}")
                        .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.polished)
            }
            Spacer()
        }
    }

    private func insert(_ name: String) {
        if !commandEditorController.insertPlaceholder(named: name) {
            command = snippetCommandInsertingPlaceholder(name, into: command)
        }
    }

    // MARK: - Variables

    @ViewBuilder
    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("snippets.variables.title", "Variables"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Spacer()
                Button {
                    variableDrafts.append(VariableDraft())
                } label: {
                    Label(
                        L10n.string("snippets.variables.add", "Add variable"),
                        systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help(L10n.string("snippets.variables.add", "Add variable"))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkSecondary)
            }
            ForEach($variableDrafts) { $draft in
                variableRow($draft)
            }
            if !variableDrafts.isEmpty {
                Text(L10n.string(
                    "snippets.variables.hint",
                    "A value is inserted as a single shell word. An environment variable is exported ahead of the command and stays set in the session after the run."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func variableRow(_ draft: Binding<VariableDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    L10n.string("snippets.variables.name", "Name"), text: draft.name,
                    prompt: Text(L10n.string("snippets.variables.name", "Name")))
                Picker("", selection: draft.isSelection) {
                    Text(L10n.string("snippets.variables.kind.freeText", "Free text")).tag(false)
                    Text(L10n.string("snippets.variables.kind.selection", "Choice")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                if snippetBelongsInCommandAsPlaceholder(draft.wrappedValue.variable) {
                    let insertLabel = L10n.string("snippets.variables.insert", "Insert in command")
                    Button {
                        insert(draft.wrappedValue.variable.name)
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(insertLabel)
                    .help(insertLabel)
                }
                Button {
                    variableDrafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
                .help(L10n.string("settings.openWith.rules.remove", "Remove"))
            }
            TextField(
                L10n.string("snippets.variables.prompt", "Prompt"), text: draft.prompt,
                prompt: Text(L10n.string("snippets.variables.prompt", "Prompt")))
            if draft.wrappedValue.isSelection {
                TextField("", text: draft.selectionValuesText, prompt: Text(verbatim: "a, b, c"))
            }
            HStack(spacing: 8) {
                Picker("", selection: draft.placement) {
                    Text(L10n.string(
                        "snippets.variables.placement.placeholder", "Placeholder in the command"))
                        .tag(SnippetVariable.Placement.placeholder)
                    Text(L10n.string(
                        "snippets.variables.placement.environment", "Environment variable"))
                        .tag(SnippetVariable.Placement.environment)
                }
                .labelsHidden()
                .fixedSize()
                TextField(
                    L10n.string("snippets.variables.default", "Default"),
                    text: draft.defaultValue,
                    prompt: Text(L10n.string("snippets.variables.default", "Default")))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }

    // MARK: - Preview

    /// What the confirmation sheet would show, for each pane the action runs
    /// in, on sample files. The planner is asked exactly as the pane asks it;
    /// a declared variable is given a sample value where the pane would
    /// prompt for one.
    @ViewBuilder
    private var previewSection: some View {
        let action = draftAction
        let samples = Dictionary(
            variables.map { ($0.name, fileActionPreviewValue(for: $0)) },
            uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("snippets.editor.preview", "Preview"))
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
            ForEach(BrowserPaneSide.allCases.filter(action.runsOn.contains), id: \.self) { side in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileActionSidesText([side]))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    switch FileActionPlanner.plan(
                        action: action, selection: fileActionPreviewSelection(for: perSelection),
                        side: side, promptedValues: samples)
                    {
                    case .success(let plan):
                        Text(fileActionDestinationText(for: plan))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        let lines = FileActionPlanDisplay.lines(for: plan)
                        ForEach(lines.indices, id: \.self) { index in
                            Text(FileActionPlanDisplay.attributed(lines[index]))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .failure(let refusal):
                        Text(FileActionPlanDisplay.refusalSentence(for: refusal))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }

    // MARK: - Save

    private func save() {
        // The refusal is structural: Save is also disabled while any of these
        // holds, but a write must not rest on one modifier being in place.
        let action = draftAction
        guard problem == nil, !action.name.isEmpty, !action.command.isEmpty,
            !hasDuplicateVariableName
        else { return }
        do {
            try store.save(action)
            onSaved()
            dismiss()
        } catch {
            errorMessage = L10n.string(
                "fileAction.editor.error.save", "Couldn't save the action.")
        }
    }
}
