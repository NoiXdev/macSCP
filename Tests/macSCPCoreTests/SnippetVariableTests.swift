import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetVariable")
struct SnippetVariableTests {
    /// The name becomes a shell assignment for `.environment`, so it has to
    /// be a valid shell identifier. The same rule applies to `.placeholder`
    /// deliberately: two rules for one field would be a defect source with
    /// no benefit.
    @Test("a valid name starts with a letter or underscore and continues alphanumerically")
    func validNames() {
        #expect(SnippetVariable.isValidName("DBNAME"))
        #expect(SnippetVariable.isValidName("_tmp2"))
        #expect(SnippetVariable.isValidName("a"))
    }

    @Test("a name that would not survive as a shell assignment is rejected")
    func invalidNames() {
        #expect(!SnippetVariable.isValidName(""))
        #expect(!SnippetVariable.isValidName("2FAST"))
        #expect(!SnippetVariable.isValidName("DB-NAME"))
        #expect(!SnippetVariable.isValidName("DB NAME"))
        #expect(!SnippetVariable.isValidName("DB;rm -rf /"))
    }

    @Test("a snippet carries its declarations through a store round trip")
    func declarationsSurviveEncoding() throws {
        let variable = SnippetVariable(
            name: "DBNAME", prompt: "Database", kind: .selection(["prod", "staging"]),
            placement: .environment, defaultValue: "staging", remembersLastValue: true)
        let original = Snippet(name: "dump", command: "mysqldump $DBNAME", variables: [variable])
        let decoded = try JSONDecoder().decode(
            Snippet.self, from: JSONEncoder().encode(original))
        #expect(decoded.variables == [variable])
    }

    /// A store file written before this feature has no `variables` key at
    /// all. It must decode as "no variables", exactly the way `tags` was
    /// introduced — not as an error.
    @Test("a snippet written before this feature still decodes")
    func legacySnippetDecodes() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","name":"n","command":"ls","tags":[]}"#
        let decoded = try JSONDecoder().decode(Snippet.self, from: Data(json.utf8))
        #expect(decoded.variables.isEmpty)
    }
}
