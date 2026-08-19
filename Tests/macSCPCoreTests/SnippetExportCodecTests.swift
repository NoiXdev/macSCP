import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetExportCodec")
struct SnippetExportCodecTests {
    @Test func aRoundTripPreservesNameCommandAndTags() throws {
        let snippet = Snippet(name: "Clean up", command: "docker system prune -f",
                              tags: ["docker"])
        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
        let restored = try SnippetExportCodec.decode(data)
        #expect(restored.snippets == [snippet])
    }

    /// The other half of "pin, not comment" (see `SnippetExportCodec`'s doc
    /// comment): this observes, on the produced bytes, that the file is (a)
    /// actually plaintext, not merely undocumented as encrypted, and (b)
    /// truthfully labeled `"encrypted" : false` rather than silently
    /// omitting the field.
    @Test func theWrittenFileIsPlainTextAndSaysSoInsteadOfClaimingEncryption() throws {
        let snippet = Snippet(name: "Clean up", command: "docker system prune -f")
        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
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

    /// The export payload is `[Snippet]`, so declarations travel without the
    /// codec knowing about them. This test exists because that is easy to
    /// break later by narrowing the payload, and nothing else would notice.
    @Test("declarations survive an export round trip")
    func declarationsSurviveExport() throws {
        let variable = SnippetVariable(
            name: "HOST", prompt: "Host", kind: .freeText,
            placement: .placeholder, defaultValue: "", remembersLastValue: false)
        let snippet = Snippet(name: "ping", command: "ping {{HOST}}", variables: [variable])
        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
        let decoded = try SnippetExportCodec.decode(data)
        #expect(decoded.snippets.first?.variables == [variable])
    }
}
