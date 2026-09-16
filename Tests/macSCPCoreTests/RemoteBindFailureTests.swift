import Foundation
import Testing

@testable import macSCPCore

/// A remote forward the server refuses: the failure is typed with whether
/// the bind needs the server's `GatewayPorts`, and the log keeps the
/// sentence it had — the transport's reason, plus the clause naming
/// `GatewayPorts` for a bind address other than loopback.
@Suite struct RemoteBindFailureTests {
    struct Refused: Error {}

    @Test(arguments: ["0.0.0.0", "192.0.2.10", "::"])
    func aNonLoopbackBindNeedsGatewayPortsAndSaysSo(bind: String) {
        let error = Refused()
        let failure = CitadelFileSystem.remoteBindFailure(for: error, bind: bind)
        #expect(
            failure
                == .remoteBindRefused(
                    reason: DialSupport.reason(for: error), needsGatewayPorts: true))
        #expect(
            DialSupport.reason(for: failure)
                == DialSupport.reason(for: error)
                + " (a bind address other than loopback needs the server's GatewayPorts)")
        #expect(DialSupport.failureKind(for: failure) == .remoteBindRefused(needsGatewayPorts: true))
    }

    @Test(arguments: ["127.0.0.1", "::1", "localhost"])
    func aLoopbackBindDoesNotNeedGatewayPorts(bind: String) {
        let error = Refused()
        let failure = CitadelFileSystem.remoteBindFailure(for: error, bind: bind)
        #expect(
            failure
                == .remoteBindRefused(
                    reason: DialSupport.reason(for: error), needsGatewayPorts: false))
        #expect(DialSupport.reason(for: failure) == DialSupport.reason(for: error))
    }
}
