import Foundation

/// Every way the connection form's submit can be refused before a connect
/// or save is attempted (M29-P2).
///
/// Cases, not text: the App layer maps each to a localized message, the same
/// split `LoginResolveError` uses. The field each case highlights belongs
/// here rather than at the call site — it used to live scattered across four
/// catch branches in the view, where nothing could check it.
public enum SubmitRefusal: Equatable, Sendable {
    /// The selected target login set no longer exists.
    case targetSetMissing
    /// The selected target login set belongs to another protocol.
    case targetSetKindMismatch
    /// The selected jump login set no longer exists.
    case jumpSetMissing
    /// The selected jump login set is not an SSH login. Refused BEFORE the
    /// set's keychain slot is read — see the resolution's own doc comment.
    case jumpSetNotSSH
    /// The connection used as jump host no longer exists.
    case jumpSessionMissing
    /// The referenced jump connection itself connects through a jump host.
    case jumpChainNotSupported
    /// The referenced jump connection is not an SSH connection.
    case jumpSessionNotSSH
    /// The referenced jump connection's own login could not be resolved —
    /// a dangling login set on it, or any other resolution failure. Named
    /// rather than left as an unlabelled catch-all so a test can reach it.
    case jumpSessionLoginUnresolvable

    /// The form control to highlight, or `nil` when no single control
    /// corresponds — the target cases refuse a picker whose failure has no
    /// matching field row.
    public var field: ConnectionViewModel.Field? {
        switch self {
        case .targetSetMissing, .targetSetKindMismatch:
            return nil
        case .jumpSetMissing, .jumpSetNotSSH:
            return .jumpHost
        case .jumpSessionMissing, .jumpChainNotSupported,
            .jumpSessionNotSSH, .jumpSessionLoginUnresolvable:
            return .jumpSession
        }
    }
}
