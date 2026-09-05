import Foundation
import Testing

@testable import macSCPCore

/// What the browser answers when a checksum is asked for one file — the
/// single place the App layer goes through, so the four backends' four
/// different shapes arrive at one surface.
///
/// The backends themselves are Task 3's; nothing here re-tests them. What
/// is tested is the translation: a capability reached through `as?`, an
/// outcome that is a statement rather than a failure, and an error about
/// ONE file turned into the same localized sentence every other browse
/// action produces.
@Suite("Checksum request")
@MainActor
struct ChecksumRequestTests {
    private static let file = RemoteFileItem(
        name: "iso.img", path: "/iso.img", kind: .file, size: 12)

    // MARK: - Doubles

    /// A file system that answers the checksum question with whatever it
    /// was handed. Only the members the browser touches on this path do
    /// anything; the rest exist because the protocol has them.
    private actor AnsweringFS: RemoteFileSystem, RemoteChecksumProvider {
        enum Answer: Sendable {
            case outcome(RemoteChecksumOutcome)
            case failure(RemoteFSError)
        }
        private let answer: Answer
        private(set) var asked: [(path: String, algorithm: ChecksumAlgorithm)] = []

        init(_ answer: Answer) { self.answer = answer }

        func remoteChecksum(
            forFileAt path: String, algorithm: ChecksumAlgorithm
        ) async throws -> RemoteChecksumOutcome {
            asked.append((path, algorithm))
            switch answer {
            case .outcome(let outcome): return outcome
            case .failure(let error): throw error
            }
        }

        func askedPaths() -> [String] { asked.map(\.path) }
        func askedAlgorithms() -> [ChecksumAlgorithm] { asked.map(\.algorithm) }

        func list(path: String) async throws -> [RemoteFileItem] { [] }
        func stat(path: String) async throws -> RemoteFileItem {
            RemoteFileItem(name: "iso.img", path: "/iso.img", kind: .file, size: 12)
        }
        func readStream(
            path: String, fromOffset offset: UInt64
        ) async throws -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func write(
            path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
        ) async throws {}
        func delete(path: String) async throws {}
        func createDirectory(at path: String) async throws {}
        func rename(from: String, to: String) async throws {}
        func setPermissions(path: String, permissions: UInt32) async throws {}
        func deleteTree(at path: String) async throws {}
        func homeDirectoryPath() async throws -> String { "/" }
        func disconnect() async {}
    }

    // MARK: - The four shapes

    @Test func aDigestComputedOnTheFarSideArrivesWithItsOrigin() async throws {
        let hex = String(repeating: "a", count: 64)
        let value = try #require(FileChecksum.computedOnRemote(.sha256, hex: hex))
        let fs = AnsweringFS(.outcome(.checksum(value)))
        let browser = RemoteBrowserViewModel(fs: fs)

        let result = await browser.checksum(of: Self.file, algorithm: .sha256)

        #expect(result == .checksum(value))
        #expect(await fs.askedPaths() == ["/iso.img"])
        #expect(await fs.askedAlgorithms() == [.sha256])
    }

    /// The multipart ETag reaches the surface AS a multipart ETag. This is
    /// the value the whole feature carries provenance for; if the browser
    /// flattened it into a plain digest here, nothing further down could
    /// tell the difference.
    @Test func aMultipartETagArrivesStillSayingItIsOne() async throws {
        let value = try #require(
            FileChecksum.objectStorageETag("\"\(String(repeating: "b", count: 32))-3\""))
        let fs = AnsweringFS(.outcome(.checksum(value)))
        let browser = RemoteBrowserViewModel(fs: fs)

        let result = await browser.checksum(of: Self.file, algorithm: .sha256)

