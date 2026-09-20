import Darwin
import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// The resolve step names each address it found — a reverse lookup — and
/// checks that the name resolves back to it (the BACKLOG row "Diagnostics:
/// reverse DNS and host name check", 2026-09-19).
///
/// **Nothing here asks a resolver for a name but one case.** The reverse and
/// forward lookups are injected (`ResolveLookups`), and the addresses are
/// TEST-NET and documentation literals turned into socket addresses with
/// `AI_NUMERICHOST`, which asks no resolver anything. The walk cases resolve
/// the literal `127.0.0.1`, which `getaddrinfo` reads as an address rather
/// than looking it up. The names are `.invalid` (RFC 2606). The one case
/// that runs the machine's own reverse and forward lookups asks about
/// `127.0.0.1`, which this machine names (which source answered — the hosts
/// file or DNS — was not measured).
///
/// **Budgets.** A case whose lookups must NOT be cut gives them 600 s, the
/// one against the machine's own resolver included — a budget no runner
/// reaches, as `HostAddressLookupTests` gives its own; 30 s was only twice
/// the 14.67 s ambient stall measured on CI. The time limit is a hang bound,
/// not a ceiling on any case. The cases about the cut give 200 ms to a
/// lookup that never answers until the case releases it, or to a host
/// lookup that sleeps the whole of it, so the cut is decided by the lookup
/// and not by how fast the runner is.
@Suite("The resolve step's names", .timeLimit(.minutes(2)))
struct ResolveNamesTests {
    private static let roomy: Duration = .seconds(600)
    private static let tight: Duration = .milliseconds(200)

    // MARK: - One address, each answer

