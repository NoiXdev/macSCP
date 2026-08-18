import Foundation

/// The on-disk payload of a snippet export (P3b spec, Task 1). The file
/// extension and `UTType` this becomes are a later task's job (P3b Task 3,
/// which the spec ties to `dev.noix.macscp.snippets`) — this type only
/// defines the bytes, not how Finder or a file picker labels them.
public struct SnippetExportPayload: Codable, Equatable, Sendable {
    public var snippets: [Snippet]

    public init(snippets: [Snippet]) {
        self.snippets = snippets
    }
}

/// `macscp-snippets` binding of the shared `ExportEnvelopeCodec` (P3b spec,
/// Task 1). Nothing but format identity lives here — envelope shape and
/// structural checks are the generic core's job (see `LoginSetExportCodec`,
/// the sibling facade this one copies the shape of).
///
/// Unlike `SessionExportCodec`/`LoginSetExportCodec`, this codec takes NO
/// `password` anywhere in its public surface. A snippet is never a
/// credential — `Snippet`'s own doc comment already rules a secret out of
/// `command`, and this project keeps secrets exclusively in the Keychain
/// (`SecretStore`), never in a JSON store. Offering a password parameter
/// here would invite encrypting a file that carries nothing to protect, so
/// the parameter itself is omitted rather than accepted and ignored.
/// `ExportEnvelopeCodec.encode` is always called with `password: nil`,
/// which is what makes the written envelope carry `"encrypted" : false` —
/// see `SnippetExportCodecTests.theWrittenFileIsPlainTextAndSaysSoInstead
/// OfClaimingEncryption` and `.probeAcceptsOurFormatAndRejectsASessionExport`,
/// which observe exactly that fact on the produced bytes (and on `probe`'s
/// return value) rather than merely asserting it in prose.
public enum SnippetExportCodec {
    static let formatName = "macscp-snippets"
    static let currentVersion = 1

    public static func encode(_ payload: SnippetExportPayload) throws -> Data {
        try ExportEnvelopeCodec.encode(
            payload, format: formatName, version: currentVersion, password: nil)
    }

    /// True = encrypted. Always `false` for this format — kept for shape
    /// parity with the other two export codecs (and because it also
    /// validates format/version before decode would), not because a
    /// snippet export can ever actually be encrypted.
    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(
            data, as: SnippetExportPayload.self, format: formatName,
            currentVersion: currentVersion)
    }

    public static func decode(_ data: Data) throws -> SnippetExportPayload {
        try ExportEnvelopeCodec.decode(
            data, as: SnippetExportPayload.self, format: formatName,
            currentVersion: currentVersion, password: nil)
    }
}
