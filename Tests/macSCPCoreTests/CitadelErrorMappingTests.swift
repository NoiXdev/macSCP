import Citadel
import Foundation
import NIOCore
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
