import Foundation

public struct ComparisonRow: Equatable, Sendable {
    public let relativePath: String
    public let state: ComparisonState

    public init(relativePath: String, state: ComparisonState) {
        self.relativePath = relativePath
        self.state = state
    }
}

public struct ComparisonProgress: Equatable, Sendable {
    public let directoriesVisited: Int
    public let rowsProduced: Int

    public init(directoriesVisited: Int, rowsProduced: Int) {
        self.directoriesVisited = directoriesVisited
        self.rowsProduced = rowsProduced
    }
}

public enum FolderComparison {
    /// Walks both sides breadth-first, pairing each directory level and
    /// classifying every pair.
    ///
    /// `Task.checkCancellation()` is called before each directory is listed
    /// and before each pair is classified, so a cancel stops the network work
    /// rather than only the reporting — a walk that keeps listing after a
    /// cancel costs the user the thing they asked to stop paying.
    ///
    /// A directory present on one side only produces ONE row and is not
    /// descended into: naming every file under it would bury the fact that
    /// the whole directory is missing.
    ///
    /// A directory below the root that cannot be listed, or a pair that
    /// cannot be classified, is one `.undetermined(.unreadable)` row and the
    /// walk goes on: aborting an hour-long comparison over one
    /// permission-denied folder would discard everything else it found. A
    /// cancel is the exception and still ends the walk, as is a failure
    /// listing the root itself.
    ///
    /// `@MainActor` so the two callbacks can be plain closures: they are
    /// invoked across `await` boundaries, and their caller is a main-actor
    /// model whose observable state they drive. The network `await`s suspend
    /// the walk; they do not move it off the actor, and the per-pair
    /// classification below is nonisolated.
    @MainActor
    public static func walk(
        left: any RemoteFileSystem, leftRoot: String,
        right: any RemoteFileSystem, rightRoot: String,
        algorithm: ChecksumAlgorithm,
        onRow: (ComparisonRow) -> Void,
        onProgress: (ComparisonProgress) -> Void
    ) async throws {
        var queue: [String] = [""]
        var directoriesVisited = 0
        var rowsProduced = 0

        while !queue.isEmpty {
            try Task.checkCancellation()
            let relative = queue.removeFirst()
            let leftPath = join(leftRoot, relative)
            let rightPath = join(rightRoot, relative)

            let leftItems: [RemoteFileItem]
            let rightItems: [RemoteFileItem]
            do {
                leftItems = try await left.list(path: leftPath)
                rightItems = try await right.list(path: rightPath)
            } catch {
                try propagateCancellation(error)
                // The root is the folder pair the user chose; with either side
                // unreadable there is nothing to compare.
                if relative.isEmpty { throw error }
                // Below the root, a directory nobody could read is one row and
                // is not descended into; the rest of the tree is still worth
                // having, and the row names the path.
                directoriesVisited += 1
                onRow(ComparisonRow(relativePath: relative, state: .undetermined(.unreadable)))
                rowsProduced += 1
                onProgress(ComparisonProgress(
                    directoriesVisited: directoriesVisited, rowsProduced: rowsProduced))
                continue
            }
            directoriesVisited += 1

            for pair in ComparisonPairing.pairs(left: leftItems, right: rightItems) {
                try Task.checkCancellation()
                let childRelative = relative.isEmpty ? pair.name : relative + "/" + pair.name
                let state: ComparisonState
                do {
                    state = try await classify(
                        pair, left: left, right: right, algorithm: algorithm)
                } catch {
                    try propagateCancellation(error)
                    // A failed fetch fails this one pair, not the comparison.
                    state = .undetermined(.unreadable)
                }

                // `.bothDirectories`, never `.same`: a directory pair is not
                // content anybody measured, and `ComparisonState` gave it its
                // own case precisely so this branch cannot be written against
                // a state that also means "two files compared and matched".
                if state == .bothDirectories {
                    queue.append(childRelative)
                    continue
                }
                onRow(ComparisonRow(relativePath: childRelative, state: state))
                rowsProduced += 1
            }

            onProgress(ComparisonProgress(
                directoriesVisited: directoriesVisited, rowsProduced: rowsProduced))
        }
    }

