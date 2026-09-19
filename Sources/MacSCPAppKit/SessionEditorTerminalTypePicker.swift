import SwiftUI
import macSCPCore

/// The session editor's terminal-type override (plan of 2026-09-19,
/// Task 4): "Use the global setting" — naming what that is right now — or
/// one of `TerminalType.allCases`.
///
/// A view of its own for the reason `SessionEditorGroupPicker` is one: it
/// keeps `ConnectionFormView.body` the shape the form's guards read it as,
/// and puts the one list the picker offers in one place.
struct SessionEditorTerminalTypePicker: View {
    @Bindable var viewModel: ConnectionViewModel
    /// The global setting, named in the "use it" row so the choice says
    /// what it means.
    let globalType: TerminalType
    /// The picker's accessibility label; the form row draws the visible one.
    let label: String

    var body: some View {
        Picker(label, selection: $viewModel.terminalTypeOverride) {
            Text(String(
                format: L10n.string(
                    "connection.field.terminalType.useGlobal %@", "Use the global setting (%@)"),
                globalType.rawValue))
                .tag(TerminalType?.none)
            ForEach(TerminalType.allCases, id: \.self) { type in
                Text(TerminalTypeLabel.text(for: type)).tag(TerminalType?.some(type))
            }
        }
        .labelsHidden()
        .help(L10n.string(
            "connection.field.terminalType.help",
            "The name the server is told for this session's terminal (TERM). The terminal itself does not change."))
    }
}
