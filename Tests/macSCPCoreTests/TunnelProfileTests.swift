import Foundation
import Testing
@testable import macSCPCore

@Suite("TunnelProfile")
struct TunnelProfileTests {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func roundtrip(_ profile: TunnelProfile) throws -> TunnelProfile {
        let data = try JSONEncoder().encode(profile)
        return try JSONDecoder().decode(TunnelProfile.self, from: data)
    }

    @Test func localKindRoundtrips() throws {
        let profile = TunnelProfile(
            sessionID: sessionID, name: "web",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80))
        #expect(try roundtrip(profile) == profile)
    }

    @Test func remoteKindRoundtrips() throws {
        let profile = TunnelProfile(
            sessionID: sessionID, name: "reverse",
            kind: .remote(bind: "127.0.0.1", remotePort: 9090, localHost: "127.0.0.1", localPort: 3000))
        #expect(try roundtrip(profile) == profile)
    }

    @Test func dynamicKindRoundtrips() throws {
        let profile = TunnelProfile(
            sessionID: sessionID, name: "socks", kind: .dynamic(bind: "127.0.0.1", localPort: 1080))
        #expect(try roundtrip(profile) == profile)
    }

    @Test func autoStartAndReconnectsRoundtrip() throws {
        let profile = TunnelProfile(
            sessionID: sessionID, name: "auto",
            kind: .dynamic(bind: "127.0.0.1", localPort: 1080),
            autoStart: .appStart, reconnects: true)
        let decoded = try roundtrip(profile)
        #expect(decoded.autoStart == .appStart)
        #expect(decoded.reconnects == true)
    }

    /// `AutoStart`'s raw values, pinned: `tunnels.json` stores these as
    /// plain strings, so a rename here is a silent format break unless a
    /// test names the exact spelling on file today.
    @Test func autoStartRawValues() {
        #expect(TunnelProfile.AutoStart.off.rawValue == "off")
        #expect(TunnelProfile.AutoStart.appStart.rawValue == "appStart")
        #expect(TunnelProfile.AutoStart.login.rawValue == "login")
        #expect(TunnelProfile.AutoStart.allCases == [.off, .appStart, .login])
    }

    /// The JSON shape for one profile of each kind, pinned as a string
    /// fixture: the compiler-synthesized `Codable` for `Kind` (an
    /// enum-with-associated-values, every case fully labeled) encodes as a
    /// single-key object keyed by the case name, its payload a NESTED
    /// keyed object — one key per parameter label, not an array — sorted
    /// alphabetically here only because the encoder is asked to
    /// (`.sortedKeys`); the labels themselves come from `Kind.local`'s own
    /// declaration. A change to `Kind`'s shape — renaming a case, renaming
    /// or dropping a parameter label — changes this fixture, which is the
    /// point: it makes the format change a decision a diff shows, not a
    /// silent break nobody reviews.
    @Test func localKindJSONShapeIsPinned() throws {
        let profile = TunnelProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sessionID: sessionID, name: "web",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            autoStart: .off, reconnects: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(profile), as: UTF8.self)
        #expect(
            json == """
            {"autoStart":"off","id":"22222222-2222-2222-2222-222222222222",\
            "kind":{"local":{"bind":"127.0.0.1","host":"internal",\
            "localPort":8080,"remotePort":80}},"name":"web",\
            "reconnects":false,"sessionID":"11111111-1111-1111-1111-111111111111"}
            """)
    }
}