    /// Rethrows when `error` is a cancel, and returns for anything else.
    ///
    /// Called first in every `catch` above, because a blanket catch would turn
    /// a cancel into a tree of `.unreadable` rows and the walk would run to
    /// completion: the failure the per-directory and per-pair checks exist to
    /// prevent, arriving through the error path. Two tests, not one: a
    /// `CancellationError` is a cancel, and so is ANY error a backend throws
    /// while this task is cancelled (a cancelled URL session reports
    /// `URLError.cancelled`, a socket reports its own), which is why the task
    /// is asked as well as the error.
    private static func propagateCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }

    /// `RemotePath.join`, not a bare `root + "/" + relative`: a root of "/"
    /// would otherwise produce "//sub", a path no backend is promised to
    /// accept.
    private static func join(_ root: String, _ relative: String) -> String {
        relative.isEmpty ? root : RemotePath.join(root, relative)
    }

    /// One retry, at the pair level, for the ordinary local↔S3 case.
    ///
    /// An object store answers from its ETag, which is always MD5, while the
    /// other side computes whatever the user chose — normally SHA-256. Every
    /// equal-size pair would therefore come back `.algorithmsDiffer`: honest,
    /// and useless on one of the three backends. So a pair that lands there
    /// is classified once more with `.md5` on BOTH sides.
    ///
    /// Why the retry sits here and not inside the closures: the closures are
    /// deliberately lazy, because `state` calls them only when the sizes are
    /// equal, and that laziness is the whole saving of the design. Resolving
    /// both checksums up front to negotiate between them would hash every
    /// file in the tree. Retrying the classification is symmetric — it does
    /// not matter which side held the ETag — and it costs nothing on the
    /// pairs that never reach it.
    ///
    /// A single-part ETag IS the file's MD5, so this retry is sound. A
    /// MULTIPART ETag is not, and it is refused by `ComparisonClassification`
    /// before any algorithm is compared, so the retry can never reach one.
    private static func classify(
        _ pair: ComparisonPair,
        left: any RemoteFileSystem, right: any RemoteFileSystem,
        algorithm: ChecksumAlgorithm
    ) async throws -> ComparisonState {
        let first = try await ComparisonClassification.state(
            for: pair,
            leftChecksum: { try await checksum(of: pair.left, on: left, algorithm: algorithm) },
            rightChecksum: { try await checksum(of: pair.right, on: right, algorithm: algorithm) })

        guard first == .undetermined(.algorithmsDiffer), algorithm != .md5 else { return first }

        return try await ComparisonClassification.state(
            for: pair,
            leftChecksum: { try await checksum(of: pair.left, on: left, algorithm: .md5) },
            rightChecksum: { try await checksum(of: pair.right, on: right, algorithm: .md5) })
    }

    /// `RemoteFileSystem` does NOT inherit `RemoteChecksumProvider` — it is
    /// declared `public protocol RemoteFileSystem: Sendable`, and the
    /// checksum lives on its own protocol. This is the conditional cast
    /// `RemoteBrowserViewModel.checksum(of:algorithm:)` already uses, with
    /// the same answer when it fails: a backend that cannot be asked is a
    /// backend that answered "not on this connection".
    private static func checksum(
        of item: RemoteFileItem?, on fs: any RemoteFileSystem,
        algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        guard let item, item.kind == .file else { return .unavailableOnThisConnection }
        guard let provider = fs as? any RemoteChecksumProvider else {
            return .unavailableOnThisConnection
        }
        return try await provider.remoteChecksum(forFileAt: item.path, algorithm: algorithm)
    }
}
