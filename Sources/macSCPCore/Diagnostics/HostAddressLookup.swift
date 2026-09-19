import Foundation

/// What asking the machine's resolver for a host name's addresses found, in
/// the shape the connection form offers them.
public enum HostAddresses: Sendable, Equatable {
    /// The name's addresses, numeric, IPv4 first and then IPv6, each family
    /// in the order the resolver returned it. Never empty.
    case found([String])
    /// The resolver answered, and it had no address for the name.
    case noAddress
    /// No answer before the deadline, or the asking task was cancelled.
    case noAnswer
}

/// The connection form's way into the diagnostics resolver: a name in, its
/// addresses out, as text.
///
/// A narrow public seam over `HostResolver`, which stays module-internal.
/// The form needs the addresses as text and nothing else — not the socket
/// addresses the probes dial, not the resolver's error sentence, not the
/// reverse and forward lookups the resolve step names them with. So this
/// type makes public one lookup, the deadline it runs under, and one
/// predicate.
///
/// **Where it runs.** `HostResolver.resolve` puts `getaddrinfo` on a
/// `DispatchQueue` of its own (`BlockingProbe`), off the cooperative pool,
/// as the resolve step does.
///
/// **The deadline** is raced from OUTSIDE the resolver as well
/// (`DetachedProbe`), so the answer is bounded by this type's own clock
/// rather than by the resolver's honesty about the budget it was handed —
/// which is also what lets a test prove the bound with a resolver that never
/// answers. `getaddrinfo` itself cannot be interrupted: a lookup that loses
/// the race runs to its own end on its own queue, and its late answer is
/// dropped.
public enum HostAddressLookup {
    /// How long the form waits for an answer. The resolve step's own budget
    /// (`ConnectionDiagnostics`' default `stepTimeout`), so a name the
    /// diagnosis would call unresolved in time is one the form gives up on
    /// at the same point.
    public static let deadline: Duration = .seconds(5)

    /// The addresses `host` resolves to, under `deadline`.
    public static func addresses(of host: String) async -> HostAddresses {
        await addresses(of: host, within: deadline, resolve: live)
    }

    /// Whether the field's text is something to resolve: a name. An empty
    /// field is not, and neither is an IP literal — it resolves to itself,
    /// and a menu offering it back would change nothing.
    ///
    /// A zone-scoped IPv6 literal (`fe80::1%en0`) is not recognised as a
    /// literal (`JumpProbeHost.addressKind(of:)` refuses the `%`), so it
    /// counts as a name; resolving it answers the address itself.
    public static func isResolvable(_ host: String) -> Bool {
        let name = trimmed(host)
        return !name.isEmpty && JumpProbeHost.addressKind(of: name) == nil
    }

    /// The lookup with its resolver injected — `live` in production, a fake
    /// in the suite. The resolver is handed the whole deadline as its budget
    /// and raced against the same deadline from outside.
    static func addresses(
        of host: String, within deadline: Duration,
        resolve: @escaping @Sendable (_ name: String, _ budget: Duration) async -> HostResolverOutcome
    ) async -> HostAddresses {
        let name = trimmed(host)
        guard let outcome = await DetachedProbe.run(timeout: deadline, { await resolve(name, deadline) })
        else { return .noAnswer }
        return answer(from: outcome)
    }

    /// The machine's resolver — the diagnostics one. The port plays no part
    /// in which addresses a name has; `0` is a numeric service `getaddrinfo`
    /// takes without consulting the services database.
    static let live: @Sendable (_ name: String, _ budget: Duration) async -> HostResolverOutcome = {
        name, budget in
        await HostResolver.resolve(host: name, port: 0, timeout: budget)
    }

    /// The resolver's outcome, as the form offers it: the addresses in their
    /// numeric form, IPv4 first and then IPv6, each family in the resolver's
    /// order. `HostResolver` has already dropped duplicates and treats a
    /// zero-address success as a failure, so `.found` is never empty.
    static func answer(from outcome: HostResolverOutcome) -> HostAddresses {
        switch outcome {
        case .resolved(let addresses):
            let ordered =
                addresses.filter { $0.family == .ipv4 } + addresses.filter { $0.family == .ipv6 }
            return ordered.isEmpty ? .noAddress : .found(ordered.map(\.text))
        case .failed:
            return .noAddress
        case .timedOut:
            return .noAnswer
        }
    }

    private static func trimmed(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
