import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHConfigParser")
struct SSHConfigParserTests {
    @Test func parsesFullBlock() {
        let hosts = SSHConfigParser.parse("""
        Host web
            HostName server.example.com
            User tim
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """)
        #expect(hosts == [SSHConfigHost(
            alias: "web", hostName: "server.example.com", user: "tim",
            port: 2222, identityFile: "~/.ssh/id_ed25519")])
    }

    @Test func keywordsAreCaseInsensitiveAndEqualsSeparatorWorks() {
        let hosts = SSHConfigParser.parse("""
        HOST web
            hostname=server.example.com
            USER = tim
        """)
        #expect(hosts.first?.hostName == "server.example.com")
        #expect(hosts.first?.user == "tim")
    }

    @Test func commentsAndBlankLinesAreIgnored() {
        let hosts = SSHConfigParser.parse("""
        # global Kommentar

        Host web   # Zeilenrest-Kommentar
            HostName server.example.com  # noch einer
        """)
        #expect(hosts == [SSHConfigHost(
            alias: "web", hostName: "server.example.com", user: nil,
            port: nil, identityFile: nil)])
    }

    @Test func multipleAliasesShareSettings() {
        let hosts = SSHConfigParser.parse("""
        Host backup mirror
            HostName backup.example.com
        """)
        #expect(hosts.map(\.alias) == ["backup", "mirror"])
        #expect(hosts.allSatisfy { $0.hostName == "backup.example.com" })
    }

    @Test func wildcardAndNegationAliasesAreSkipped() {
        let hosts = SSHConfigParser.parse("""
        Host *
            ServerAliveInterval 60
        Host web !intern web-?
            HostName server.example.com
        """)
        #expect(hosts.map(\.alias) == ["web"])
    }

    @Test func invalidPortYieldsNil() {
        let hosts = SSHConfigParser.parse("""
        Host web
            Port zweiundzwanzig
        """)
        #expect(hosts.first?.port == nil)
    }

    @Test func quotedValuesAreUnquoted() {
        let hosts = SSHConfigParser.parse("""
        Host web
            IdentityFile "~/.ssh/mein key"
        """)
        #expect(hosts.first?.identityFile == "~/.ssh/mein key")
    }

    @Test func firstValueWinsAndMatchBlocksAreIgnored() {
        let hosts = SSHConfigParser.parse("""
        Host web
            HostName erster.example.com
            HostName zweiter.example.com
        Match user tim
            HostName match.example.com
        Host zweiter
            HostName b.example.com
        """)
        #expect(hosts.map(\.alias) == ["web", "zweiter"])
        #expect(hosts.first?.hostName == "erster.example.com")
    }

    @Test func importerReturnsEmptyForMissingFileAndSortsByAlias() throws {
        #expect(SSHConfigImporter.load(
            path: "/tmp/macscp-keine-config-\(UUID().uuidString)") == [])

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sshconf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try """
        Host zeta
            HostName z.example.com
        Host Alpha
            HostName a.example.com
        """.write(to: file, atomically: true, encoding: .utf8)

        let hosts = SSHConfigImporter.load(path: file.path(percentEncoded: false))
        #expect(hosts.map(\.alias) == ["Alpha", "zeta"])
    }
}
