import Foundation
import Observation
import macSCPCore

/// The connection form's "Resolve…" beside the host field: it looks the
/// typed name up, offers its addresses, and on a choice replaces the host
/// field's text with one of them (the BACKLOG row "Offer to resolve an
/// entered host name to its IP", 2026-09-19).
///
/// **SSH/SFTP only** (`isOffered(for:)`). S3 and WebDAV reach their endpoint
/// over TLS, whose certificate is checked against the NAME; an address would
/// not match it.
///
/// **The target host only.** The jump host's field is drawn by hand in
/// `ConnectionFormView.sshJumpSection` and gets no such action; the form
/// hands this model to the schema-rendered target host row alone.
///
/// **What choosing does, and what it does not.** It writes the host field —
/// `ConnectionViewModel.host`, which is `values[SSHField.host]` — and nothing
/// else. Known hosts are keyed by host and port, so the next connect asks
/// the user to confirm the server's key again, for the address, through the
/// ordinary first-connection prompt; nothing here copies the name's entry
/// over, which would be a way to trust a key nobody was shown. The name is
/// not kept anywhere. The line under the field says both
/// (`footnote(for:)`).
///
/// **The lookup** is `HostAddressLookup`'s: the diagnostics resolver, off
/// the cooperative pool and under its own deadline, so a slow resolver ends
/// as "no answer in time" instead of a spinner that stays. The form never
/// waits on it — `resolve(_:)` returns at once.
///
/// Owned by the form (`@State` in `ConnectionFormView`), one per form, so
/// two windows resolving two hosts hold two of these.
@MainActor
@Observable
final class HostResolveModel {
    /// Where the lookup stands, each settled state carrying the host text it
    /// was made for.
    enum State: Equatable {
        case idle
        case resolving(host: String)
        /// The addresses to offer, in `HostAddressLookup`'s order.
        case found(host: String, addresses: [String])
        case noAddress(host: String)
        case noAnswer(host: String)

        /// The host text this state was made for; `nil` while idle.
        var host: String? {
            switch self {
            case .idle: nil
            case .resolving(let host), .found(let host, _), .noAddress(let host),
                .noAnswer(let host):
                host
            }
        }
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let lookup: @Sendable (String) async -> HostAddresses
    /// The lookup whose answer may still land. Replaced by the next
    /// `resolve(_:)`, which cancels it first.
    @ObservationIgnored private var current: (id: UUID, task: Task<Void, Never>)?
    /// Every lookup that has not finished yet, the replaced ones included —
    /// what `settle()` waits for. Each removes itself when it ends.
    @ObservationIgnored private var unfinished: [UUID: Task<Void, Never>] = [:]

    init(
        lookup: @escaping @Sendable (String) async -> HostAddresses = {
            await HostAddressLookup.addresses(of: $0)
        }
    ) {
        self.lookup = lookup
    }

    /// Whether a form of this kind offers the action. SSH only — see the
    /// type's own documentation for why S3 and WebDAV do not.
    static func isOffered(for kind: ConnectionKind) -> Bool {
        kind == .ssh
    }

    /// What the control shows while the field holds `host`. A state made for
    /// another text reads as idle: once the field changes, an offer or a
    /// message about the old name is about something no longer there.
    func presentation(forHost host: String) -> State {
        state.host == host ? state : .idle
    }

    /// Starts looking `host` up, replacing — and cancelling — any lookup
    /// still running. Returns at once; the answer lands in `state`.
    func resolve(_ host: String) {
        current?.task.cancel()
        let id = UUID()
        state = .resolving(host: host)
        let lookup = self.lookup
        let task = Task { [weak self] in
            let answer = await lookup(host)
            self?.land(id: id, host: host, answer: answer)
        }
        current = (id, task)
        unfinished[id] = task
    }

    /// Replaces the host field's text with `address`, when it is one the
    /// current offer contains. Writes nothing else.
    func choose(_ address: String, in form: ConnectionViewModel) {
        guard case .found(_, let addresses) = state, addresses.contains(address) else { return }
        form.host = address
        state = .idle
    }

    /// Stops the running lookup, if any, and offers nothing. Called when the
    /// control leaves the screen.
    func cancel() {
        current?.task.cancel()
        current = nil
        state = .idle
    }

    /// Waits until every lookup started so far has ended. For the suite,
    /// which has no other way to know a dropped answer really was dropped.
    func settle() async {
        while let entry = unfinished.first {
            await entry.value.value
        }
    }

    /// The line drawn under the host field for `state`: the consequences
    /// note under an offer, a message for no address or no answer, nothing
    /// otherwise.
    static func footnote(for state: State) -> String? {
        switch state {
        case .idle, .resolving:
            return nil
        case .found:
            return L10n.string(
                "connection.host.resolve.note",
                "Connecting to an address asks you to confirm the server's host key again, and the name is not kept.")
        case .noAddress:
            return L10n.string(
                "connection.host.resolve.noAddress", "No address was found for this name.")
        case .noAnswer:
            return L10n.string(
                "connection.host.resolve.noAnswer", "The name did not resolve in time.")
        }
    }

    /// Lands a lookup's answer — only the current lookup's, and only if it
    /// was not cancelled. A replaced or cancelled lookup's answer is dropped:
    /// the state already belongs to something newer.
    private func land(id: UUID, host: String, answer: HostAddresses) {
        unfinished[id] = nil
        guard current?.id == id, !(current?.task.isCancelled ?? true) else { return }
        current = nil
        switch answer {
        case .found(let addresses): state = .found(host: host, addresses: addresses)
        case .noAddress: state = .noAddress(host: host)
        case .noAnswer: state = .noAnswer(host: host)
        }
    }
}
