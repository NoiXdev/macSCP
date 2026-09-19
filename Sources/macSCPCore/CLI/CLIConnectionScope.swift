import Foundation

/// What the command line does with one connection: runs a subcommand's body
/// against it, then — on every exit path, the body returning (an early
/// `return` inside it included) or throwing — settles what the connection
/// still has running and disconnects it.
///
/// What it can still have running is an S3 multipart abort (final review I1
/// of the 2026-09-19 plan). A failed upload throws the moment its abort is
/// launched, and this process exits right after a subcommand's `run()`
/// returns — taking an abort still running with it, and leaving an
/// incomplete upload behind that the account is billed for. So the scope
/// waits for the connection's pending aborts first, each under the
/// uploader's own bound (`S3Uploader.abortBoundSeconds`), and hands the
/// object key of each one that did not confirm to `noteUnconfirmedAbort`.
///
/// Lives in Core, not beside `withConnection` in the command-line target,
/// because that target has no test target; `withConnection` dials and hands
/// the connection here.
public enum CLIConnectionScope {
    public static func run(
        _ fs: any RemoteFileSystem,
        noteUnconfirmedAbort: (_ objectKey: String) -> Void,
        _ body: (any RemoteFileSystem) async throws -> Void
    ) async throws {
        do {
            try await body(fs)
        } catch {
            await close(fs, noteUnconfirmedAbort: noteUnconfirmedAbort)
            throw error
        }
        await close(fs, noteUnconfirmedAbort: noteUnconfirmedAbort)
    }

    private static func close(
        _ fs: any RemoteFileSystem, noteUnconfirmedAbort: (_ objectKey: String) -> Void
    ) async {
        for objectKey in await fs.awaitUnconfirmedAborts() {
            noteUnconfirmedAbort(objectKey)
        }
        await fs.disconnect()
    }
}
