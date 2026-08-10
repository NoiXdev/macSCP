import Foundation
import macSCPCore

/// Maps a `SessionListViewModel.prepareForSubmit(form:)` refusal to the
/// localized message it produced before M29-P2, when each resolution
/// lived in `ContentView` as its own function (`resolveSelectedLoginSet`,
/// `resolveSelectedJumpLoginSet`, `resolveSelectedJumpSession`) and
/// called `showFailure` directly. The field to highlight now comes from
/// `SubmitRefusal.field` instead — only the message is decided here.
/// Lifted out of `ContentView` (M29-P2/T3) so the mapping is held by
/// tests rather than by reading.
///
/// `.jumpSessionLoginUnresolvable` reuses the `loginSets.missingSet` key:
/// it is the old catch-all that covered a dangling login set on the
/// REFERENCED session, or any other unclassified resolution failure.
enum SubmitRefusalText {
    static func message(for refusal: SubmitRefusal) -> String {
        switch refusal {
        case .targetSetMissing, .jumpSetMissing, .jumpSessionLoginUnresolvable:
            return L10n.string(
                "loginSets.missingSet",
                "The stored login for this connection was not found. Choose a login or enter credentials.")
        case .targetSetKindMismatch:
            return L10n.string(
                "form.loginSet.kindMismatch",
                "The selected stored login belongs to a different kind of connection. "
                    + "Choose a login for this connection's protocol, or enter the credentials here.")
        case .jumpSetNotSSH:
            return L10n.string(
                "form.jump.set.notSSH",
                "The jump host uses a stored login that is not an SSH login. "
                    + "Choose an SSH login for the jump host, or enter its "
                    + "user name and password here.")
        case .jumpSessionMissing:
            return L10n.string(
                "form.jump.session.missing", "The connection used as jump host no longer exists.")
        case .jumpChainNotSupported:
            return L10n.string(
                "form.jump.session.chainNotSupported",
                "The selected jump host connects through another jump host; chains are not supported.")
        case .jumpSessionNotSSH:
            return L10n.string(
                "form.jump.session.notSSH",
                "Only SSH connections can be used as a jump host.")
        }
    }
}
