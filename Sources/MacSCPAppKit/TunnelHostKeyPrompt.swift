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
/// **A QUEUE, not a single continuation** (fix round 1). "Start all" dials
/// every forwarding of a session at once, so two unknown-key questions can
/// arrive within milliseconds of each other. A single slot answered the
/// first one `false` to make room for the second — the user saw one prompt
/// and one profile came to rest in `.needsConfirmation` for no reason they
/// could see. Questions now wait their turn: the head is the one on screen,
/// each answer resumes exactly its own asker, and the next question takes
/// the screen.
///
/// **The bridge can be closed.** A window's decider outlives its window: the
/// runner keeps it across every reconnect, so a question raised hours later
/// would park a dial on a continuation nobody can answer, and
/// `TunnelRunner.stop()` — which waits for that run task — would then hold
/// the quit. `invalidate()`, called when the window disappears, refuses
/// everything queued and everything later, at once.
@MainActor
@Observable
final class TunnelHostKeyPromptBridge {
    /// One waiting question: the candidate on screen (or behind the one on
    /// screen) and the asker to resume.
    private struct Question {
        let id: UUID
        let candidate: HostKeyCandidate
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The question at the head of the queue — what the sheet draws. `nil`
    /// while none is pending.
    ///
    /// **Stored, not computed** (fix round 2). It was a computed property
    /// over `queue` for one round, and `queue` is `@ObservationIgnored`:
    /// under `@Observable` a computed property over ignored storage
    /// registers no dependency at all, so neither presenter was invalidated
    /// when a question arrived. The sheet never appeared and the dial parked
    /// on a continuation nobody could answer — exactly the failure the
    /// one-sheet fix had just removed, arriving by a different route.
    /// `CertificatePromptBridge.currentCandidate` is stored for the same
    /// reason, and `theBridgeNotifiesItsObserverWhenAQuestionArrives` is the
    /// measurement.
    private(set) var currentCandidate: HostKeyCandidate?

    /// How many questions are waiting, the head included. Observable so a
    /// test can state "the second one is still queued" without reading a
    /// private field.
    private(set) var pendingCount = 0

    /// Set by `invalidate()`, cleared by `revalidate()`. Every `ask` in
    /// between answers `false` without queueing anything.
    private(set) var isInvalidated = false

    /// The queue itself is ignored by observation — a `Question` holds a
    /// continuation, and nothing outside this type reads it. What the views
    /// observe are the three published properties above, all written HERE,
    /// in one place, so they cannot drift from the queue they describe.
    @ObservationIgnored private var queue: [Question] = [] {
        didSet {
            pendingCount = queue.count
            currentCandidate = queue.first?.candidate
        }
    }

    init() {}

    /// Decider side: awaited by the `HostKeyDecider` this window hands to
    /// `TunnelManager.start(_:decider:)`.
    ///
    /// Cancellation-safe — a cancelled start resolves `false` rather than
    /// hanging, and leaves the OTHER queued questions alone.
    func ask(_ candidate: HostKeyCandidate) async -> Bool {
        guard !isInvalidated else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isInvalidated {
                    continuation.resume(returning: false)
                    return
                }
                queue.append(Question(id: id, candidate: candidate, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answer(id: id, trust: false)
            }
        }
    }

    /// Called by the UI once the user answers Trust/Cancel — always about
    /// the question on screen, which is the head of the queue.
    func resolve(trust: Bool) {
        guard let head = queue.first else { return }
        answer(id: head.id, trust: trust)
    }

    /// Refuses everything pending and everything to come. Called when the
    /// window that owns this bridge disappears: from that moment no sheet is
    /// watching, so a question would be one nobody could ever answer.
    func invalidate() {
        isInvalidated = true
        let pending = queue
        queue = []
        for question in pending { question.continuation.resume(returning: false) }
    }

    /// Opens the bridge again — called from the window's `onAppear`, the
    /// symmetric half of the `onDisappear` that closes it.
    ///
    /// **Without it, `invalidate()` was permanent** (fix round 2). SwiftUI
    /// sends a view `onDisappear`/`onAppear` for reasons that are not the
    /// window closing, and this window's own `updateModel` half is re-armed
    /// in `onAppear` for exactly that reason. A bridge that was closed once
    /// and never reopened answered every later question `false`, so a
    /// forwarding the user started by hand came to rest in
    /// `.needsConfirmation` with no prompt ever shown.
    func revalidate() {
        isInvalidated = false
    }

    /// Resumes one specific asker, wherever in the queue it sits. Identity
    /// matters: a cancelled dial three questions back must not consume the
    /// answer the user gave to the one on screen.
    private func answer(id: UUID, trust: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let question = queue.remove(at: index)
        question.continuation.resume(returning: trust)
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
