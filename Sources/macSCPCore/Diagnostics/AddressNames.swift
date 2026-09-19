import Foundation

/// The resolve step's name table — its three columns, as catalogue keys — and
/// the words its check column is written in.
///
/// The table's shape follows `DiagnosticTraceColumn`, and for the same
/// reasons: Core names a column, the App resolves the name, and the report
/// prints each key's last component. The check WORDS are English and
/// unlocalized here, like every other word the report prints; the panel maps
/// them through `diagnostics.names.check.*`. Constants rather than literals,
/// so a reworded word breaks that mapping loudly instead of quietly
/// no longer matching.
///
/// **What the table is not: a verdict.** An address without a name, or with a
/// name that leads somewhere else, is common and no fault by itself — shared
/// hosting, a provider's generic PTR, a home line. So nothing here changes
/// the resolve row's outcome: the row reports what the lookups answered and
/// the reader judges (the S3 access probe's precedent, item 18 of
/// `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md`).
public enum DiagnosticNameColumn {
    public static let address = "diagnostics.names.column.address"
    public static let name = "diagnostics.names.column.name"
    public static let check = "diagnostics.names.column.check"

    /// Every column key, in the order the cells are written.
    public static let all = [address, name, check]

    /// The name resolves back to the address it was looked up for.
    public static let resolvesBack = "resolves back"
    /// The name resolves, or does not resolve at all, but not to this
    /// address.
    public static let doesNotResolveBack = "does not resolve back"
    /// The reverse lookup answered with an IP literal rather than a name.
    /// Resolving an address "back" to itself would confirm nothing, so the
    /// forward lookup is not made.
    public static let notAName = "not a name"
    /// The resolver has no name for the address.
    public static let noName = "no name"
    /// A lookup did not answer inside the resolve step's budget.
    public static let noAnswer = "no answer"

    /// What the name column says when there is no name to print: an empty
    /// cell reads as a value that went missing.
    public static let noNameCell = "—"
}

/// One address of the resolve step, with the name it was given and what
/// became of that name.
struct AddressName: Sendable, Equatable {
    /// The address, in `ResolvedAddress.text`'s numeric form.
    let address: String
    /// The name, made presentable (`ResolveLookups.presentable(_:)`), or `nil`
    /// when there is none — no name, or no answer in time.
    let name: String?
    /// One of `DiagnosticNameColumn`'s words, or a resolver's own sentence
    /// (`gai_strerror`) when a lookup failed rather than answered.
    let check: String
}

/// The lookups the resolve step makes, injectable so the suite can answer
/// them itself: `host` finds the endpoint's addresses, `reverse` asks for an
/// address's name, `forward` asks which addresses of one family a name
/// resolves to.
///
/// One seam for all three because they share ONE budget, the resolve step's
/// (`ConnectionDiagnostics.resolve`): a case can only show that the naming
/// gets what the host lookup left if it can make the host lookup take time.
///
/// `reverse` and `forward` each take the budget left and may answer `nil`
/// for "no answer in time" — and whatever they do with that budget, the
/// caller races them against the same budget from outside
/// (`name(_:within:)`), so an injected lookup that never answers is held to
/// it too.
struct ResolveLookups: Sendable {
    /// What a reverse lookup answered.
    enum Reverse: Sendable, Equatable {
        case name(String)
        /// The resolver has no name for the address (`EAI_NONAME`).
        case noName
        /// The lookup failed; the resolver's own sentence.
        case failed(String)
    }

    /// What a forward lookup answered.
    enum Forward: Sendable, Equatable {
        /// Every address of the asked family, numeric.
        case addresses([String])
        /// The name does not resolve in that family.
        case noAddress
        /// The lookup failed; the resolver's own sentence.
        case failed(String)
    }

    let host: @Sendable (_ host: String, _ port: Int, _ budget: Duration) async -> HostResolverOutcome
    let reverse: @Sendable (_ address: ResolvedAddress, _ budget: Duration) async -> Reverse?
    let forward:
        @Sendable (_ name: String, _ family: ResolvedAddress.Family, _ budget: Duration) async
            -> Forward?

    /// `host` defaults to the machine's own lookup, so a case about names
    /// states only the two lookups it answers.
    init(
        host: @escaping @Sendable (_ host: String, _ port: Int, _ budget: Duration) async
            -> HostResolverOutcome = { host, port, budget in
                await HostResolver.resolve(host: host, port: port, timeout: budget)
            },
        reverse: @escaping @Sendable (_ address: ResolvedAddress, _ budget: Duration) async
            -> Reverse?,
        forward: @escaping @Sendable (
            _ name: String, _ family: ResolvedAddress.Family, _ budget: Duration
        ) async -> Forward?
    ) {
        self.host = host
        self.reverse = reverse
        self.forward = forward
    }

    /// The machine's resolver, each lookup on a queue of its own under the
    /// budget it was handed (`HostResolver.resolve(host:port:timeout:flags:)`,
    /// `HostResolver.reverseLookUp(_:)`, `HostResolver.forwardLookUp(_:family:)`).
    static let live = ResolveLookups(
        reverse: { address, budget in
            await BlockingProbe.run(
                label: "dev.noidee.macscp.diagnostics.reverse", timeout: budget
            ) {
                HostResolver.reverseLookUp(address.socketAddress)
            }
        },
        forward: { name, family, budget in
            await BlockingProbe.run(
                label: "dev.noidee.macscp.diagnostics.forward", timeout: budget
            ) {
                HostResolver.forwardLookUp(name, family: family)
            }
        })

