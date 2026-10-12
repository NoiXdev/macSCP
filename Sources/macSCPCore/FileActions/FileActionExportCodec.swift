import Foundation

/// One action as it travels in an export file. A separate type from
/// `FileAction` for the same reason `ExportedSnippet` is separate from
/// `Snippet`: an export is a wire format, and a field the wire format does
/// not name cannot be expressed by an import — which is a capability
/// boundary rather than an import-side cleanup rule someone has to
/// remember.
public struct ExportedFileAction: Codable, Equatable, Sendable {
    /// File-local id — never imported as-is; `imported()` mints a fresh one.
    public let id: UUID
    public var name: String
    public var command: String
    /// `nil` when the action declares none, so a file without variables
    /// carries no empty `variables` key.
    public var variables: [SnippetVariable]?
    /// A list rather than a set so the file is byte-stable; written in the
    /// declaration order of `BrowserPaneSide`.
    public var runsOn: [BrowserPaneSide]
    public var perSelection: FileActionPerSelection

    /// The one place a stored action becomes an exported one. Every field
    /// that travels is named here.
    public init(_ action: FileAction) {
        self.id = action.id
        self.name = action.name
        self.command = action.command
        self.variables = action.variables.isEmpty ? nil : action.variables
        self.runsOn = BrowserPaneSide.allCases.filter(action.runsOn.contains)
        self.perSelection = action.perSelection
    }

    /// The action this entry describes, with a fresh identity so an import
    /// never silently overwrites an action the user already has.
    public func imported() -> FileAction {
        FileAction(
            name: name, command: command, variables: variables ?? [],
            runsOn: Set(runsOn), perSelection: perSelection)
    }
}

/// The top-level object of an export file. Its key is `actions`, which is
/// the second thing — beside the envelope's `format` — that tells it apart
/// from a snippets file.
public struct FileActionExportPayload: Codable, Equatable, Sendable {
    public var actions: [ExportedFileAction]

    public init(actions: [ExportedFileAction]) {
        self.actions = actions
    }
}

/// `macscp-file-actions` binding of the shared `ExportEnvelopeCodec`,
/// copying the shape of `SnippetExportCodec`: nothing but format identity
/// lives here.
///
/// Like `SnippetExportCodec` it takes **no password**. A `FileAction` is a
/// command template and nothing else, so there is nothing to encrypt, and
/// every file this codec writes says `"encrypted" : false`.
///
/// **A snippets file is refused here and an actions file is refused by
/// `SnippetExportCodec`**, which is the structural half of keeping the two
/// kinds apart. Two independent things enforce it: the envelope's `format`
/// differs (`macscp-file-actions` against `macscp-snippets`), and the
/// payloads' required keys differ (`actions` against `snippets`). Refusal is
/// a thrown `SessionExportError.notAnExportFile`.
public enum FileActionExportCodec {
    static let formatName = "macscp-file-actions"
    static let currentVersion = 1

    public static func encode(_ payload: FileActionExportPayload) throws -> Data {
        try ExportEnvelopeCodec.encode(
            payload, format: formatName, version: currentVersion, password: nil)
    }

    /// The envelope's own `encrypted` flag, read back — not a format
    /// predicate. The format and version check runs first, inside
    /// `ExportEnvelopeCodec`, and **throws** on a mismatch, so a snippets
    /// file raises `.notAnExportFile` here instead of answering `false`.
    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(
            data, as: FileActionExportPayload.self, format: formatName,
            currentVersion: currentVersion)
    }

    public static func decode(_ data: Data) throws -> FileActionExportPayload {
        try ExportEnvelopeCodec.decode(
            data, as: FileActionExportPayload.self, format: formatName,
            currentVersion: currentVersion, password: nil)
    }
}
