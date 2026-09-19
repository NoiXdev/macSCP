import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// `HostResolveModel` — the connection form's "Resolve…" beside the host
/// field (the BACKLOG row "Offer to resolve an entered host name to its IP",
/// 2026-09-19): which forms offer it, what choosing an address writes, and
/// that a lookup without an address leaves the form as it was.
///
/// **No resolver is asked anything.** The lookup is scripted
/// (`ScriptedLookup`): each lookup waits until the case answers it, or —
/// unless it is made deaf to it — until its task is cancelled; never on a
/// clock of its own, so nothing here races a deadline. The deadline itself is `HostAddressLookup`'s, and
/// `HostAddressLookupTests` measures it. Names are `.invalid`, addresses are
/// TEST-NET and documentation literals.
///
/// That the form draws this model beside the host field, only for SSH, and
/// that nothing on this path writes a known host, is
/// `HostResolveWiringGuardTests`' claim, read from source.
@MainActor
@Suite("Resolving the host field", .timeLimit(.minutes(1)))
struct HostResolveModelTests {
    private static func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in
            fatalError("not exercised by these tests — nothing here dials")
        })
    }

    /// A form filled in everywhere a stray write could land: the target's
    /// endpoint and login, the jump's, and the session name.
    private static func makeFilledForm(host: String) -> ConnectionViewModel {
        let form = makeForm()
        form.host = host
        form.port = "2222"
        form.username = "alice"
        form.jumpEnabled = true
        form.jumpHost = "bastion.invalid"
        form.jumpPort = "2200"
        form.jumpUsername = "bob"
        form.saveName = "web"
        return form
    }

    // MARK: - Which forms offer it

    /// SSH/SFTP only. An S3 or WebDAV endpoint is reached over TLS, whose
    /// certificate is checked against the NAME — an address would not match.
    @Test func theActionIsOfferedForSSHOnly() {
        #expect(ConnectionKind.allCases.filter { HostResolveModel.isOffered(for: $0) } == [.ssh])
    }

    // MARK: - Offering and choosing

    @Test func aResolvedNameOffersItsAddressesInTheLookupsOrder() async {
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)

        model.resolve("server.invalid")
        #expect(model.state == .resolving(host: "server.invalid"))
        script.answer("server.invalid", with: .found(["192.0.2.10", "2001:db8::1"]))
        await model.settle()

        #expect(model.presentation(forHost: "server.invalid")
            == .found(host: "server.invalid", addresses: ["192.0.2.10", "2001:db8::1"]))
        #expect(script.asked == ["server.invalid"])
    }

    /// Choosing replaces the host text and nothing else: every other field
    /// the form holds — port, login, the jump's own host and login — and the
    /// session name are as they were.
    @Test func choosingAnAddressWritesOnlyTheHostField() async {
        let form = Self.makeFilledForm(host: "server.invalid")
        let valuesBefore = form.values
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)
        model.resolve(form.host)
        script.answer("server.invalid", with: .found(["192.0.2.10", "2001:db8::1"]))
        await model.settle()

        model.choose("2001:db8::1", in: form)

        var expected = valuesBefore
        expected[SSHField.host] = "2001:db8::1"
        #expect(form.values == expected)
        #expect(form.host == "2001:db8::1")
        #expect(form.saveName == "web")
        #expect(form.kind == .ssh)
        #expect(form.jumpEnabled)
    }

    /// Once the field holds the address, the offer made for the name is gone.
    @Test func choosingEndsTheOffer() async {
        let form = Self.makeFilledForm(host: "server.invalid")
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)
        model.resolve(form.host)
        script.answer("server.invalid", with: .found(["192.0.2.10"]))
        await model.settle()

        model.choose("192.0.2.10", in: form)

        #expect(model.presentation(forHost: form.host) == .idle)
        #expect(model.presentation(forHost: "server.invalid") == .idle)
    }

    /// An address the offer did not contain is not written.
    @Test func anAddressTheOfferDidNotContainIsNotWritten() async {
        let form = Self.makeFilledForm(host: "server.invalid")
        let valuesBefore = form.values
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)
        model.resolve(form.host)
        script.answer("server.invalid", with: .found(["192.0.2.10"]))
        await model.settle()

        model.choose("198.51.100.7", in: form)

        #expect(form.values == valuesBefore)
    }

    // MARK: - No address

    /// A lookup that found nothing, or did not answer in time, says so and
    /// leaves every field — the host text included — as it was.
    @Test(arguments: [HostAddresses.noAddress, .noAnswer])
    func aFailingLookupLeavesTheFormUnchanged(_ outcome: HostAddresses) async {
        let form = Self.makeFilledForm(host: "missing.invalid")
        let valuesBefore = form.values
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)

        model.resolve(form.host)
        script.answer("missing.invalid", with: outcome)
        await model.settle()

        #expect(form.values == valuesBefore)
        let expected: HostResolveModel.State =
            outcome == .noAddress
            ? .noAddress(host: "missing.invalid") : .noAnswer(host: "missing.invalid")
        #expect(model.presentation(forHost: form.host) == expected)
        #expect(HostResolveModel.footnote(for: expected) != nil)
    }

    // MARK: - Staleness

    /// An offer belongs to the text it was made for: once the field says
    /// something else, it is not shown.
    @Test func anOfferIsNotShownForAnotherHostText() async {
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)
        model.resolve("first.invalid")
        script.answer("first.invalid", with: .found(["192.0.2.10"]))
        await model.settle()

        #expect(model.presentation(forHost: "second.invalid") == .idle)
        #expect(model.presentation(forHost: "first.invalid")
            == .found(host: "first.invalid", addresses: ["192.0.2.10"]))
    }

    /// A second lookup replaces the first: the first is cancelled, and
    /// whatever it still answers is dropped — even when it answers AFTER the
    /// second one landed, which is the order that would overwrite it.
    ///
    /// The lookups here ignore their cancellation, as `getaddrinfo` does: a
    /// lookup that honoured it would end at once with nothing, and the case
    /// could not tell a dropped answer from one that never came (measured:
    /// with the model's drop check removed, the honouring version stayed
    /// green 5 of 5).
    @Test func aNewerLookupSupersedesAnOlderOne() async throws {
        let script = ScriptedLookup(ignoresCancellation: true)
        let model = HostResolveModel(lookup: script.lookup)
        let newer = HostResolveModel.State.found(host: "new.invalid", addresses: ["192.0.2.10"])

        model.resolve("old.invalid")
        model.resolve("new.invalid")
        script.answer("new.invalid", with: .found(["192.0.2.10"]))
        try await pollUntil("the newer lookup's answer lands") { model.state == newer }
        script.answer("old.invalid", with: .found(["198.51.100.7"]))
        await model.settle()

        #expect(model.state == newer)
    }

    /// Cancelling — the control leaving the screen — stops the lookup and
    /// leaves nothing offered.
    @Test func cancellingEndsTheLookupWithNothingOffered() async {
        let form = Self.makeFilledForm(host: "server.invalid")
        let valuesBefore = form.values
        let script = ScriptedLookup()
        let model = HostResolveModel(lookup: script.lookup)

        model.resolve(form.host)
        model.cancel()
        await model.settle()

        #expect(model.state == .idle)
        #expect(form.values == valuesBefore)
    }

    // MARK: - The line under the field

    /// The offer carries the consequences note; each failure its own
    /// message; nothing is said while idle or resolving.
    @Test func eachSettledStateHasItsOwnLineAndTheOthersNone() {
        let offer = HostResolveModel.footnote(
            for: .found(host: "server.invalid", addresses: ["192.0.2.10"]))
        let none = HostResolveModel.footnote(for: .noAddress(host: "server.invalid"))
        let late = HostResolveModel.footnote(for: .noAnswer(host: "server.invalid"))

        #expect(offer != nil && none != nil && late != nil)
        #expect(Set([offer, none, late]).count == 3)
        #expect(HostResolveModel.footnote(for: .idle) == nil)
        #expect(HostResolveModel.footnote(for: .resolving(host: "server.invalid")) == nil)
    }
}

