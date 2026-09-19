import SwiftUI
import macSCPCore

/// "Resolve…" beside the SSH host field, and the menu of addresses it
/// offers once the name is resolved. What happens is `HostResolveModel`'s,
/// tested there; this view only draws the model's state for the text the
/// field holds right now and hands the clicks back.
///
/// The line under the field — the consequences note under an offer, or the
/// message when there is no address — is not drawn here but by the form's
/// `fieldFootnote`, from the same model, because a row's footnote sits under
/// the whole row and this view sits beside the field inside it.
///
/// A view of its own rather than a stretch of `ConnectionFormView`, for the
/// reason `SessionEditorGroupPicker` is one: it keeps the form's `body` the
/// shape `ConnectionFormScrollGuardTests` reads it as — no
/// `Button(L10n.string(…))` inside its `ScrollView`.
struct HostResolveControl: View {
    let model: HostResolveModel
    let form: ConnectionViewModel

    var body: some View {
        let host = form.host
        Group {
            switch model.presentation(forHost: host) {
            case .resolving:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        L10n.string("connection.host.resolve.resolving", "Resolving…"))
            case .found(_, let addresses):
                Menu(L10n.string("connection.host.resolve.choose", "Use address")) {
                    ForEach(addresses, id: \.self) { address in
                        // An address is a value, identical in every locale,
                        // so it is shown verbatim rather than looked up.
                        Button {
                            model.choose(address, in: form)
                        } label: {
                            Text(verbatim: address)
                        }
                    }
                }
                .fixedSize()
            case .idle, .noAddress, .noAnswer:
                Button(L10n.string("connection.host.resolve", "Resolve…")) {
                    model.resolve(host)
                }
                .fixedSize()
                .disabled(!HostAddressLookup.isResolvable(host))
                .help(L10n.string(
                    "connection.host.resolve.help",
                    "Looks this name up and offers its addresses to use instead"))
            }
        }
        // A lookup nobody can see the answer to is stopped: the form went
        // away, or switched to a kind that does not offer the action.
        .onDisappear { model.cancel() }
    }
}