    @Test func aNameThatResolvesBackIsReportedAsResolvingBack() async throws {
        let address = try await Self.address("192.0.2.10")
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .name("server.invalid")],
            forward: ["server.invalid": .addresses(["192.0.2.99", "192.0.2.10"])])

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names == [
            AddressName(
                address: "192.0.2.10", name: "server.invalid",
                check: DiagnosticNameColumn.resolvesBack),
        ])
    }

    @Test func aNameThatLeadsElsewhereIsReportedAsNotResolvingBack() async throws {
        let address = try await Self.address("192.0.2.10")
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .name("server.invalid")],
            forward: ["server.invalid": .addresses(["192.0.2.99"])])

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names.map(\.check) == [DiagnosticNameColumn.doesNotResolveBack])
        #expect(names.map(\.name) == ["server.invalid"])
    }

    /// A name that does not resolve at all leads back to nothing, which is
    /// the same finding about the name.
    @Test func aNameThatDoesNotResolveIsReportedAsNotResolvingBack() async throws {
        let address = try await Self.address("192.0.2.10")
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .name("server.invalid")],
            forward: ["server.invalid": .noAddress])

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names.map(\.check) == [DiagnosticNameColumn.doesNotResolveBack])
    }

    @Test func anAddressWithoutANameIsReportedAsHavingNone() async throws {
        let address = try await Self.address("192.0.2.10")
        let asked = Questions()
        let lookups = Self.lookups(reverse: ["192.0.2.10": .noName], forward: [:], asked: asked)

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names == [
            AddressName(address: "192.0.2.10", name: nil, check: DiagnosticNameColumn.noName)
        ])
        // Asked, and asked only the one question: with no name there is
        // nothing to resolve back. Positive beside negative — the reverse
        // question is required, so an empty log cannot satisfy the second.
        #expect(asked.all == ["reverse 192.0.2.10"])
    }

    /// A reverse lookup that answers with an address is not a name, and the
    /// forward lookup that would "confirm" it is not made — an IP literal
    /// resolves to itself whatever it is.
    @Test func aReverseAnswerThatIsAnAddressIsNotAName() async throws {
        let address = try await Self.address("192.0.2.10")
        let asked = Questions()
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .name("192.0.2.10")],
            forward: ["192.0.2.10": .addresses(["192.0.2.10"])], asked: asked)

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names.map(\.check) == [DiagnosticNameColumn.notAName])
        #expect(names.map(\.name) == ["192.0.2.10"])
        #expect(asked.all == ["reverse 192.0.2.10"])
    }

    /// A lookup that FAILED rather than answered carries the resolver's own
    /// sentence, the way the resolve row itself does.
    @Test func aFailedLookupCarriesTheResolversOwnSentence() async throws {
        let address = try await Self.address("192.0.2.10")
        let other = try await Self.address("192.0.2.11")
        let lookups = Self.lookups(
            reverse: [
                "192.0.2.10": .failed("temporary failure"),
                "192.0.2.11": .name("server.invalid"),
            ],
            forward: ["server.invalid": .failed("server failure")])

        let names = await lookups.name([address, other], within: Self.roomy)

        #expect(names.map(\.check) == ["temporary failure", "server failure"])
        #expect(names.map(\.name) == [nil, "server.invalid"])
    }

    // MARK: - The budget

    /// A reverse lookup that does not answer inside the budget is `no
    /// answer` — the step goes on, and nothing waits for the lookup.
    ///
    /// Nothing here asserts that the lookup was ASKED before the cut. That
    /// was a check once, and the whole suite turned it red on this machine
    /// (2026-09-19, load average 4.8): the lookup runs as a detached task,
    /// and on a busy pool the 200 ms budget ran out before the task got a
    /// thread at all. "Not asked in time" and "asked and silent" are one
    /// answer by design — neither is a name — so the case pins the answer.
    @Test func aReverseLookupCutByTheBudgetIsNoAnswer() async throws {
        let address = try await Self.address("192.0.2.10")
        let release = AsyncSignal()
        let lookups = ResolveLookups(
            reverse: { _, _ in
                _ = await release.wait()
                return .name("late.invalid")
            },
            forward: { _, _, _ in .addresses(["192.0.2.10"]) })

        let names = await lookups.name([address], within: Self.tight)
        release.signal()

        #expect(names == [
            AddressName(address: "192.0.2.10", name: nil, check: DiagnosticNameColumn.noAnswer)
        ])
    }

    /// The name came back and the forward lookup did not answer in time: the
    /// check says so.
    ///
    /// Asked of the confirming half directly, with the name already in hand,
    /// so the ONLY lookup racing the tight budget is the one that never
    /// answers — a reverse lookup that had to answer inside 200 ms first
    /// would make this case a measurement of the runner. For the reverse
    /// case's reason, whether the lookup was asked before the cut is not
    /// asserted.
    @Test func aForwardLookupCutByTheBudgetIsNoAnswer() async throws {
        let address = try await Self.address("192.0.2.10")
        let release = AsyncSignal()
        let lookups = ResolveLookups(
            reverse: { _, _ in
                Issue.record("the confirming half asked for a name")
                return .noName
            },
            forward: { _, _, _ in
                _ = await release.wait()
                return .addresses(["192.0.2.10"])
            })

        let check = await lookups.confirm("server.invalid", of: address, within: Self.tight)
        release.signal()

        #expect(check == DiagnosticNameColumn.noAnswer)
    }

    /// Nothing left of the budget is no answer for every address, and no
    /// question is put.
    @Test func noBudgetLeftIsNoAnswerForEveryAddress() async throws {
        let addresses = [try await Self.address("192.0.2.10"), try await Self.address("2001:db8::10")]
        let asked = Questions()
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .noName, "2001:db8::10": .noName], forward: [:], asked: asked)

        let names = await lookups.name(addresses, within: .zero)

        #expect(names.map(\.check) == [DiagnosticNameColumn.noAnswer, DiagnosticNameColumn.noAnswer])
        #expect(names.map(\.address) == ["192.0.2.10", "2001:db8::10"])
        #expect(asked.all.isEmpty)
    }

    // MARK: - Several addresses

    /// Every address is named, in the order the resolve found them, each
    /// forward lookup asked in its own address's family.
    @Test func severalAddressesAreNamedInTheirOwnOrderAndFamily() async throws {
        let addresses = [
            try await Self.address("192.0.2.1"),
            try await Self.address("2001:db8::1"),
            try await Self.address("198.51.100.1"),
        ]
        let asked = Questions()
        let lookups = Self.lookups(
            reverse: [
                "192.0.2.1": .name("v4.invalid"),
                "2001:db8::1": .name("v6.invalid"),
                "198.51.100.1": .noName,
            ],
            forward: [
                "v4.invalid": .addresses(["192.0.2.1"]),
                "v6.invalid": .addresses(["2001:db8::2"]),
            ],
            asked: asked)

        let names = await lookups.name(addresses, within: Self.roomy)

        #expect(names == [
            AddressName(
                address: "192.0.2.1", name: "v4.invalid", check: DiagnosticNameColumn.resolvesBack),
            AddressName(
                address: "2001:db8::1", name: "v6.invalid",
                check: DiagnosticNameColumn.doesNotResolveBack),
            AddressName(address: "198.51.100.1", name: nil, check: DiagnosticNameColumn.noName),
        ])
        #expect(Set(asked.all) == [
            "reverse 192.0.2.1", "reverse 2001:db8::1", "reverse 198.51.100.1",
            "forward v4.invalid IPv4", "forward v6.invalid IPv6",
        ])
    }

    /// The addresses are named at the same time, not in turn — which is what
    /// keeps an address whose lookup never answers from spending the others'
    /// budget. Proven without a clock: the first address's lookup answers
    /// only once the SECOND address has been asked, which naming them in
    /// turn would never do while the first was waiting. In turn, the first
    /// would wait out the whole 600 s budget, and the suite's time limit
    /// turns that wait red long before.
    @Test func theAddressesAreNamedAtTheSameTime() async throws {
        let addresses = [try await Self.address("192.0.2.1"), try await Self.address("192.0.2.2")]
        let secondAsked = AsyncSignal()
        let lookups = ResolveLookups(
            reverse: { address, _ in
                if address.text == "192.0.2.2" {
                    secondAsked.signal()
                    return .noName
                }
                guard await secondAsked.wait() == .signalled else { return .noName }
                return .name("first.invalid")
            },
            forward: { _, _, _ in .addresses(["192.0.2.1"]) })

        let names = await lookups.name(addresses, within: Self.roomy)

        #expect(names == [
            AddressName(
                address: "192.0.2.1", name: "first.invalid",
                check: DiagnosticNameColumn.resolvesBack),
            AddressName(address: "192.0.2.2", name: nil, check: DiagnosticNameColumn.noName),
        ])
    }

    // MARK: - What a row may print

    /// A name is text a DNS server chose. What would break a line or a cell
    /// is escaped; the forward lookup is asked with the name as it came.
    @Test func aNameThatWouldBreakALineIsEscapedInTheRow() async throws {
        let address = try await Self.address("192.0.2.10")
        let hostile = "a\nb c\u{7F}\u{2028}.invalid"
        let asked = Questions()
        let lookups = Self.lookups(
            reverse: ["192.0.2.10": .name(hostile)],
            forward: [hostile: .addresses(["192.0.2.10"])], asked: asked)

        let names = await lookups.name([address], within: Self.roomy)

        #expect(names.map(\.name) == ["a\\010b\\032c\\127\\u{2028}.invalid"])
        #expect(names.map(\.check) == [DiagnosticNameColumn.resolvesBack])
        #expect(asked.all.contains("forward \(hostile) IPv4"))
    }

    @Test func thePresentableFormLeavesAnOrdinaryNameAlone() {
        #expect(ResolveLookups.presentable("host-1.example.invalid") == "host-1.example.invalid")
        #expect(ResolveLookups.presentable("tab\there") == "tab\\009here")
    }

    /// A backslash the name itself carries is escaped too, so the text
    /// `\010` in a name cannot pass for an escaped newline: the two print
    /// differently.
    @Test func aLiteralBackslashIsEscaped() {
        let spelled = ResolveLookups.presentable("a\\010b.invalid")
        let newline = ResolveLookups.presentable("a\nb.invalid")

        #expect(spelled == "a\\\\010b.invalid")
        #expect(newline == "a\\010b.invalid")
        #expect(spelled != newline)
    }

    /// The Unicode bidirectional controls — the twelve scalars with the
    /// `Bidi_Control` property — would reorder the text around them in a
    /// pasted report, so each is written as an escape.
    @Test(arguments: [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ] as [UInt32])
    func aBidiControlIsEscaped(value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        var name = "a"
        name.unicodeScalars.append(scalar)
        name += "b.invalid"

        let escape = "\\u{\(String(value, radix: 16, uppercase: true))}"
        #expect(ResolveLookups.presentable(name) == "a" + escape + "b.invalid")
    }

    // MARK: - The table

    @Test func theTableHasOneRowPerAddressUnderTheThreeColumns() {
        let table = ConnectionDiagnostics.namesTable([
            AddressName(
                address: "192.0.2.1", name: "v4.invalid", check: DiagnosticNameColumn.resolvesBack),
            AddressName(address: "2001:db8::1", name: nil, check: DiagnosticNameColumn.noName),
        ])
        #expect(table?.columns == DiagnosticNameColumn.all)
        #expect(table?.rows == [
            ["192.0.2.1", "v4.invalid", DiagnosticNameColumn.resolvesBack],
            ["2001:db8::1", DiagnosticNameColumn.noNameCell, DiagnosticNameColumn.noName],
        ])
        #expect(ConnectionDiagnostics.namesTable([]) == nil)
    }

    // MARK: - Through the walk

    /// The resolve row carries the names as its table, keeps its detail line
    /// as it always was, and stays `ok` whatever the names say — a name that
    /// does not resolve back is a report, never a verdict.
    @Test func theResolveRowCarriesTheNamesAndStaysOk() async throws {
        let lookups = Self.lookups(
            reverse: ["127.0.0.1": .name("elsewhere.invalid")],
            forward: ["elsewhere.invalid": .addresses(["192.0.2.1"])])

        let report = await Self.walk(host: "127.0.0.1", lookups: lookups, stepTimeout: Self.roomy)

        let resolve = try #require(report.steps.first)
        #expect(report.steps.map(\.id) == [DiagnosticStepID.resolve])
        #expect(resolve.outcome == .ok)
        #expect(resolve.detail == "IPv4 127.0.0.1")
        #expect(resolve.table == DiagnosticTable(
            columns: DiagnosticNameColumn.all,
            rows: [["127.0.0.1", "elsewhere.invalid", DiagnosticNameColumn.doesNotResolveBack]]))
        #expect(DiagnoseRendering.exitCode(for: report) == .success)
    }

    /// The lookups count against the resolve step's own budget: what they
    /// are handed is what the HOST lookup left of it, never a budget of
    /// their own. That the handed budget is then kept is
    /// `aReverseLookupCutByTheBudgetIsNoAnswer`'s property.
    ///
    /// The host lookup is made to take at least 300 ms, so the budget
    /// handed on can be at most the step's less that — a floor on the time
    /// spent, which a slow runner can only make larger, and the budget
    /// handed on only smaller. The step's budget is 600 s, which no runner
    /// comes near, so the naming is never cut here.
    @Test func theNamesAreHandedWhatTheHostLookupLeftOfTheStepsBudget() async throws {
        let spent: Duration = .milliseconds(300)
        let handed = Mutex<[Duration]>([])
        let lookups = ResolveLookups(
            host: { host, port, budget in
                try? await Task.sleep(for: spent)
                return await HostResolver.resolve(
                    host: host, port: port, timeout: budget, flags: AI_NUMERICHOST)
            },
            reverse: { _, budget in
                handed.withLock { $0.append(budget) }
                return .name("loop.invalid")
            },
            forward: { _, _, budget in
                handed.withLock { $0.append(budget) }
                return .addresses(["127.0.0.1"])
            })

        let report = await Self.walk(host: "127.0.0.1", lookups: lookups, stepTimeout: Self.roomy)

        let budgets = handed.withLock { $0 }
        let resolve = try #require(report.steps.first)
        #expect(budgets.count == 2)
        #expect(budgets.allSatisfy { $0 <= Self.roomy - spent && $0 > .zero }, """
            the lookups were handed \(budgets), not what the host lookup left of \(Self.roomy)
            """)
        #expect(resolve.outcome == .ok)
        #expect(resolve.table?.rows == [["127.0.0.1", "loop.invalid", DiagnosticNameColumn.resolvesBack]])
    }

    /// A host lookup that used the whole budget leaves the naming nothing:
    /// every address is `no answer`, and no name is asked for — while the
    /// row still reports the addresses it found, `ok`.
    @Test func aHostLookupThatSpentTheBudgetLeavesTheNamesNoAnswer() async throws {
        let asked = Questions()
        let lookups = ResolveLookups(
            host: { host, port, budget in
                try? await Task.sleep(for: budget)
                return await HostResolver.resolve(
                    host: host, port: port, timeout: Self.roomy, flags: AI_NUMERICHOST)
            },
            reverse: { address, _ in
                asked.record("reverse \(address.text)")
                return .noName
            },
            forward: { _, _, _ in .noAddress })

        let report = await Self.walk(host: "127.0.0.1", lookups: lookups, stepTimeout: Self.tight)

        let resolve = try #require(report.steps.first)
        #expect(resolve.outcome == .ok)
        #expect(resolve.detail == "IPv4 127.0.0.1")
        #expect(resolve.table?.rows == [
            ["127.0.0.1", DiagnosticNameColumn.noNameCell, DiagnosticNameColumn.noAnswer]
        ])
        #expect(asked.all.isEmpty)
    }

    /// The pasted report prints the names under the resolve row, in both
    /// renderings.
    @Test func bothRenderingsPrintTheNamesUnderTheResolveRow() async throws {
        let lookups = Self.lookups(
            reverse: ["127.0.0.1": .name("loop.invalid")],
            forward: ["loop.invalid": .addresses(["127.0.0.1"])])
        let report = await Self.walk(host: "127.0.0.1", lookups: lookups, stepTimeout: Self.roomy)

        let text = report.plainText().components(separatedBy: "\n")
        let row = try #require(text.firstIndex { $0.hasPrefix("resolve — ok") })
        #expect(text.dropFirst(row + 1).first?.contains("address") == true)
        let named = text.dropFirst(row + 2).first ?? ""
        #expect(named.contains("127.0.0.1"))
        #expect(named.contains("loop.invalid"))
        #expect(named.contains(DiagnosticNameColumn.resolvesBack))

        let markdown = report.markdown()
        #expect(markdown.contains("## `resolve`"))
        #expect(markdown.contains("| address | name | check |"))
        #expect(markdown.contains("| 127.0.0.1 | loop.invalid | resolves back |"))
    }

    // MARK: - The machine's own resolver

    /// The live lookups against loopback: a name comes back, and it resolves
    /// back. Whatever the name is — the case
    /// does not spell the machine's hosts file.
    ///
    /// The budget is not under test here, the lookups are, so it is one no
    /// runner reaches. It was 5 s once, and the whole suite cut it on this
    /// machine at a load average of 91 (2026-09-19): the case read `no
    /// answer` after 9.4 s, which is the runner's word, not the resolver's.
    @Test func theLiveLookupsNameLoopbackAndConfirmIt() async throws {
        let address = try await Self.address("127.0.0.1")

        let names = await ResolveLookups.live.name([address], within: .seconds(600))

        let named = try #require(names.first)
        #expect(names.count == 1)
        #expect(named.address == "127.0.0.1")
        #expect(named.name?.isEmpty == false)
        #expect(named.check == DiagnosticNameColumn.resolvesBack)
    }

    // MARK: - Support

    /// A literal as the resolve would carry it — through `getaddrinfo` with
    /// `AI_NUMERICHOST`, which asks no resolver.
    static func address(_ literal: String) async throws -> ResolvedAddress {
        let outcome = await HostResolver.resolve(
            host: literal, port: 22, timeout: roomy, flags: AI_NUMERICHOST)
        guard case .resolved(let addresses) = outcome, let first = addresses.first else {
            throw ResolveNamesTestError.notALiteral(literal)
        }
        return first
    }

    /// A resolver answered from two tables. An address or name missing from
    /// its table fails the case: the lookup asked something nobody expected.
    static func lookups(
        reverse: [String: ResolveLookups.Reverse], forward: [String: ResolveLookups.Forward],
        asked: Questions = Questions()
    ) -> ResolveLookups {
        ResolveLookups(
            reverse: { address, _ in
                asked.record("reverse \(address.text)")
                guard let answer = reverse[address.text] else {
                    Issue.record("reverse lookup of an unexpected address \(address.text)")
                    return .noName
                }
                return answer
            },
            forward: { name, family, _ in
                asked.record("forward \(name) \(family.rawValue)")
                guard let answer = forward[name] else {
                    Issue.record("forward lookup of an unexpected name \(name)")
                    return .noAddress
                }
                return answer
            })
    }

    /// A direct walk that measures only the resolve step: the `dial` scope
    /// against a descriptor with no dial.
    static func walk(
        host: String, lookups: ResolveLookups, stepTimeout: Duration
    ) async -> DiagnosticReport {
        await ConnectionDiagnostics(
            descriptor: descriptor(endpoint: Endpoint(host: host, port: 22)),
            values: FieldValues(), secrets: nil, jump: nil,
            jumpDialer: DiagnosticJumpDialer(
                connectJump: { _, _ in throw RemoteFSError.protocolError(reason: "unused") },
                dialTarget: { _, _ in throw RemoteFSError.protocolError(reason: "unused") }),
            lookups: lookups, internetSpeedTransport: .neverAsked,
            stepTimeout: stepTimeout, appVersion: "test"
        ).run(scope: .dial)
    }

    private static func descriptor(endpoint: Endpoint) -> BackendDescriptor {
        BackendDescriptor(
            kind: .s3,
            capabilities: BackendDescriptor.descriptor(for: .s3).capabilities,
            connectionSchema: ConnectionFieldSchema(fields: [], presets: []),
            credentialSchema: ConnectionFieldSchema(fields: [], presets: []),
            makeConfig: { _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            displaySummary: { _ in "" },
            apply: { _, _ in },
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [],
            endpoint: { _ in endpoint }, dial: nil, diagnostics: [])
    }
}

/// Every question a scripted resolver was asked, in the order it was asked.
final class Questions: Sendable {
    private let asked = Mutex<[String]>([])

    func record(_ question: String) { asked.withLock { $0.append(question) } }

    var all: [String] { asked.withLock { $0 } }
}

enum ResolveNamesTestError: Error {
    case notALiteral(String)
}
