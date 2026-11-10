import macSCPCore

/// The sentence under the "send credentials unencrypted?" question. The kind
/// comes from `PlaintextTransportGate.kind(for:)`, which is where the choice
/// is made; this type only turns it into a catalog key and its text, so a
/// plain FTP session is pointed at FTPS and a web endpoint at the encrypted
/// scheme.
enum PlaintextConfirmationBody {
    /// The catalog key of the sentence for this kind.
    static func key(for kind: PlaintextTransportGate.Kind) -> String {
        switch kind {
        case .http: "transport.plaintext.body"
        case .plainFTP: "transport.plaintext.body.ftp"
        }
    }

    /// The localized sentence for this kind.
    static func text(for kind: PlaintextTransportGate.Kind) -> String {
        switch kind {
        case .http:
            L10n.string(
                "transport.plaintext.body",
                "This connection uses http://, so the password travels in the clear. "
                    + "Use https:// where the server offers it.")
        case .plainFTP:
            L10n.string(
                "transport.plaintext.body.ftp",
                "This connection uses plain FTP, so the password travels in the clear. "
                    + "Use FTPS where the server offers it.")
        }
    }
}
