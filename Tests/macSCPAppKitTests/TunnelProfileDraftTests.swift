import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// What the profile sheet's form accepts, as a value (port-forwarding plan,
/// Task 6).
///
/// The sheet itself renders no decision: the draft below is what turns eight
/// text fields into a `TunnelProfile.Kind` or a refusal, which is why the
/// rules the design states — "port 1–65535, host non-empty for local/remote"
/// — are measured here rather than read out of a view body.
///
/// The round trip in `anExistingProfileEditsBackToItself` is the half that
/// keeps the two directions from drifting: a form that renders a profile
/// into fields it cannot read back would lose a value on every edit.
@Suite("Tunnel profile draft")
struct TunnelProfileDraftTests {

    private static func draft(
        name: String = "web", kind: TunnelProfileDraft.KindTag = .local,
        bind: String = "127.0.0.1", listenPort: String = "8080",
        targetHost: String = "internal", targetPort: String = "80"
    ) -> TunnelProfileDraft {
        var draft = TunnelProfileDraft()
        draft.name = name
        draft.kindTag = kind
        draft.bind = bind
        draft.listenPort = listenPort
        draft.targetHost = targetHost
        draft.targetPort = targetPort
        return draft
    }

    private static let sessionID = UUID()

    // MARK: - What it builds

    @Test func aLocalDraftBecomesALocalForward() throws {
        let profile = try Self.draft().profile(id: UUID(), sessionID: Self.sessionID).get()
        #expect(profile.kind == .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80))
        #expect(profile.sessionID == Self.sessionID)
        #expect(profile.name == "web")
    }

    /// The listen port is the SERVER's for a remote forward, and the target
    /// is on this Mac — the one place the two halves of the form change
    /// sides.
    @Test func aRemoteDraftListensOnTheServer() throws {
        let draft = Self.draft(kind: .remote, listenPort: "9000", targetHost: "127.0.0.1", targetPort: "5900")
        let profile = try draft.profile(id: UUID(), sessionID: Self.sessionID).get()
        #expect(profile.kind == .remote(bind: "127.0.0.1", remotePort: 9000, localHost: "127.0.0.1", localPort: 5900))
    }

    /// A SOCKS5 forward's destination is negotiated per connection, so the
    /// target fields are not read at all — a blank pair is valid here and
    /// invalid for the other two kinds.
    @Test func aDynamicDraftNeedsNoTarget() throws {
        let draft = Self.draft(kind: .dynamic, listenPort: "1080", targetHost: "", targetPort: "")
        let profile = try draft.profile(id: UUID(), sessionID: Self.sessionID).get()
        #expect(profile.kind == .dynamic(bind: "127.0.0.1", localPort: 1080))
    }

    /// A blank bind address means the loopback default the design names, not
    /// a refusal: the field is a narrowing, and leaving it empty asks for the
    /// safe answer rather than for every interface.
    @Test func aBlankBindMeansLoopback() throws {
        let profile = try Self.draft(bind: "  ").profile(id: UUID(), sessionID: Self.sessionID).get()
        #expect(profile.kind == .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80))
    }

    // MARK: - What it refuses

    @Test func aProfileNeedsAName() {
        let outcome = Self.draft(name: "   ").profile(id: UUID(), sessionID: Self.sessionID)
        #expect(outcome == .failure(.nameEmpty))
    }

    @Test func theListenPortMustBeAPortNumber() {
        for port in ["0", "65536", "-1", "http", ""] {
            let outcome = Self.draft(listenPort: port).profile(id: UUID(), sessionID: Self.sessionID)
            #expect(
                outcome == .failure(.listenPortInvalid),
                "\"\(port)\" was accepted as a listening port")
        }
    }

    @Test func theTargetOfALocalOrRemoteForwardMustBeNamed() {
        #expect(
            Self.draft(targetHost: " ").profile(id: UUID(), sessionID: Self.sessionID)
                == .failure(.targetHostEmpty))
        #expect(
            Self.draft(kind: .remote, targetHost: "").profile(id: UUID(), sessionID: Self.sessionID)
                == .failure(.targetHostEmpty))
        #expect(
            Self.draft(targetPort: "70000").profile(id: UUID(), sessionID: Self.sessionID)
                == .failure(.targetPortInvalid))
    }

    // MARK: - The round trip

    @Test func anExistingProfileEditsBackToItself() throws {
        let kinds: [TunnelProfile.Kind] = [
            .local(bind: "0.0.0.0", localPort: 8080, host: "internal", remotePort: 80),
            .remote(bind: "127.0.0.1", remotePort: 9000, localHost: "localhost", localPort: 5900),
            .dynamic(bind: "127.0.0.1", localPort: 1080),
        ]
        for kind in kinds {
            let original = TunnelProfile(
                sessionID: Self.sessionID, name: "round trip", kind: kind,
                autoStart: .appStart, reconnects: true)
            let rebuilt = try TunnelProfileDraft(profile: original)
                .profile(id: original.id, sessionID: original.sessionID).get()
            #expect(rebuilt == original)
        }
    }
}
