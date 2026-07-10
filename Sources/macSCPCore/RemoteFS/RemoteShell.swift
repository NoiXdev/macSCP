import Foundation

/// An interactive remote shell (PTY). Lives on top of an existing
/// connection; `close()` ends only the shell, never the connection.
public protocol RemoteShell: AnyObject, Sendable {
    /// Byte chunks of the shell's output. Ends normally when the shell
    /// closes; throws if the shell or connection fails. Exactly ONE consumer.
    var output: AsyncThrowingStream<[UInt8], Error> { get }
    /// Writes raw input bytes (keyboard) to the shell.
    func send(_ bytes: [UInt8]) async throws
    /// Reports a new terminal size (SSH window-change).
    func resize(cols: Int, rows: Int) async throws
    /// Closes the shell. Idempotent; returns only once the channel is closed.
    func close() async
}

/// The capability to open shells over an existing connection. The UI queries
/// it via `as?` on the remote file system (LocalFileSystem doesn't have it).
public protocol RemoteShellProvider: AnyObject {
    /// Opens a PTY shell (TERM=`terminal`) with an initial size.
    func openShell(terminal: String, cols: Int, rows: Int) async throws -> any RemoteShell
}
