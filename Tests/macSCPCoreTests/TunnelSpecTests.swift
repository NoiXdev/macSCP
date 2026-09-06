import Foundation
import Testing

@testable import macSCPCore

/// `TunnelSpec` — OpenSSH forwarding notation in and out.
///
/// Nothing here names a real host: a spec carries no secret, and a test that
/// puts a plausible host name into an error message invites one to be pasted
/// in later. `db` and `example.invalid` throughout.
@Suite("Tunnel spec")
struct TunnelSpecTests {

    // MARK: - Local (-L)

    @Test(arguments: [
        // The default bind, which is the whole point of leaving it out.
        ("8080:db:5432",
         TunnelProfile.Kind.local(bind: "127.0.0.1", localPort: 8080, host: "db", remotePort: 5432)),
        // An explicit bind is taken as written — including the one the
        // default must NOT be.
        ("0.0.0.0:8080:db:5432",
         TunnelProfile.Kind.local(bind: "0.0.0.0", localPort: 8080, host: "db", remotePort: 5432)),
        // IPv6 binds are bracketed, and the brackets are notation, not part
        // of the address.
        ("[::1]:8080:db:5432",
         TunnelProfile.Kind.local(bind: "::1", localPort: 8080, host: "db", remotePort: 5432)),
        // The destination may be IPv6 too, in the same brackets.
        ("8080:[::1]:5432",
         TunnelProfile.Kind.local(bind: "127.0.0.1", localPort: 8080, host: "::1", remotePort: 5432)),
        // Port 0 on THIS machine's listener is allowed: the listener binds an
        // ephemeral port and reports it back.
        ("0:db:5432",
         TunnelProfile.Kind.local(bind: "127.0.0.1", localPort: 0, host: "db", remotePort: 5432)),
    ])
    func aLocalSpecParses(input: String, expected: TunnelProfile.Kind) throws {
        #expect(try TunnelSpec.parse(local: input) == expected)
    }

    // MARK: - Remote (-R)

    @Test(arguments: [
        ("8080:localhost:5432",
         TunnelProfile.Kind.remote(
            bind: "127.0.0.1", remotePort: 8080, localHost: "localhost", localPort: 5432)),
        ("0.0.0.0:8080:localhost:5432",
         TunnelProfile.Kind.remote(
            bind: "0.0.0.0", remotePort: 8080, localHost: "localhost", localPort: 5432)),
        ("[::1]:8080:localhost:5432",
         TunnelProfile.Kind.remote(
            bind: "::1", remotePort: 8080, localHost: "localhost", localPort: 5432)),
    ])
    func aRemoteSpecParses(input: String, expected: TunnelProfile.Kind) throws {
        #expect(try TunnelSpec.parse(remote: input) == expected)
    }

    // MARK: - Dynamic (-D)

    @Test(arguments: [
        ("1080", TunnelProfile.Kind.dynamic(bind: "127.0.0.1", localPort: 1080)),
        ("0.0.0.0:1080", TunnelProfile.Kind.dynamic(bind: "0.0.0.0", localPort: 1080)),
        ("[::1]:1080", TunnelProfile.Kind.dynamic(bind: "::1", localPort: 1080)),
        ("0", TunnelProfile.Kind.dynamic(bind: "127.0.0.1", localPort: 0)),
    ])
    func aDynamicSpecParses(input: String, expected: TunnelProfile.Kind) throws {
        #expect(try TunnelSpec.parse(dynamic: input) == expected)
    }

    // MARK: - Refusals

