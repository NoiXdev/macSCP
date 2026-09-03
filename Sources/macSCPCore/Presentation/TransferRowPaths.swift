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
/// ## Two renderings of one pair, and why the pair is what is stored
///
/// The paths are stored RAW, with the session each remote side belongs to
/// beside them; `source`/`destination` render the qualified display form on
/// demand and `clipboardText` renders the raw one. Storing the raw pair is
/// what makes the two renderings impossible to disagree — the first version
/// of this type stored only the qualified strings, and its "Copy paths"
/// therefore pasted `/var/www/index.html (on prod-web)`, which is not a
/// path. Every other copy affordance in the tree hands over something that
/// can be pasted into a shell (`ContentView+Transfers.copyPaths(of:)`, the
/// path bar's click-to-copy), and one of them sits in the very next context
/// menu over.
///
/// Neither path is ever rebuilt from `Item.fileName`: that field is a
/// display LABEL, decorated with " →" for a skipped symlink and "/" for an
/// expansion failure. The item carries the real paths, and this reads them.
public struct TransferRowPaths: Equatable, Sendable {
    /// Where the file is read from, unqualified.
    public let rawSource: String
    /// Where it is written, file name included and unqualified — the item's
    /// own `destinationPath`, joined by the engine's own join.
    public let rawDestination: String
    /// The session the SOURCE side lives on, or `nil` when that side is on
    /// this machine (or its tab has no name yet).
    public let sourceSession: String?
    /// The session the DESTINATION side lives on, under the same rule.
    public let destinationSession: String?

    public init(
        rawSource: String, rawDestination: String,
        sourceSession: String?, destinationSession: String?
    ) {
        self.rawSource = rawSource
        self.rawDestination = rawDestination
        self.sourceSession = sourceSession
        self.destinationSession = destinationSession
    }

    /// The source as the row shows it: the path, plus the session it lives
    /// on where there is one to name.
    public var source: String { Self.qualified(rawSource, session: sourceSession) }

    /// The destination as the row shows it, under the same rule — so a
    /// cross-session transfer names both of its ends.
    public var destination: String {
        Self.qualified(rawDestination, session: destinationSession)
    }

    /// What "Copy paths" puts on the pasteboard: one RAW path per line,
    /// source first — the order the row's hint reads in. No session
    /// qualifier: a copied path has to be a path.
    public var clipboardText: String { "\(rawSource)\n\(rawDestination)" }

    /// Folds a queue item into its two paths and the sessions they live on.
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

        // The destination of a cross-session transfer belongs to the target
        // tab, not to the tab whose queue is running it.
        let targetSessionName = item.crossBackendTarget?.name ?? sessionName

        self.init(
            rawSource: item.sourcePath,
            rawDestination: item.destinationPath,
            sourceSession: sourceIsRemote ? Self.named(sessionName) : nil,
            destinationSession: destinationIsRemote ? Self.named(targetSessionName) : nil)
    }

    /// An empty name is treated as no name: it arrives by its own route (a
    /// stored session saved blank) and would otherwise render an empty pair
    /// of brackets. Normalised once, here, so neither renderer has to ask.
    private static func named(_ session: String?) -> String? {
        guard let session, !session.isEmpty else { return nil }
        return session
    }

    /// A path with the session it lives on, or the bare path when there is
    /// none to name — a local file, or a tab that has not been named yet.
    private static func qualified(_ path: String, session: String?) -> String {
        guard let session else { return path }
        return String(
            format: CoreL10n.string("core.transfer.pathOnSession %1$@ %2$@"), path, session)
    }
}
