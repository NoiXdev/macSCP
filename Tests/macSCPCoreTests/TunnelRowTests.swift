import Foundation
import Testing
@testable import macSCPCore

/// `TunnelRow` is what `tunnels list --json` prints, one object per line, and
/// those keys are a CONTRACT: a script reads `.session` and `.autostart` out
/// of them, and a renamed property would change the output silently.
///
/// The key set is therefore pinned as LITERAL text here, against
/// `JSONSerialization` rather than against the type — the same reason
/// `TunnelProfileTests.localKindJSONShapeIsPinned` pins the profile's on-disk
/// shape. Both CLI suites that read this output decode INTO `TunnelRow`,
/// which is exactly why they cannot see a rename: encoder and decoder move
/// together, and the round trip stays green while the printed key changes.
@Suite("TunnelRow")
struct TunnelRowTests {
    /// Carries hex LETTERS on purpose: `uuidString` differs from its
    /// lowercased form only on letters, so an all-digit fixture cannot
    /// tell the two apart (found by the round-1 re-review, 2026-09-06).
    private static let profileID = UUID(uuidString: "ABCDEF12-3456-4ABC-8DEF-ABCDEF123456")!
    private static let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static func encoded(_ row: TunnelRow) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(row))
        return try #require(object as? [String: Any], "a row encoded as something else")
    }

    /// The seven keys, spelled out. A renamed property is red here and
    /// nowhere else.
    @Test func theJSONKeysArePinned() throws {
        let object = try Self.encoded(TunnelRow(
            profile: TunnelProfile(
                id: Self.profileID, sessionID: Self.sessionID, name: "db",
                kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
                autoStart: .off, reconnects: false),
            sessionName: "web"))
        #expect(
            Set(object.keys) == ["name", "session", "kind", "spec", "autostart", "reconnect", "id"],
            "tunnels list --json prints \(object.keys.sorted())")
    }

    /// The values behind those keys, including the two spellings the command
    /// line shares with its own flags and the id's exact text.
    ///
    /// `id` is `UUID.uuidString`'s UPPERCASE form — what the store file
    /// holds, so a row's id can be grepped for in `tunnels.json` — and not
    /// `Codable`'s own `UUID` encoding, which would be the same text but
    /// would tie the row to a `UUID` property nobody asked for.
    @Test func theValuesAreTheOnesTheColumnsShow() throws {
        let object = try Self.encoded(TunnelRow(
            profile: TunnelProfile(
                id: Self.profileID, sessionID: Self.sessionID, name: "socks",
                kind: .dynamic(bind: "::1", localPort: 1080),
                autoStart: .appStart, reconnects: true),
            sessionName: "web"))
        #expect(object["name"] as? String == "socks")
        #expect(object["session"] as? String == "web")
        #expect(object["kind"] as? String == "dynamic")
        #expect(object["spec"] as? String == "[::1]:1080")
        // `app-start`, the spelling `--autostart` takes — not the stored raw
        // value `appStart`, which `TunnelProfile`'s own JSON carries.
        #expect(object["autostart"] as? String == "app-start")
        #expect(object["reconnect"] as? Bool == true)
        #expect(object["id"] as? String == "ABCDEF12-3456-4ABC-8DEF-ABCDEF123456")
        #expect(object["id"] as? String != Self.profileID.uuidString.lowercased())
        #expect(object["id"] as? String == Self.profileID.uuidString)
    }

    /// The row a profile makes decodes back into the same row — the property
    /// this suite's key check deliberately does NOT stand in for, kept here
    /// so both are visible side by side.
    @Test func aRowSurvivesTheRoundTrip() throws {
        let row = TunnelRow(
            profile: TunnelProfile(
                id: Self.profileID, sessionID: Self.sessionID, name: "back",
                kind: .remote(bind: "0.0.0.0", remotePort: 9000,
                              localHost: "127.0.0.1", localPort: 3000),
                autoStart: .login, reconnects: false),
            sessionName: "web")
        let decoded = try JSONDecoder().decode(TunnelRow.self, from: try JSONEncoder().encode(row))
        #expect(decoded == row)
    }
}