        guard case .checksum(let carried) = result else {
            Issue.record("expected a checksum, got \(result)")
            return
        }
        #expect(carried.provenance == .objectStorageETagMultipart(partCount: 3))
        #expect(!carried.describesFileContent)
    }

    @Test func aConnectionThatCannotAnswerSaysSoRatherThanFailing() async {
        let fs = AnsweringFS(.outcome(.unavailableOnThisConnection))
        let browser = RemoteBrowserViewModel(fs: fs)

        #expect(await browser.checksum(of: Self.file, algorithm: .sha256)
            == .unavailableOnThisConnection)
    }

    /// A backend that does not conform at all — `MockRemoteFileSystem` is
    /// one — is reached through the same `as?` the capability is always
    /// reached through, and produces the same statement rather than a
    /// crash or a silent nothing.
    @Test func aBackendWithoutTheCapabilityIsTheSameStatement() async {
        let browser = RemoteBrowserViewModel(fs: MockRemoteFileSystem(tree: ["/": []]))

        #expect(await browser.checksum(of: Self.file, algorithm: .sha256)
            == .unavailableOnThisConnection)
    }

    /// An error about THIS file is not "no checksums here" — it is a
    /// failure about one file, carrying the same localized text every
    /// other browse action produces for the same error.
    ///
    /// The `%@` slot carries `DialSupport.reason(for: error)`, not the
    /// `RemoteFSError`'s own `reason` verbatim (diagnostic-log plan, Task 3
    /// fix round 1, Critical): `.protocolError`'s free text is exactly
    /// where `S3FileSystem`/`WebDAVFileSystem` embed the endpoint the user
    /// typed, which may carry `KEY:SECRET@` — planted here as
    /// `"unreadable ETag"`, an innocuous stand-in, but `message(for:path:)`
    /// cannot tell that string apart from a credential-bearing one, so it
    /// no longer reads either.
    @Test func anErrorAboutOneFileIsAFailureAndNotAnAbsence() async {
        let error = RemoteFSError.protocolError(reason: "unreadable ETag")
        let fs = AnsweringFS(.failure(error))
        let browser = RemoteBrowserViewModel(fs: fs)

        let result = await browser.checksum(of: Self.file, algorithm: .sha256)

        #expect(result == .failed(String(
            format: CoreL10n.string("core.browse.protocolError %@"), DialSupport.reason(for: error))))
    }

    @Test func aMissingFileReportsThePathTheCallerAskedAbout() async {
        let fs = AnsweringFS(.failure(.notFound(path: "/iso.img")))
        let browser = RemoteBrowserViewModel(fs: fs)

        #expect(await browser.checksum(of: Self.file, algorithm: .sha256)
            == .failed(String(
                format: CoreL10n.string("core.browse.notFound %@"), "/iso.img")))
    }

    /// The algorithm is the caller's, passed through untouched — S3's
    /// substitution is S3's to make and to label, never this layer's to
    /// pre-empt.
    @Test func theAlgorithmAskedForIsTheOnePassedOn() async {
        let fs = AnsweringFS(.outcome(.unavailableOnThisConnection))
        let browser = RemoteBrowserViewModel(fs: fs)

        _ = await browser.checksum(of: Self.file, algorithm: .md5)

        #expect(await fs.askedAlgorithms() == [.md5])
    }

    // MARK: - Which backends the action is offered on

    /// The offer follows the capability flag and nothing else. Written as
    /// a derivation rather than as three expectations about three
    /// backends: a `switch` over `ConnectionKind` would satisfy any list
    /// of names written today and then drift the first time a descriptor
    /// changes its mind, which is the whole reason the flag exists.
    @Test func theOfferIsTheCapabilityFlagForEveryBackend() {
        for kind in ConnectionKind.allCases {
            #expect(ChecksumAvailability.isOffered(for: kind)
                == BackendDescriptor.descriptor(for: kind).capabilities.supportsRemoteChecksum)
        }
    }

    /// The derivation above is satisfied by a function that always answers
    /// the same thing, so this holds it to discriminating at all — and it
    /// is WebDAV that makes it discriminate today.
    @Test func atLeastOneBackendIsNotOfferedAndAtLeastOneIs() {
        #expect(ConnectionKind.allCases.contains { ChecksumAvailability.isOffered(for: $0) })
        #expect(ConnectionKind.allCases.contains { !ChecksumAvailability.isOffered(for: $0) })
    }

    /// The local pane has no descriptor to read, so its answer comes off
    /// the conformance — and both directions are pinned here, because a
    /// function that answered `true` for anything at all would satisfy the
    /// positive half on its own.
    @Test func theLocalFileSystemIsOfferedAndABackendWithoutTheCapabilityIsNot() {
        #expect(ChecksumAvailability.isOffered(byLocalFileSystem: LocalFileSystem()))
        #expect(!ChecksumAvailability.isOffered(
            byLocalFileSystem: MockRemoteFileSystem(tree: ["/": []])))
    }
}