/// A lookup the case answers by hand. Each host gets a stream the lookup
/// waits on; `answer(_:with:)` yields into it. A lookup whose task is
/// cancelled stops waiting — the stream's iteration ends — and answers
/// `.noAnswer`, which the model must drop.
///
/// `ignoresCancellation` makes it deaf to that, like `getaddrinfo`: the wait
/// runs in an unstructured task, which the caller's cancellation does not
/// reach, so the lookup answers only when the case answers it.
private final class ScriptedLookup: Sendable {
    private struct Channel: Sendable {
        let stream: AsyncStream<HostAddresses>
        let continuation: AsyncStream<HostAddresses>.Continuation
    }

    private let channels = Mutex<[String: Channel]>([:])
    private let askedHosts = Mutex<[String]>([])
    private let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    var asked: [String] { askedHosts.withLock { $0 } }

    func answer(_ host: String, with answer: HostAddresses) {
        channel(for: host).continuation.yield(answer)
    }

    var lookup: @Sendable (String) async -> HostAddresses {
        { [self] host in
            askedHosts.withLock { $0.append(host) }
            let stream = channel(for: host).stream
            let wait: @Sendable () async -> HostAddresses = {
                for await answer in stream { return answer }
                return .noAnswer
            }
            return ignoresCancellation ? await Task { await wait() }.value : await wait()
        }
    }

    private func channel(for host: String) -> Channel {
        channels.withLock { channels in
            if let existing = channels[host] { return existing }
            let (stream, continuation) = AsyncStream<HostAddresses>.makeStream()
            let created = Channel(stream: stream, continuation: continuation)
            channels[host] = created
            return created
        }
    }
}
