import Foundation
import Testing

@testable import macSCPCore

@Suite("FileAction")
struct FileActionTests {
    @Test func roundTripsThroughJSON() throws {
        let action = FileAction(
            name: "Count lines", command: "wc -l {{PATH}}",
            runsOn: [.remote], perSelection: .onceWithEveryPath)
        let data = try JSONEncoder().encode(action)
        let back = try JSONDecoder().decode(FileAction.self, from: data)
        #expect(back == action)
    }

    /// The custom encoder and decoder branch on `variables` and on a
    /// two-element `runsOn`, which the test above does not reach.
    @Test func roundTripsWithVariablesAndBothSides() throws {
        let variable = SnippetVariable(
            name: "MODE", prompt: "Mode?", kind: .selection(["fast", "safe"]),
            placement: .placeholder, defaultValue: "fast", remembersLastValue: false)
        let action = FileAction(
            name: "Archive", command: "tar -czf {{MODE}}.tgz {{PATH}}",
            variables: [variable], runsOn: [.local, .remote], perSelection: .oncePerFile)
        let data = try JSONEncoder().encode(action)
        let back = try JSONDecoder().decode(FileAction.self, from: data)
        #expect(back == action)
    }

    /// A `Set`'s iteration order is not stable across process launches, so an
    /// encoder that wrote it straight out would rewrite the store file
    /// differently on every save. The encoding walks `BrowserPaneSide.allCases`
    /// instead. This is a single probe of that property, not a sensitivity
    /// measurement: the hashing seed is fixed for the life of a process, so a
    /// two-element set presents one of its two hash orders per run.
    @Test func runsOnEncodesInDeclarationOrder() throws {
        let action = FileAction(
            name: "n", command: "c", runsOn: [.remote, .local],
            perSelection: .oncePerFile)
        let json = try #require(String(data: try JSONEncoder().encode(action), encoding: .utf8))
        #expect(json.contains("[\"local\",\"remote\"]"))
    }

    /// An absent `variables` key decodes to none, so a store file written
    /// before an action had variables keeps loading.
    @Test func anAbsentVariablesKeyDecodesToNone() throws {
        let json = """
            {"id":"7E4F7E1C-0000-4000-8000-000000000001","name":"n",
             "command":"c","runsOn":["remote"],"perSelection":"onceWithEveryPath"}
            """
        let action = try JSONDecoder().decode(FileAction.self, from: Data(json.utf8))
        #expect(action.variables.isEmpty)
    }
}
