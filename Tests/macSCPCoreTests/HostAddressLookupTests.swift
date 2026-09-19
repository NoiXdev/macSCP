import Darwin
import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// `HostAddressLookup` — the connection form's "Resolve…" asks the
/// diagnostics resolver for a name's addresses through it (the BACKLOG row
/// "Offer to resolve an entered host name to its IP", 2026-09-19).
///
/// **Nothing here asks a resolver for a name.** The resolver is injected,
/// and its addresses are TEST-NET and documentation literals turned into
/// socket addresses with `AI_NUMERICHOST` (`ResolveNamesTests.address(_:)`),
/// which asks no resolver anything. The one case through the machine's own
/// `getaddrinfo` hands it the literals `127.0.0.1` and `::1`, which it reads
/// as addresses rather than looking them up. Names are `.invalid`.
///
/// **Deadlines.** A case whose lookup must not be cut gives it 600 s, which
/// nothing here comes near. The case about the cut gives 200 ms to a lookup
/// that never answers on its own: it is parked until its task is cancelled,
/// so the deadline is the only thing that can end it and the case does not
/// depend on how fast the runner is. The suite's time limit is the
/// harness's, for a regression that stops cutting it: it turns a hang into
/// a red, and asserts nothing about how long the cut took.
@Suite("Host address lookup for the connection form", .timeLimit(.minutes(1)))
struct HostAddressLookupTests {
    private static let roomy: Duration = .seconds(600)
    private static let tight: Duration = .milliseconds(200)

    // MARK: - Ordering

    /// IPv4 first, then IPv6, each family in the order the resolver gave it
    /// — the order the resolver interleaves them in is not kept across the
    /// two families.
    @Test func theAddressesComeIPv4FirstThenIPv6EachInResolverOrder() async throws {
        let resolved = [
            try await ResolveNamesTests.address("2001:db8::1"),
            try await ResolveNamesTests.address("192.0.2.10"),
            try await ResolveNamesTests.address("2001:db8::2"),
            try await ResolveNamesTests.address("198.51.100.7"),
        ]

        let answer = await HostAddressLookup.addresses(
            of: "server.invalid", within: Self.roomy,
            resolve: { _, _ in .resolved(resolved) })

        #expect(answer == .found(["192.0.2.10", "198.51.100.7", "2001:db8::1", "2001:db8::2"]))
    }

    @Test func aSingleFamilyKeepsTheResolversOrder() async throws {
        let resolved = [
            try await ResolveNamesTests.address("198.51.100.7"),
            try await ResolveNamesTests.address("192.0.2.10"),
        ]

        #expect(HostAddressLookup.answer(from: .resolved(resolved))
            == .found(["198.51.100.7", "192.0.2.10"]))
    }

    // MARK: - No address, no answer

    /// The resolver's own failure — `gai_strerror`'s sentence, or its
    /// "no address returned" — is no address for the form. The sentence is
    /// not carried: the form says it in its own, localized words.
    @Test func aFailedLookupIsNoAddress() {
        #expect(HostAddressLookup.answer(from: .failed("nodename nor servname provided"))
            == .noAddress)
    }

    @Test func aResolverThatTimedOutIsNoAnswer() {
        #expect(HostAddressLookup.answer(from: .timedOut) == .noAnswer)
    }

    /// The deadline is the seam's own, raced from outside the lookup, so a
    /// resolver that never answers is cut by it too.
    @Test func aLookupThatNeverAnswersIsCutByTheDeadline() async {
        let answer = await HostAddressLookup.addresses(
            of: "silent.invalid", within: Self.tight,
            resolve: { _, _ in
                await suspendUntilCancelled()
                return .failed("released by cancellation — must not be what the caller sees")
            })

        #expect(answer == .noAnswer)
    }

    // MARK: - What is asked

    /// The field's text is asked trimmed — a trailing space typed or pasted
    /// into the host field is not part of the name — and the resolver gets
    /// the whole deadline as its own budget.
    @Test func theNameIsAskedTrimmedWithTheWholeDeadline() async throws {
        let asked = Mutex<[String]>([])
        let resolved = [try await ResolveNamesTests.address("192.0.2.10")]

        _ = await HostAddressLookup.addresses(
            of: "  server.invalid\n", within: Self.roomy,
            resolve: { name, budget in
                asked.withLock { $0.append("\(name) \(budget)") }
                return .resolved(resolved)
            })

        #expect(asked.withLock { $0 } == ["server.invalid \(Self.roomy)"])
    }

    /// The live resolver is the diagnostics one, reached through the seam: a
    /// literal comes back as itself, in its numeric form.
    @Test(arguments: ["127.0.0.1", "::1"])
    func theLiveResolverAnswersALiteralWithItself(_ literal: String) async {
        let answer = await HostAddressLookup.addresses(
            of: literal, within: Self.roomy, resolve: HostAddressLookup.live)

        #expect(answer == .found([literal]))
    }

    // MARK: - What can be resolved

    /// A name can be resolved; an empty field and an address cannot — an
    /// address resolves to itself, and offering it back is a menu of one
    /// entry that changes nothing.
    @Test(arguments: [
        ("server.invalid", true),
        ("  server.invalid ", true),
        ("", false),
        ("   ", false),
        ("192.0.2.10", false),
        ("2001:db8::1", false),
        (" 192.0.2.10 ", false),
    ])
    func onlyANameIsResolvable(_ host: String, _ resolvable: Bool) {
        #expect(HostAddressLookup.isResolvable(host) == resolvable)
    }
}

/// Suspends until the calling task is cancelled, and only then returns —
/// the shape of `ConnectionDiagnosticsTests`' parked fakes, for the reason
/// given there: a fake that can finish on its own races whatever is meant to
/// end it. An `AsyncStream` nothing ever yields to ends its iteration when
/// the iterating task is cancelled.
private func suspendUntilCancelled() async {
    let (never, producer) = AsyncStream<Never>.makeStream()
    for await _ in never {}
    producer.finish()
}
