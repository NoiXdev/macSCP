import SwiftUI
import macSCPCore

/// Holds the continuation for the WebDAV/S3 certificate-trust decider
/// (M21/T10) — the certificate twin of `ConnectionViewModel.hostKeyPrompt`'s
/// own continuation, but living here (App layer) rather than on the view
/// model: the descriptor's `connect` closure takes its `certificateDecider`
/// directly by `ContentView.makeTab`'s connector closure, one level below the
/// `ConnectionViewModel.Connector` seam the host-key decider is threaded
/// through — see that closure's own comment.
///
/// A reference type (not a `@State` field) because it must exist BEFORE the
/// `SessionTab` it is later attached to: the connector closure is built
/// before the tab it will belong to, exactly the ordering constraint
/// `SessionTab.conflictBridge` sidesteps by being constructed inside
/// `SessionTab.init` instead (this bridge is constructed just before, and
/// handed to both the closure and the tab).
///
/// Single-continuation shape (no `promptID` matching like
/// `ConflictPromptBridge`): only one connect attempt is ever in flight per
/// tab, so there is no second question that could arrive while the first is
/// still open.
@MainActor
@Observable
final class CertificatePromptBridge {
    /// The open prompt — drives the presenter. `nil` while no certificate
    /// question is pending.
    private(set) var currentCandidate: ServerCertificateCandidate?
    private var continuation: CheckedContinuation<Bool, Never>?

    init() {}

    /// Decider side: awaited by the `certificateDecider` closure handed to
    /// the descriptor's `connect`. Cancellation-safe — if the connecting task
    /// is cancelled while the prompt is open, it resolves `false` (refuse)
    /// instead of hanging.
    func ask(_ candidate: ServerCertificateCandidate) async -> Bool {
        currentCandidate = candidate
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    currentCandidate = nil
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(trust: false)
            }
        }
    }

    /// Called by the UI once the user answers Trust/Cancel.
    func resolve(trust: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        currentCandidate = nil
        continuation.resume(returning: trust)
    }
}

/// Full-pane trust decision for an unknown WebDAV/S3 server certificate
/// (M21/T10). Same shape as `ConnectionFormView.hostKeyPromptView` for the
/// same kind of question: shows the presented certificate's identifying
/// details and asks Trust/Cancel — but Cancel, not Trust, carries the
/// default action here (spec: an unknown TLS certificate is a more common,
/// less inherently suspicious event on a home NAS than an unknown SSH host
/// key, so Return must not silently accept it).
///
/// A mismatch NEVER reaches this view — `WebDAVSessionDelegate
/// .decideCertificate` refuses it before ever consulting the decider this
/// prompt answers; see `ContentView`'s certificate-mismatch handling.
struct CertificatePromptView: View {
    let candidate: ServerCertificateCandidate
    let onTrust: () -> Void
    let onCancel: () -> Void

    /// `dd.MM.yyyy` (mirrors `KnownHostsSheet.dateFormatter`) — pinned to
    /// `en_US_POSIX` so the expiry date renders identically regardless of the
    /// user's locale.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private var expiryText: String {
        guard let notAfter = candidate.notAfter else { return "\u{2014}" }
        return Self.dateFormatter.string(from: notAfter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("certificate.prompt.title", "Trust this server's certificate?"))
                .font(.title2.bold())
            Text("\(candidate.host):\(String(candidate.port))")
                .font(.callout)
                .foregroundStyle(DesignTokens.inkSecondary)
            Text(candidate.subject)
                .font(.callout)
                .textSelection(.enabled)

            detailRow(L10n.string("certificate.prompt.expires", "Expires"), expiryText)

            Text(L10n.string("certificate.prompt.fingerprint", "Fingerprint"))
                .font(.callout)
            Text(candidate.fingerprintSHA256)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button(L10n.string("certificate.prompt.trust", "Trust")) {
                    onTrust()
                }
                .buttonStyle(.polished)
                Button(L10n.string("common.cancel", "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.polishedProminent)
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .font(.callout)
                .foregroundStyle(DesignTokens.inkTertiary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}