    /// Names every address, all of them at once, inside ONE budget: the part
    /// of the resolve step's own budget its host lookup left over.
    ///
    /// Concurrent rather than in turn, so a host with four addresses whose
    /// resolver is slow does not spend four budgets — and so one address
    /// that never answers costs the others nothing. The answers come back in
    /// the order of `addresses`, whichever finished first.
    func name(_ addresses: [ResolvedAddress], within budget: Duration) async -> [AddressName] {
        let deadline = ContinuousClock.now.advanced(by: budget)
        return await withTaskGroup(of: (Int, AddressName).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask { (index, await self.name(address, until: deadline)) }
            }
            var named = [AddressName?](repeating: nil, count: addresses.count)
            for await (index, answer) in group { named[index] = answer }
            return named.compactMap { $0 }
        }
    }

    /// One address: its name, then whether the name leads back to it.
    private func name(
        _ address: ResolvedAddress, until deadline: ContinuousClock.Instant
    ) async -> AddressName {
        guard let reverse = await Self.bounded(until: deadline, { await self.reverse(address, $0) })
        else {
            return AddressName(
                address: address.text, name: nil, check: DiagnosticNameColumn.noAnswer)
        }
        switch reverse {
        case .noName:
            return AddressName(address: address.text, name: nil, check: DiagnosticNameColumn.noName)
        case .failed(let sentence):
            return AddressName(address: address.text, name: nil, check: sentence)
        case .name(let name):
            let check = await confirm(name, of: address, until: deadline)
            return AddressName(address: address.text, name: Self.presentable(name), check: check)
        }
    }

    /// Whether `name` resolves back to `address`, as the check column's
    /// word — or the resolver's sentence, when the lookup failed.
    ///
    /// A name that is itself an IP literal is not looked up: resolving a
    /// literal hands back the literal, so a PTR record holding the address
    /// itself would "resolve back" whatever it said. The literal test is
    /// `JumpProbeHost`'s, the one this module already reads addresses out of
    /// foreign text with.
    ///
    /// Compared as numeric text with any IPv6 zone dropped from both sides:
    /// the forward answer for a link-local name need not carry the zone the
    /// resolve's own record did, and the zone names this Mac's interface,
    /// not the address.
    func confirm(
        _ name: String, of address: ResolvedAddress, within budget: Duration
    ) async -> String {
        await confirm(name, of: address, until: ContinuousClock.now.advanced(by: budget))
    }

    private func confirm(
        _ name: String, of address: ResolvedAddress, until deadline: ContinuousClock.Instant
    ) async -> String {
        guard JumpProbeHost.addressKind(of: name) == nil else { return DiagnosticNameColumn.notAName }
        guard
            let forward = await Self.bounded(
                until: deadline, { await self.forward(name, address.family, $0) })
        else { return DiagnosticNameColumn.noAnswer }
        switch forward {
        case .noAddress:
            return DiagnosticNameColumn.doesNotResolveBack
        case .failed(let sentence):
            return sentence
        case .addresses(let found):
            let wanted = Self.withoutZone(address.text)
            return found.contains { Self.withoutZone($0) == wanted }
                ? DiagnosticNameColumn.resolvesBack : DiagnosticNameColumn.doesNotResolveBack
        }
    }

    /// One lookup, handed what is left until `deadline` and raced against
    /// it from outside (`DetachedProbe`): `nil` when it did not answer in
    /// time, however it treats the budget itself — and without asking it at
    /// all when nothing is left.
    private static func bounded<T: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ lookUp: @escaping @Sendable (Duration) async -> T?
    ) async -> T? {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return nil }
        return await DetachedProbe.run(timeout: left) { await lookUp(left) } ?? nil
    }

    private static func withoutZone(_ text: String) -> Substring {
        text.prefix { $0 != "%" }
    }

    /// Anything the resolver handed back that would break a line or a cell,
    /// or rearrange the text around it, written as an escape instead: a C0
    /// or C1 control, a space, DEL, the two Unicode line breaks and the
    /// twelve bidirectional controls (the `Bidi_Control` scalars: U+061C,
    /// U+200E–200F, U+202A–202E, U+2066–2069). The DNS presentation escape
    /// `\DDD` for a scalar that fits a byte, `\u{…}` for those that do not.
    /// A backslash the name carries is itself escaped, as `\\`, so no name
    /// can spell an escape it does not contain — the text `\010` would
    /// otherwise print exactly like an escaped newline (final review M2 of
    /// the 2026-09-19 plan).
    ///
    /// Only for what the row PRINTS. A name is text a DNS server chose, and a
    /// newline in it would start a fresh line in the pasted report and in the
    /// command line's rows — a row that nobody measured — while a
    /// right-to-left override would reorder what follows it on screen. The
    /// forward lookup is asked with the name as it came back.
    static func presentable(_ name: String) -> String {
        var escaped = ""
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0...0x20, 0x7F...0x9F:
                escaped += "\\" + String(repeating: "0", count: 3 - String(scalar.value).count)
                    + String(scalar.value)
            case 0x5C:
                escaped += "\\\\"
            case 0x2028, 0x2029, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

extension ConnectionDiagnostics {
    /// The resolve step's name table, or `nil` when there is nothing to name.
    ///
    /// A `static func` over values, like `traceTable(_:)`, so the rows can be
    /// pinned without a resolver.
    static func namesTable(_ names: [AddressName]) -> DiagnosticTable? {
        guard !names.isEmpty else { return nil }
        return DiagnosticTable(
            columns: DiagnosticNameColumn.all,
            rows: names.map { [$0.address, $0.name ?? DiagnosticNameColumn.noNameCell, $0.check] })
    }
}