    @Test func aPortAboveTheRangeIsRefusedWithItsNumber() {
        #expect(throws: TunnelSpecError.portOutOfRange(70000)) {
            _ = try TunnelSpec.parse(local: "70000:db:1")
        }
        #expect(throws: TunnelSpecError.portOutOfRange(70000)) {
            _ = try TunnelSpec.parse(dynamic: "70000")
        }
    }

    @Test(arguments: [
        // Too few fields for a local forward, and neither of them a port.
        "a:b",
        // A field count no shape has.
        "8080",
        "1:2:3:4:5",
        // An empty destination host.
        "8080::5432",
        // An unclosed bracket is not an address.
        "[::1:8080:db:5432",
        // A port that is not a number.
        "http:db:5432",
    ])
    func aMalformedLocalSpecNamesTheTextItRefused(input: String) {
        #expect(throws: TunnelSpecError.malformed(input)) {
            _ = try TunnelSpec.parse(local: input)
        }
    }

    @Test func aRemoteForwardCannotAskTheServerToChooseThePort() {
        // Port 0 is refused on the SERVER's listener specifically — the
        // client cannot learn the port the server picked, so the forward
        // would look healthy and swallow every connection
        // (`CitadelFileSystem.withRemotePortForward`).
        #expect(throws: TunnelSpecError.remotePortZero) {
            _ = try TunnelSpec.parse(remote: "0:example.invalid:1")
        }
        #expect(throws: TunnelSpecError.remotePortZero) {
            _ = try TunnelSpec.parse(remote: "[::1]:0:example.invalid:1")
        }
    }

    @Test func aLocalAndADynamicSpecStillAcceptPortZero() throws {
        // The counterpart of the refusal above, so the rule cannot be
        // widened into "port 0 is never allowed" without a red test: THIS
        // machine's listener does report the ephemeral port it bound.
        #expect(try TunnelSpec.parse(local: "0:db:5432")
            == .local(bind: "127.0.0.1", localPort: 0, host: "db", remotePort: 5432))
        #expect(try TunnelSpec.parse(dynamic: "0")
            == .dynamic(bind: "127.0.0.1", localPort: 0))
    }

    @Test func everyErrorNamesTheTextItRefused() {
        #expect(TunnelSpecError.malformed("a:b").description.contains("a:b"))
        #expect(TunnelSpecError.portOutOfRange(70000).description.contains("70000"))
        // The remote-port-zero refusal has no offending text but the port,
        // so it must at least say which port and whose listener.
        #expect(TunnelSpecError.remotePortZero.description.contains("0"))
        #expect(TunnelSpecError.remotePortZero.description.contains("server"))
    }

    // MARK: - Rendering

    @Test(arguments: [
        ("8080:db:5432", "127.0.0.1:8080:db:5432"),
        ("0.0.0.0:8080:db:5432", "0.0.0.0:8080:db:5432"),
        ("[::1]:8080:db:5432", "[::1]:8080:db:5432"),
        ("8080:[::1]:5432", "127.0.0.1:8080:[::1]:5432"),
    ])
    func renderingALocalSpecProducesItsCanonicalForm(
        input: String, canonical: String
    ) throws {
        #expect(TunnelSpec.render(try TunnelSpec.parse(local: input)) == canonical)
        // And the canonical form parses back to the same kind, so the pair
        // is a round trip rather than a one-way pretty-printer.
        #expect(try TunnelSpec.parse(local: canonical) == (try TunnelSpec.parse(local: input)))
    }

    @Test(arguments: [
        ("8080:localhost:5432", "127.0.0.1:8080:localhost:5432"),
        ("[::1]:8080:localhost:5432", "[::1]:8080:localhost:5432"),
    ])
    func renderingARemoteSpecProducesItsCanonicalForm(
        input: String, canonical: String
    ) throws {
        #expect(TunnelSpec.render(try TunnelSpec.parse(remote: input)) == canonical)
        #expect(try TunnelSpec.parse(remote: canonical) == (try TunnelSpec.parse(remote: input)))
    }

    @Test(arguments: [
        ("1080", "127.0.0.1:1080"),
        ("[::1]:1080", "[::1]:1080"),
    ])
    func renderingADynamicSpecProducesItsCanonicalForm(
        input: String, canonical: String
    ) throws {
        #expect(TunnelSpec.render(try TunnelSpec.parse(dynamic: input)) == canonical)
        #expect(try TunnelSpec.parse(dynamic: canonical) == (try TunnelSpec.parse(dynamic: input)))
    }
}
