import Foundation

/// The full source and destination a transfer row can show on demand.
///
/// A row has space for a file name and a direction arrow, which is enough
/// to recognise a transfer and not enough to identify one: two tabs
/// uploading `config.yml` produce two identical rows. This is the fold from
/// a queue item to the two paths that tell them apart.
///
/// It lives in Core rather than in the bar because the decision it makes is
/// not a layout decision. Which SIDE of a transfer is on this machine
/// follows from the queue's own model — `direction` says which side is
/// remote, and `crossRemote` is what distinguishes a remote→remote transfer
/// (enqueued as an `.upload`, because the target-write side is what the tab
/// indicator reflects) from an upload of a local file. A view deriving that
/// for itself would be a second copy of a rule the queue already owns.
///
/// Both strings are for DISPLAY: a remote path is qualified with the name
/// of the session it belongs to, so a cross-session transfer names both of
/// its ends. That qualification is also what `clipboardText` copies — the
/// row shows qualified paths, and a copy that quietly differed from the
/// display would be the more surprising of the two.
public struct TransferRowPaths: Equatable, Sendable {
    /// Where the file is read from.
    public let source: String
    /// Where it is written, file name included — joined exactly the way
    /// `TransferEngine.copyFile` joins it, so the row shows the path the
    /// transfer actually writes.
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }

    /// What "Copy paths" puts on the pasteboard: one path per line, source
    /// first — the order the row's hint reads in.
    public var clipboardText: String { "\(source)\n\(destination)" }

    /// Folds a queue item into its two display paths.
    ///
    /// - Parameters:
    ///   - item: the row's item.
    ///   - sessionName: the display name of the session that owns this
    ///     queue — the tab's `titleName`, which is `nil` before a tab has
    ///     connected. Every remote side of the transfer belongs to it
    ///     EXCEPT a cross-backend destination, which names its own target.
    ///     `nil` (or empty) qualifies nothing rather than inventing a
    ///     placeholder.
    public init(item: TransferQueueViewModel.Item, sessionName: String?) {
        // `.download` is the only direction that writes to this machine;
        // every other item writes to a remote. On the source side the
        // question needs `crossRemote` as well: a remote→remote transfer is
        // an `.upload` whose source is another machine's file.
        let sourceIsRemote = item.direction == .download || item.crossRemote
        let destinationIsRemote = item.direction != .download

        let destinationPath = RemotePath.join(item.destinationDirectory, item.fileName)
        // The destination of a cross-session transfer belongs to the target
        // tab, not to the tab whose queue is running it.
        let destinationSession = item.crossBackendTarget?.name ?? sessionName

        self.init(
            source: Self.qualified(
                item.sourcePath, session: sourceIsRemote ? sessionName : nil),
            destination: Self.qualified(
                destinationPath, session: destinationIsRemote ? destinationSession : nil))
    }

    /// A path with the session it lives on, or the bare path when there is
    /// no session to name — a local file, or a tab that has not been named
    /// yet. An empty name is treated as no name: it arrives by its own
    /// route (a stored session saved blank) and would otherwise render an
    /// empty pair of brackets.
    private static func qualified(_ path: String, session: String?) -> String {
        guard let session, !session.isEmpty else { return path }
        return String(
            format: CoreL10n.string("core.transfer.pathOnSession %1$@ %2$@"), path, session)
    }
}
