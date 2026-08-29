import Foundation

/// One snippet as it travels in an export file — the export's OWN type, the
/// way `ExportedSession` is the sessions format's own type.
///
/// Deliberately not `Snippet`. The stored type is what `SnippetStore`
/// persists, and while the payload carried it directly, every field added
/// there reached every export file by merely existing. What a snippet
/// SHARES is decided here instead, field by field, and copied across by
/// `init(_:)` — so a field the export type does not name cannot be
/// expressed by the file at all, and no import-side cleanup rule has to
/// remember to strip it.
///
/// The bytes are unchanged by this: its fields carry `Snippet`'s own
/// coding keys, so a file written while the payload was `[Snippet]` decodes
/// here key for key (`SnippetExportCodecTests
/// .aFileFromBeforeTheExportTypeStillImports`), and the envelope stays at
/// version 1.
public struct ExportedSnippet: Codable, Equatable, Sendable {
    /// File-local id — never imported as-is. `SnippetImportPlanner` mints a
    /// fresh id for every snippet it takes over, and uses an EXISTING
    /// snippet's id when the user chooses Replace, exactly as
    /// `SessionImportPlanner` does for `ExportedSession.id`.
    ///
    /// Unlike `ExportedSession.id`, nothing inside the file refers to it:
    /// `ExportedGroup` is a per-file catalogue `ExportedSession.groupID`
    /// points into, and a snippet export has no such catalogue. It is
    /// carried because it always was — dropping it would change the bytes
    /// of a format that has no reason to change them.
    public let id: UUID
    public var name: String
    public var command: String
    /// Free-form labels (`Snippet.tags`). `nil` on a payload written before
    /// this field reached the format; the import side then applies
    /// `Snippet`'s own default (`[]`), mapped at import rather than at
    /// decode so every reader sees what the file actually said — the same
    /// rule `ExportedSession.tags` follows.
    ///
    /// A value, not a reference: no remapping on import, unlike `id`.
    public var tags: [String]?
    /// The values this snippet asks for before it runs
    /// (`Snippet.variables`). `nil` on a payload written before
    /// declarations existed; default applied at import, like `tags`.
    public var variables: [SnippetVariable]?

    public init(
        id: UUID, name: String, command: String, tags: [String]? = nil,
        variables: [SnippetVariable]? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.tags = tags
        self.variables = variables
    }

    /// The one place a stored snippet becomes an exported one. Every field
    /// that travels is named here; a field on `Snippet` that is not named
    /// here does not reach a file, and adding one to `Snippet` does not
    /// change what this writes.
    public init(_ snippet: Snippet) {
        self.init(
            id: snippet.id, name: snippet.name, command: snippet.command,
            tags: snippet.tags, variables: snippet.variables)
    }
}

/// The on-disk payload of a snippet export (P3b spec, Task 1). The file
/// extension and `UTType` this becomes are a later task's job (P3b Task 3,
/// which the spec ties to `dev.noix.macscp.snippets`) — this type only
/// defines the bytes, not how Finder or a file picker labels them.
public struct SnippetExportPayload: Codable, Equatable, Sendable {
    public var snippets: [ExportedSnippet]

    public init(snippets: [ExportedSnippet]) {
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

    /// True = encrypted — the envelope's own flag, read back verbatim. NOT a
    /// format predicate: the format/version check runs first, inside
    /// `ExportEnvelopeCodec`, and THROWS on a mismatch rather than reporting
    /// it here.
    ///
    /// For every file this codec wrote the answer is `false`, because
    /// `encode` always passes `password: nil`. It is NOT always `false`: a
    /// file that merely claims this format can carry `"encrypted" : true`,
    /// and then this returns `true` and `decode` — which has no password to
    /// pass — refuses with `.passwordRequired`. Both halves are pinned by
    /// `SnippetExportCodecTests
    /// .aForeignFileClaimingEncryptionProbesTrueAndRefusesToDecode`.
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
