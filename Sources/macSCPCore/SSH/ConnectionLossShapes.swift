import Citadel
import NIOCore
import NIOSSH

/// The error shapes that mean "the SSH connection or its channel is gone".
///
/// A mid-transfer disconnect does NOT surface as a typed Citadel error:
/// in-flight SFTP requests fail with NIO's `ChannelError.ioOnClosedChannel`
/// (verified via a live kill test against the Docker rig), or with Citadel's
/// `SFTPError.connectionClosed` when the channel closes with pending request
/// promises; NIOSSH signals a dropped transport as `.tcpShutdown`.
/// Deliberately conservative: only these clear connection-loss shapes match —
/// everything else keeps whatever mapping it had.
///
/// Its own type in the SSH layer, rather than a method on
/// `CitadelFileSystem` (fix round 1 of the lost-connection cause work, review
/// Minor 9): two callers read these shapes — `CitadelFileSystem.mapSFTPError`,
/// which turns them into `RemoteFSError.connectionFailed`, and
/// `LivenessProbeFailure.classify(_:)` in the Sessions layer, for
/// an error that reached the probe unmapped. Naming them here keeps the
/// second caller pointed at the shapes rather than at a backend.
///
/// Two questions, not one. `matches(_:)` is the raw transport shapes, and it
/// is what `mapSFTPError` asks — widening it would change which
/// `RemoteFSError` that function produces. `matchesOrWasMapped(_:)` adds what
/// `mapSFTPError` turns those shapes INTO, because by the time the liveness
/// probe sees an error it has usually already been mapped.
enum ConnectionLossShapes {
    static func matches(_ error: any Error) -> Bool {
        switch error {
        case ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed:
            return true
        case SFTPError.connectionClosed:
            return true
        case let error as NIOSSHError where error.type == .tcpShutdown:
            return true
        default:
            return false
        }
    }

    static func matchesOrWasMapped(_ error: any Error) -> Bool {
        if case RemoteFSError.connectionFailed = error { return true }
        return matches(error)
    }
}
