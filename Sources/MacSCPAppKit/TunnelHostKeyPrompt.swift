import SwiftUI
import macSCPCore

/// Holds the continuation behind ONE window's host-key decider for tunnels
/// (port-forwarding plan, Task 6) — the tunnel twin of
/// `CertificatePromptBridge`, and built the same way for the same reason.
///
/// **Why a tunnel needs its own.** A tab's unknown-key question is answered
/// by `ConnectionViewModel.hostKeyPrompt`, drawn where the connection form
/// would be. A tunnel has no tab: it dials its own connection, from the
/// stored session, with no pane of its own to draw a question in. So the
/// window that started it holds this bridge, and hands
/// `HostKeyDecider.asking { await bridge.ask($0) }` to `TunnelManager`.
///
/// **A MISMATCH never arrives here.** TOFU's hard stop is decided inside the
/// dial (`HostKeyValidation`), before any decider is consulted; what reaches
/// this bridge is an UNKNOWN key and nothing else. Autostart reaches it
/// never at all — that path hands in `.refusing`, which asks nobody.
///
/// Single-continuation, like the certificate bridge: a second question
/// arriving while one is open resolves the first as refused rather than
/// silently replacing it, so no dial is left waiting on a continuation
/// nothing will resume.
@MainActor
@Observable
final class TunnelHostKeyPromptBridge {
    /// The open question — drives the presenter. `nil` while none is
    /// pending.
    private(set) var currentCandidate: HostKeyCandidate?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    init() {}

    /// Decider side: awaited by the `HostKeyDecider` this window hands to
    /// `TunnelManager.start(_:decider:)`. Cancellation-safe — a cancelled
    /// start resolves `false` (refuse) rather than hanging.
    func ask(_ candidate: HostKeyCandidate) async -> Bool {
        resolve(trust: false)
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

    /// Called by the UI once the user answers Trust/Cancel — and by `ask`
    /// itself, to close a question that is being replaced.
    func resolve(trust: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        currentCandidate = nil
        continuation.resume(returning: trust)
    }
}

/// The unknown-host-key question for a forwarding, as a sheet.
///
/// The same three facts `ConnectionFormView.hostKeyPromptView` shows for a
/// tab's connect — host, key type, fingerprint — and the same two answers,
/// reading the same catalogue keys, because it is the same question. What
/// differs is only where it is drawn: a tunnel has no pane of its own, so
/// this arrives as a sheet on the window whose menu started it.
///
/// Cancel carries the default action: a forwarding is often started without
/// anyone watching the server it dials, and Return must not accept a key
/// nobody read.
struct TunnelHostKeyPromptView: View {
    let candidate: HostKeyCandidate
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L10n.string(
                "connection.hostkey.first", "First connection to %@"), candidate.host))
                .font(.title2.bold())
            Text(L10n.string(
                "tunnel.hostkey.subtitle",
                "A forwarding is opening a connection of its own to this server."))
                .font(.callout)
                .foregroundStyle(DesignTokens.inkSecondary)
            Text(String(format: L10n.string(
                "connection.hostkey.fingerprintLabel", "Fingerprint (%@):"), candidate.keyType))
                .font(.callout)
            Text(candidate.fingerprintSHA256)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { onCancel() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.polished)
                Button(L10n.string("connection.hostkey.trust", "Trust & connect")) { onTrust() }
                    .buttonStyle(.polishedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
    }
}
