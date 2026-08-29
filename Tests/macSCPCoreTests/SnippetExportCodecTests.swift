import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetExportCodec")
struct SnippetExportCodecTests {
    @Test func aRoundTripPreservesNameCommandAndTags() throws {
        let snippet = Snippet(name: "Clean up", command: "docker system prune -f",
                              tags: ["docker"])
        let data = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))
        let restored = try SnippetExportCodec.decode(data)
        #expect(restored.snippets == [ExportedSnippet(snippet)])
    }

    /// The other half of "pin, not comment" (see `SnippetExportCodec`'s doc
    /// comment): this observes, on the produced bytes, that the file is (a)
    /// actually plaintext, not merely undocumented as encrypted, and (b)
    /// truthfully labeled `"encrypted" : false` rather than silently
    /// omitting the field.
    @Test func theWrittenFileIsPlainTextAndSaysSoInsteadOfClaimingEncryption() throws {
        let snippet = Snippet(name: "Clean up", command: "docker system prune -f")
        let data = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("docker system prune -f"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["encrypted"] as? Bool == false)
    }

    /// `probe` reports `ExportEnvelopeCodec`'s `encrypted` flag (see
    /// `SessionExportCodec.probe`'s and `LoginSetExportCodec.probe`'s
    /// identical doc comments: "True = encrypted"). Since `SnippetExportCodec`
    /// never has a password to pass, `probe` on our own output is always
    /// `false` — never `true` the way the task brief's own sketch assumed;
    /// the corrected assertion below matches
    /// `LoginSetExportCodecTests.roundTripsUnencrypted`'s
    /// `probe(data) == false` for the same unencrypted case.
    ///
    /// The second half is the sibling of `LoginSetExportCodecTests
    /// .rejectsASessionsFile`: a `.macscpsessions` file must not probe (or
    /// decode) as a snippet export — the shared envelope rejects a format
    /// mismatch the same way for every format, as structurally
    /// unrecognized rather than as a decode failure.
    @Test func probeAcceptsOurFormatAndRejectsASessionExport() throws {
        let ours = try SnippetExportCodec.encode(SnippetExportPayload(snippets: []))
        #expect(try SnippetExportCodec.probe(ours) == false)

        let sessions = try SessionExportCodec.encode(
            SessionExportPayload(includesSecrets: false, groups: [], sessions: []), password: nil)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SnippetExportCodec.probe(sessions)
        }
    }

    /// A command missing its `command` field can never come out of
    /// `SnippetExportCodec.encode` itself — it can only arrive as a
    /// hand-edited or corrupted file. Built as literal JSON, not re-encoded,
    /// for exactly that reason. (A multi-line command, by contrast, decodes
    /// fine now — see `SnippetTests.multilineCommandSurvivesEncoding` — so
    /// it no longer serves as the "damaged" shape this test needs.)
    ///
    /// `ExportEnvelopeCodec`'s private `envelope(from:)` decodes the whole
    /// `Envelope<P>` (header AND nested payload) through a single `try?`, so
    /// a payload-level failure — the missing field, in this case — comes
    /// out as `.notAnExportFile`, the same generic "not a recognizable
    /// export" error as a garbled file, not as the underlying `DecodingError`
    /// and not as a partial result with the bad entry dropped.
    @Test func aFileWithADamagedSnippetFailsTheWholeDecodeRatherThanDroppingItSilently() throws {
        let json = """
            {
              "encrypted" : false,
              "format" : "macscp-snippets",
              "payload" : {
                "snippets" : [
                  {
                    "id" : "11111111-1111-1111-1111-111111111111",
                    "name" : "Broken",
                    "tags" : [ ]
                  }
                ]
              },
              "version" : 1
            }
            """
        let data = Data(json.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SnippetExportCodec.decode(data)
        }
    }

    @Test func rejectsAnUnsupportedVersion() throws {
        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: []))
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["version"] = 2
        let tampered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: SessionExportError.unsupportedVersion(2)) {
            _ = try SnippetExportCodec.decode(tampered)
        }
    }

    /// The one shape that DOES reach `.passwordRequired` in a format with no
    /// password path at all: a file this app cannot have written. `encode`
    /// is the only writer and always passes `password: nil`, so everything
    /// this codec produces carries `"encrypted" : false` — but nothing stops
    /// a hand-written or corrupted file from claiming our format name with
    /// `"encrypted" : true`. `probe` reports that claim verbatim (it reads
    /// the envelope's flag, it does not verify it), so it answers `true`
    /// here; `decode`, which has no password to pass, then refuses with
    /// `.passwordRequired` rather than crashing or importing a half-decoded
    /// payload. The app maps that to the same generic refusal every other
    /// unreadable file gets (`snippetImportErrorText`).
    ///
    /// Written as literal JSON for the same reason
    /// `aFileWithADamagedSnippetFailsTheWholeDecodeRatherThanDroppingItSilently`
    /// is: this codec cannot produce these bytes.
    @Test func aForeignFileClaimingEncryptionProbesTrueAndRefusesToDecode() throws {
        let json = """
            {
              "encrypted" : true,
              "format" : "macscp-snippets",
              "version" : 1
            }
            """
        let data = Data(json.utf8)

        #expect(try SnippetExportCodec.probe(data) == true)
        #expect(throws: SessionExportError.passwordRequired) {
            _ = try SnippetExportCodec.decode(data)
        }
    }

    /// Declarations travel because `ExportedSnippet` names them and
    /// `ExportedSnippet.init(_:)` copies them — no longer because the
    /// payload happens to hold the stored type. This test exists because
    /// that is easy to break later by narrowing the export type, and
    /// nothing else would notice.
    @Test("declarations survive an export round trip")
    func declarationsSurviveExport() throws {
        let variable = SnippetVariable(
            name: "HOST", prompt: "Host", kind: .freeText,
            placement: .placeholder, defaultValue: "", remembersLastValue: false)
        let snippet = Snippet(name: "ping", command: "ping {{HOST}}", variables: [variable])
        let data = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))
        let decoded = try SnippetExportCodec.decode(data)
        #expect(decoded.snippets.first?.variables == [variable])
    }

    /// The OTHER direction of format compatibility, and the one a literal
    /// decode test cannot see: what this version WRITES is still what an
    /// earlier one reads. The keys below are `Snippet`'s own coding keys, in
    /// the order `.sortedKeys` puts them, and the envelope is still
    /// version 1 — so an installation that expects `[Snippet]` in the
    /// payload decodes this file without knowing the export grew a type of
    /// its own.
    ///
    /// Pinned as whole-text equality rather than as a handful of
    /// `contains` checks: a key that silently disappeared, or one that
    /// silently appeared, is exactly the damage this test exists to catch,
    /// and only equality sees both.
    @Test("what this version writes is what an earlier one reads")
    func theWrittenBytesStillCarryTheKeysAnEarlierVersionExpects() throws {
        let variable = SnippetVariable(
            name: "DB", prompt: "Which database?", kind: .freeText, placement: .placeholder,
            defaultValue: "staging", remembersLastValue: true)
        let snippet = Snippet(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Dump",
            command: "mysqldump {{DB}}", tags: ["db"], variables: [variable])

        let data = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))

        #expect(String(decoding: data, as: UTF8.self) == """
            {
              "encrypted" : false,
              "format" : "macscp-snippets",
              "payload" : {
                "snippets" : [
                  {
                    "command" : "mysqldump {{DB}}",
                    "id" : "22222222-2222-2222-2222-222222222222",
                    "name" : "Dump",
                    "tags" : [
                      "db"
                    ],
                    "variables" : [
                      {
                        "defaultValue" : "staging",
                        "kind" : {
                          "freeText" : {

                          }
                        },
                        "name" : "DB",
                        "placement" : "placeholder",
                        "prompt" : "Which database?",
                        "remembersLastValue" : true
                      }
                    ]
                  }
                ]
              },
              "version" : 1
            }
            """)
    }

    /// The boundary this milestone exists for, stated where it can be
    /// observed: a payload is built here with no `Snippet` anywhere in
    /// sight. The file's shape is `ExportedSnippet`'s, so a field reaches a
    /// file only if the export type names it AND `ExportedSnippet.init(_:)`
    /// copies it across — a field that merely exists on `Snippet` cannot be
    /// expressed by the file at all.
    ///
    /// `tags` and `variables` stand in for any later field on the stored
    /// type: they travel because both halves name them, and the assertion
    /// below is what fails if either half stops.
    @Test("the file carries the export's own type, not the stored one")
    func theFileCarriesTheExportsOwnTypeAndNotTheStoredOne() throws {
        let variable = SnippetVariable(
            name: "HOST", prompt: "Host", kind: .freeText,
            placement: .placeholder, defaultValue: "", remembersLastValue: false)
        let stored = Snippet(
            name: "ping", command: "ping {{HOST}}", tags: ["net"], variables: [variable])
        let handWritten = ExportedSnippet(
            id: stored.id, name: "ping", command: "ping {{HOST}}", tags: ["net"],
            variables: [variable])

        #expect(ExportedSnippet(stored) == handWritten)

        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [handWritten]))
        #expect(try SnippetExportCodec.decode(data).snippets == [handWritten])
    }

    /// A file written by an earlier version — when the payload carried the
    /// STORED `Snippet` type — still decodes, key for key. Literal JSON on
    /// purpose: a round trip through today's types would only prove today's
    /// types agree with themselves, which is exactly the thing a format
    /// change breaks without noticing.
    ///
    /// The keys below are the ones `Snippet` encodes (`id`, `name`,
    /// `command`, `tags`, `variables`), and the envelope is version 1 —
    /// unchanged, because the bytes are unchanged.
    @Test("a file written before the export had its own type still imports")
    func aFileFromBeforeTheExportTypeStillImports() throws {
        let json = """
            {
              "encrypted" : false,
              "format" : "macscp-snippets",
              "payload" : {
                "snippets" : [
                  {
                    "command" : "mysqldump {{DB}}",
                    "id" : "22222222-2222-2222-2222-222222222222",
                    "name" : "Dump",
                    "tags" : [ "db" ],
                    "variables" : [
                      {
                        "defaultValue" : "staging",
                        "kind" : { "freeText" : { } },
                        "name" : "DB",
                        "placement" : "placeholder",
                        "prompt" : "Which database?",
                        "remembersLastValue" : true
                      }
                    ]
                  }
                ]
              },
              "version" : 1
            }
            """
        let decoded = try SnippetExportCodec.decode(Data(json.utf8))
        let restored = try #require(decoded.snippets.first)
        #expect(decoded.snippets.count == 1)
        #expect(restored.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(restored.name == "Dump")
        #expect(restored.command == "mysqldump {{DB}}")
        #expect(restored.tags == ["db"])
        #expect(restored.variables == [SnippetVariable(
            name: "DB", prompt: "Which database?", kind: .freeText, placement: .placeholder,
            defaultValue: "staging", remembersLastValue: true)])
    }

    /// The older shape still: an export written before declarations existed
    /// carries no `variables` key, and one written before tags reached the
    /// format carries no `tags` key either. Both are absent here, and both
    /// decode as "the file said nothing" rather than as a decode failure —
    /// the import side applies `Snippet`'s own defaults, the same way
    /// `SessionImportPlanner` maps a `nil` `ExportedSession.tags`.
    @Test("an export with neither tags nor declarations still imports")
    func anExportWithoutTagsOrDeclarationsStillImports() throws {
        let json = """
            {
              "encrypted" : false,
              "format" : "macscp-snippets",
              "payload" : {
                "snippets" : [
                  {
                    "command" : "df -h",
                    "id" : "33333333-3333-3333-3333-333333333333",
                    "name" : "Disk"
                  }
                ]
              },
              "version" : 1
            }
            """
        let restored = try #require(try SnippetExportCodec.decode(Data(json.utf8)).snippets.first)
        #expect(restored.name == "Disk")
        #expect(restored.command == "df -h")
        #expect(restored.tags == nil)
        #expect(restored.variables == nil)
    }

    /// Pins the reason `SnippetVariableMemoryStore` exists as a store
    /// separate from `Snippet` (see that type's doc comment): a value
    /// someone typed and opted to have remembered must never travel with
    /// an export.
    ///
    /// Asserts BOTH halves, not just the absence: first, that
    /// `remember` genuinely put the value on disk in
    /// `snippet-variables.json` — without that half, the second assertion
    /// would pass even if `remember` were deleted entirely, since `encode`
    /// never touches that file and `Snippet` has no field to carry the
    /// value regardless of whether anything was ever remembered. Verified
    /// by hand: commenting out the `remember` call turns the FIRST
    /// assertion red (not the second), confirming the test actually
    /// exercises the store rather than passing vacuously. The second half
    /// is what guards against a future field on `ExportedSnippet` quietly
    /// reintroducing the value into an export. It no longer has to watch
    /// `Snippet` for the same thing: a stored property added there reaches
    /// no file unless `ExportedSnippet` names it too.
    @Test("a remembered value never appears in the export bytes")
    func rememberedValueNeverReachesTheExport() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippet-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let variable = SnippetVariable(
            name: "DB", prompt: "Database", kind: .freeText,
            placement: .placeholder, defaultValue: "", remembersLastValue: true)
        let snippet = Snippet(name: "psql", command: "psql {{DB}}", variables: [variable])
        let secretRememberedValue = "unmistakably-secret-kunden-db"
        try SnippetVariableMemoryStore(directory: dir)
            .remember(secretRememberedValue, snippetID: snippet.id, name: "DB")

        let variablesFileText = try String(
            contentsOf: dir.appendingPathComponent("snippet-variables.json"), encoding: .utf8)
        #expect(variablesFileText.contains(secretRememberedValue))

        let data = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))
        let exportText = String(decoding: data, as: UTF8.self)
        #expect(!exportText.contains(secretRememberedValue))
    }
}
