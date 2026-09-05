import Citadel
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import macSCPCore

/// Unit tests for the CitadelFileSystem SFTP error mapping (no server needed).
///
/// M5d regression: a mid-transfer disconnect surfaces from NIO as
/// `ChannelError.ioOnClosedChannel` (and from Citadel as
/// `SFTPError.connectionClosed`), NOT as a `RemoteFSError.connectionFailed`.
/// Without mapping these to `connectionFailed`, the transfer queue classifies
/// the item as `.failed` (red) instead of `.interrupted` (resumable).
@Suite("CitadelFileSystem error mapping")
struct CitadelErrorMappingTests {
    /// Unwraps the mapped error as RemoteFSError or records a failure.
    private func mapped(_ error: Error) -> RemoteFSError? {
        let result = CitadelFileSystem.mapSFTPError(error, path: "/remote/file.bin")
        guard let fsError = result as? RemoteFSError else {
            Issue.record("expected RemoteFSError, got \(result)")
            return nil
        }
        return fsError
    }

    @Test("ChannelError.ioOnClosedChannel maps to connectionFailed")
    func ioOnClosedChannelIsConnectionFailure() {
        let fsError = mapped(ChannelError.ioOnClosedChannel)
        #expect(fsError?.isConnectionFailure == true)
    }

    @Test("ChannelError.alreadyClosed maps to connectionFailed")
    func alreadyClosedChannelIsConnectionFailure() {
        let fsError = mapped(ChannelError.alreadyClosed)
        #expect(fsError?.isConnectionFailure == true)
    }

    @Test("SFTPError.connectionClosed maps to connectionFailed")
    func sftpConnectionClosedIsConnectionFailure() {
        let fsError = mapped(SFTPError.connectionClosed)
        #expect(fsError?.isConnectionFailure == true)
    }

    @Test("other ChannelError cases stay protocolError")
    func otherChannelErrorStaysProtocolError() {
        let fsError = mapped(ChannelError.operationUnsupported)
        #expect(fsError?.isConnectionFailure == false)
        if case .protocolError = fsError {} else {
            Issue.record("expected protocolError, got \(String(describing: fsError))")
        }
    }

    @Test("other SFTP errors stay protocolError")
    func otherSFTPErrorStaysProtocolError() {
        let fsError = mapped(SFTPError.invalidResponse)
        #expect(fsError?.isConnectionFailure == false)
        if case .protocolError = fsError {} else {
            Issue.record("expected protocolError, got \(String(describing: fsError))")
        }
    }

    @Test("unknown errors stay protocolError")
    func unknownErrorStaysProtocolError() {
        struct DummyError: Error {}
        let fsError = mapped(DummyError())
        #expect(fsError?.isConnectionFailure == false)
        if case .protocolError = fsError {} else {
            Issue.record("expected protocolError, got \(String(describing: fsError))")
        }
    }
}

/// The connect-time mappers (`mapConnectError`, `mapStageAware`) build a
/// `RemoteFSError.connectionFailed`'s free text out of a foreign error, and
/// this suite pins what that text may carry: the error's
/// `localizedDescription` — or, for a `NIOSSHError`, its type name alone —
/// and never the stored properties `String(describing:)` prints. The same
/// rule `mapSFTPError` has followed since the diagnostic-log plan's Task 3
/// fix round 1, applied to the sites that round flagged and left.
///
/// The planted value lives in a named constant, and every check computes its
/// `Bool` BEFORE the expectation (CLAUDE.md, "A value a test must not leak
/// has two exits"): `#expect` prints the source text of what it checks, so a
/// literal in the expectation would leak through the failure message that
/// appears exactly when someone is looking.
@Suite("CitadelFileSystem connect error mapping")
struct CitadelConnectErrorMappingTests {
    /// A foreign error the way a transport library writes one: a stored
    /// property carrying the configuration it was dialling with. Its
    /// `localizedDescription` is Foundation's generic sentence, which names
    /// the type and a code and nothing the value holds; its description is
    /// the stored property, verbatim.
    private struct DialError: Error {
        let endpoint: String
    }

    private static let secret = "sentinel-jump-secret-3a9f"

    private static var plantedDialError: DialError {
        DialError(endpoint: "ssh://user:\(secret)@host.example")
    }

    /// Unwraps the mapped error's reason or records a failure.
    private func connectionFailedReason(of error: Error) -> String? {
        guard case RemoteFSError.connectionFailed(let reason) = error else {
            Issue.record("expected connectionFailed, got \(type(of: error))")
            return nil
        }
        return reason
    }

    /// The positive beside every negative below (CLAUDE.md, "Guards that
    /// name what they watch"): the fixture WOULD leak under the spelling the
    /// mappers used to have. Without this, "the reason carries no secret"
    /// would also hold for a fixture that never carried one.
    @Test("the fixture's description carries the planted value")
    func theFixtureWouldLeakWhenDescribed() {
        let describedLeaks = String(describing: Self.plantedDialError).contains(Self.secret)
        #expect(describedLeaks == true)
    }

    @Test("a target-hop transport error reaches connectionFailed without its stored properties")
    func targetHopReasonCarriesNoStoredProperty() {
        let mapped = CitadelFileSystem.mapConnectError(Self.plantedDialError)
        guard let reason = connectionFailedReason(of: mapped) else { return }
        let leaked = reason.contains(Self.secret)
        #expect(leaked == false)
        #expect(!reason.isEmpty)
    }

    @Test("a jump-hop transport error is attributed to the jump host, without its stored properties")
    func jumpHopReasonCarriesNoStoredProperty() {
        let mapped = CitadelFileSystem.mapStageAware(
            CitadelFileSystem.JumpStageError(underlying: Self.plantedDialError))
        guard let reason = connectionFailedReason(of: mapped) else { return }
        #expect(reason.hasPrefix("jump host: "))
        let leaked = reason.contains(Self.secret)
        #expect(leaked == false)
    }

    /// The `SSHClientError` arm of `mapStageAware` is a separate `default:`
    /// from the one above — a Citadel client error that is not the auth
    /// refusal keeps the jump attribution and goes through the same text
    /// rule. `SSHClientError` has no stored properties, so only the shape is
    /// pinned here; the secrecy half is the two tests above.
    @Test("a jump-hop client error other than an auth refusal is attributed to the jump host")
    func jumpHopClientErrorKeepsTheJumpAttribution() {
        let mapped = CitadelFileSystem.mapStageAware(
            CitadelFileSystem.JumpStageError(underlying: SSHClientError.channelCreationFailed))
        guard let reason = connectionFailedReason(of: mapped) else { return }
        #expect(reason.hasPrefix("jump host: "))
        #expect(reason.count > "jump host: ".count)
    }

    /// `ConnectionViewModel.failedState` recognises a jump host refusing the
    /// tunnel by the substring `channelSetupRejected` in a
    /// `connectionFailed` reason. `localizedDescription` on a `NIOSSHError`
    /// is Foundation's generic sentence — the type adopts neither
    /// `LocalizedError` nor a description Foundation reads — so
    /// `connectFailureText(for:)` renders a `NIOSSHError` as its `type`
    /// instead, a closed enumeration whose description is the case name.
    /// `NIOSSHError` has no public initializer, so the mapper's arm itself is
    /// read, not measured; what IS measured is the rendering that arm relies
    /// on staying the name the view model matches.
    @Test("the jump tunnel refusal's type renders as the name the connect form matches")
    func channelSetupRejectedRendersAsItsName() {
        #expect(NIOSSHError.ErrorType.channelSetupRejected.description == "channelSetupRejected")
    }
}
