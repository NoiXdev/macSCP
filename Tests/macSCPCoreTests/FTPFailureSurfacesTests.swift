import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The other places a raw `FTPConnectionFailure` is rendered or classified,
/// beside `DialSupport` (which `FTPFailureRenderingTests` holds): the transfer
/// queue's status, the browser's banner, and the two FTP boundaries that decide
/// whether a failure stays itself or becomes a `RemoteFSError`.
///
/// The queue and the browser each carry their own `switch` over the error, and
/// neither goes through `DialSupport` (measured in the Task 8 review: the only
/// reader of `FTPConnectionFailure` outside the FTP folder was
/// `DialProbes.swift`). A raw failure reaching either fell to a `default:` arm
/// and read as the bridged case index. These cases hold the UI half: a
/// failure's sentence is the CATALOGUE `message`, in the user's language, and
/// its classification is the one the dial mapper gives it.
@Suite("FTP failures on the queue, the browser and the boundaries", .timeLimit(.minutes(5)))
@MainActor
struct FTPFailureSurfacesTests {
    // MARK: - The transfer queue

    /// What the queue's status says for each failure. Derived from the dial
    /// mapper's table (`FTPFailureRenderingTests.expectedKinds`) by one rule,
    /// written here as a statement: a refused login is the queue's
    /// `authenticationFailed`; a failure that ended or refused the connection
    /// is `connectionFailed` with the catalogue sentence as its detail; a
    /// server answer this client cannot use is `protocolError` with the same;
    /// a local guard is `unknown` with the same.
    private static func expectedQueueKind(_ kind: FTPConnectionFailure.Kind) -> TransferFailureKind? {
        let message = FTPFailureRenderingTests.failure(of: kind).message
        switch FTPFailureRenderingTests.expectedKinds[kind] {
        case .authenticationFailed: return .authenticationFailed
        case .connectionFailed: return .connectionFailed(detail: message)
        case .serverAnswerUnusable: return .protocolError(detail: message)
        case .unknown: return .unknown(detail: message)
        default: return nil
        }
    }

    @Test(arguments: FTPConnectionFailure.Kind.allCases)
    func theQueueClassifiesAnFTPFailureAndRendersItsCatalogueSentence(
        _ kind: FTPConnectionFailure.Kind
    ) throws {
        let failure = FTPFailureRenderingTests.failure(of: kind)
        let expected = try #require(Self.expectedQueueKind(kind))
        let classified = TransferQueueViewModel.failureKind(for: failure)
        #expect(classified == expected)

        let rendered = TransferQueueViewModel.message(for: failure)
        let bridged = (failure as NSError).localizedDescription
        let carriesTheBridge = rendered.contains(bridged)
        let carriesItsSentence = rendered.contains(failure.message)
        #expect(carriesTheBridge == false, "\(kind) renders as the bridged case index")
        // A login the server refused has the queue's own authentication
        // sentence instead, which is not the FTP catalogue's.
        if expected != .authenticationFailed {
            #expect(carriesItsSentence, "\(kind) does not render its catalogue sentence")
        }
    }

    // MARK: - The browser banner

    @Test(arguments: FTPConnectionFailure.Kind.allCases)
    func theBrowserBannerSaysWhatKindOfFailureAnFTPFailureWasInItsOwnFrame(
        _ kind: FTPConnectionFailure.Kind
    ) throws {
        let failure = FTPFailureRenderingTests.failure(of: kind)
        let expectedKind = try #require(FTPFailureRenderingTests.expectedKinds[kind])
        let frame: String
        let argument: String
        switch expectedKind {
        case .authenticationFailed:
            frame = "core.error.permissionDenied %@"
            argument = "/pub"
        case .connectionFailed:
            frame = "core.error.connectionLost %@"
            argument = failure.message
        case .serverAnswerUnusable:
            frame = "core.browse.protocolError %@"
            argument = failure.message
        default:
            frame = "core.error.unexpected %@"
            argument = failure.message
        }
        let expected = String(format: CoreL10n.string(frame), argument)
        #expect(RemoteBrowserViewModel.message(for: failure, path: "/pub") == expected)
        // Positive: the frame is looked up, not left as its own key.
        #expect(CoreL10n.string(frame) != frame)
    }

    // MARK: - The two FTP boundaries

    /// A refused login at the dial is an authentication failure, as it is on
    /// S3 (`S3FileSystem` maps its 403 to `.authenticationFailed`). It was
    /// flattened to `connectionFailed(reason:)`, which lost the identity the
    /// form, the audit log and the diagnostics classify by.
    @Test func aRefusedLoginAtConnectIsAnAuthenticationFailure() async throws {
        let server = LoopbackFTPServer(
            security: .plain, advertisesMLSD: true, requiresTLSSessionReuse: false)
        let endpoint = try await server.start()
        let outcome: Result<Void, any Error>
        do {
            let fs = try await FTPFileSystem.connect(
                FTPConnectionConfig(
                    host: endpoint.host, port: endpoint.port,
                    username: "user-\(UUID().uuidString.prefix(8))", security: .plain,
                    password: "wrong-\(UUID().uuidString)"),
                transferSlots: 1, certificateDecider: .refusing, timeout: .seconds(30),
                trustStore: nil)
            await fs.disconnect()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await server.stop()

        guard case .failure(let error) = outcome else {
            Issue.record("a wrong password connected")
            return
        }
        let isAuthentication: Bool
        if case RemoteFSError.authenticationFailed = error { isAuthentication = true } else { isAuthentication = false }
        #expect(isAuthentication, "a refused login did not arrive as authenticationFailed")
    }

    /// The same identity at the transfer boundary, where it is a latent trap
    /// rather than a live path: wrapped as `connectionFailed`,
    /// `isConnectionFailure` answers `true` and the queue would resume a
    /// transfer a password will never let through. Today the only login during
    /// a transfer is inside the lease acquire, outside this wrap
    /// (`FTPFileSystem.readStream`/`write`), so it is unreachable; the case
    /// holds the mapping for whoever moves the acquire.
    ///
    /// `leavesConnectionInStep` is NOT part of the fix and is held where it
    /// was: it governs the pool's reuse decision, and a refused login is still
    /// a connection nothing has established the state of.
    @Test func aRefusedLoginDuringATransferIsNotResumable() {
        let wrapped = FTPFileSystem.transferFailure(FTPConnectionFailure.loginRefused, path: "/a")
        let isAuthentication: Bool
        if case RemoteFSError.authenticationFailed = wrapped { isAuthentication = true } else { isAuthentication = false }
        #expect(isAuthentication)
        let resumable = (wrapped as? RemoteFSError)?.isConnectionFailure ?? false
        #expect(resumable == false)

        // The positive beside it: a dropped connection IS wrapped as one the
        // queue resumes, so the false above is about the login and not about
        // the helper never classifying anything.
        let dropped = FTPFileSystem.transferFailure(FTPConnectionFailure.connectionClosed, path: "/a")
        #expect((dropped as? RemoteFSError)?.isConnectionFailure == true)

        // And the pool's reuse decision is where it was.
        #expect(FTPConnectionFailure.loginRefused.leavesConnectionInStep == false)
    }
}
