import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionExportCodec")
struct FileActionExportCodecTests {
    private let action = FileAction(
        name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote, .local],
        perSelection: .oncePerFile)

    private func actionsFile() throws -> Data {
        try FileActionExportCodec.encode(
            FileActionExportPayload(actions: [ExportedFileAction(action)]))
    }

    private func snippetsFile() throws -> Data {
        try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [
                ExportedSnippet(Snippet(name: "n", command: "ls"))
            ]))
    }

    @Test func roundTripsThroughThePayload() throws {
        let back = try FileActionExportCodec.decode(try actionsFile())
        #expect(back.actions.count == 1)
        #expect(back.actions[0].name == "Count")
        #expect(back.actions[0].command == "wc -l {{PATH}}")
    }

    /// `probe` reports the envelope's own `encrypted` flag, as
    /// `SnippetExportCodec.probe` does — so for a file this codec wrote the
    /// answer is `false`. That `false` is the "this is my format and it
    /// needs no password" answer; the foreign-format case below is a throw.
    @Test func probeAcceptsItsOwnFileAndReportsItAsPlainText() throws {
        #expect(try FileActionExportCodec.probe(try actionsFile()) == false)
    }

    /// The property the separate type exists for, in both directions: an
    /// actions file is refused by the snippets codec and a snippets file is
    /// refused by the actions codec. Refusal here is a throw of
    /// `.notAnExportFile`, not a `false` — `probe`'s `Bool` is "encrypted",
    /// so a `false` would mean "accepted, plain".
    @Test func neitherCodecAcceptsTheOthersFile() throws {
        let actions = try actionsFile()
        let snippets = try snippetsFile()
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try FileActionExportCodec.probe(snippets)
        }
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try FileActionExportCodec.decode(snippets)
        }
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SnippetExportCodec.probe(actions)
        }
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SnippetExportCodec.decode(actions)
        }
    }

    /// The envelope's `format` is one barrier; the payload's own key is a
    /// second, independent one. Relabel an actions file as a snippets file
    /// and the snippets codec still refuses it, because `snippets` is a
    /// required key of its payload and the file carries `actions`.
    @Test func anActionsFileRelabelledAsSnippetsStillFailsOnItsPayload() throws {
        let text = try #require(String(data: try actionsFile(), encoding: .utf8))
        let anchor = "\"format\" : \"\(FileActionExportCodec.formatName)\""
        #expect(text.contains(anchor))
        let relabelled = text.replacingOccurrences(
            of: anchor, with: "\"format\" : \"\(SnippetExportCodec.formatName)\"")
        let data = Data(relabelled.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SnippetExportCodec.probe(data)
        }
    }

    /// An export carries the template and the two choices that decide what
    /// the template means. An imported action arrives with both set, so
    /// there is no "absent means something" case to reason about later.
    @Test func anExportCarriesTheFormAndTheSides() throws {
        let text = try #require(String(data: try actionsFile(), encoding: .utf8))
        #expect(text.contains("\"perSelection\""))
        #expect(text.contains("\"runsOn\""))
    }

    /// Written in `BrowserPaneSide`'s declared order whatever order the set
    /// iterates in, so exporting the same action twice yields the same
    /// bytes.
    @Test func sidesAreExportedInDeclaredOrder() {
        #expect(ExportedFileAction(action).runsOn == [.local, .remote])
    }

    @Test func importingMintsAFreshIdentityAndKeepsTheRest() throws {
        let back = try FileActionExportCodec.decode(try actionsFile())
        let imported = back.actions[0].imported()
        #expect(imported.id != action.id)
        #expect(imported.name == action.name)
        #expect(imported.command == action.command)
        #expect(imported.runsOn == action.runsOn)
        #expect(imported.perSelection == action.perSelection)
    }
}
