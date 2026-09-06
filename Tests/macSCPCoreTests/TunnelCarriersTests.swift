import Foundation
import Testing

@testable import macSCPCore

/// `TunnelCarriers` — which connection kinds can carry a forwarding, and
/// what a session that cannot is told.
@Suite("Tunnel carriers")
struct TunnelCarriersTests {

    @Test func onlySSHCarriesAForwarding() {
        // There is no `direct-tcpip` over S3 or WebDAV. Spelled one kind per
        // line rather than derived from `allCases`, because a fourth backend
        // must make someone answer this question rather than inherit an
        // answer from a loop.
        #expect(TunnelCarriers.carries(.ssh))
        #expect(TunnelCarriers.carries(.s3) == false)
        #expect(TunnelCarriers.carries(.webdav) == false)
    }

    @Test func aPlainSSHSessionIsNotRefused() {
        #expect(TunnelCarriers.refusal(for: sshSession(name: "rig")) == nil)
    }

    @Test func anS3SessionIsRefusedForItsProtocol() {
        #expect(TunnelCarriers.refusal(for: s3Session(name: "objects"))
            == "session objects is an S3 session; forwardings need SSH")
    }

    @Test func aWebDAVSessionIsRefusedForItsProtocol() {
        // The second non-SSH kind, and the one that takes the other article:
        // the sentence is built from the backend's own English name, so this
        // is what holds that construction to a readable result.
        #expect(TunnelCarriers.refusal(for: webdavSession(name: "cloud"))
            == "session cloud is a WebDAV session; forwardings need SSH")
    }

    @Test func aLoginSetSessionIsRefused() {
        let session = sshSession(name: "prod", loginSetID: UUID())
        #expect(TunnelCarriers.refusal(for: session)
            == "session prod belongs to a login set; "
            + "forwardings dial with the session's own login")
    }

    @Test func aJumpHostSessionIsRefused() {
        let session = sshSession(
            name: "behind",
            jump: StoredSession.JumpSpec(host: "example.invalid", username: "tim"))
        #expect(TunnelCarriers.refusal(for: session)
            == "session behind uses a jump host; forwardings cannot dial through one")
    }

    @Test func theLoginSetRuleIsAnsweredBeforeTheProtocolRule() {
        // Both are true of this session, and the order is not cosmetic: it is
        // the order `StoredSessionConnectionConfig.build` refuses in, and the
        // dial must not report one rule while the code enforces the other.
        let session = s3Session(name: "objects", loginSetID: UUID())
        #expect(TunnelCarriers.refusal(for: session)
            == "session objects belongs to a login set; "
            + "forwardings dial with the session's own login")
    }
}
