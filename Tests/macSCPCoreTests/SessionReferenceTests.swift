import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionReference")
struct SessionReferenceTests {
    private func session(_ name: String, id: UUID = UUID()) -> StoredSession {
        sshSession(id: id, name: name, host: "example.com", port: 22,
                      username: "deploy", authKind: .password)
    }

    @Test func parsesRemoteReference() {
        #expect(SessionReference.parse("prod:/var/www")
            == .remote(name: "prod", path: "/var/www"))
    }

    @Test func aPathWithoutPrefixIsLocal() {
        #expect(SessionReference.parse("./dist.tar.gz") == .local(path: "./dist.tar.gz"))
        #expect(SessionReference.parse("/tmp/x") == .local(path: "/tmp/x"))
    }

    /// Only the FIRST colon separates; the rest belongs to the path. Remote
    /// paths legitimately contain colons.
    @Test func onlyTheFirstColonSeparates() {
        #expect(SessionReference.parse("prod:/var/log/app:1.log")
            == .remote(name: "prod", path: "/var/log/app:1.log"))
    }

    /// A Windows-style drive letter is not a session name. Single-character
    /// prefixes stay local so `C:\tmp` keeps working on a mounted volume.
    @Test func singleLetterPrefixStaysLocal() {
        #expect(SessionReference.parse("C:/tmp/x") == .local(path: "C:/tmp/x"))
    }

    @Test func emptyPathDefaultsToRoot() {
        #expect(SessionReference.parse("prod:") == .remote(name: "prod", path: "/"))
    }

    @Test func resolvesAUniqueName() throws {
        let wanted = session("prod")
        let resolved = try SessionReference.parse("prod:/x").resolve(
            in: [session("staging"), wanted])
        #expect(resolved.id == wanted.id)
    }

    @Test func anUnknownNameThrows() {
        #expect(throws: SessionReferenceError.unknown("nope")) {
            try SessionReference.parse("nope:/x").resolve(in: [session("prod")])
        }
    }

    /// Two sessions may share a name — the App allows it. A script must not
    /// silently get whichever came first.
    @Test func anAmbiguousNameThrows() {
        #expect(throws: SessionReferenceError.ambiguous("prod", count: 2)) {
            try SessionReference.parse("prod:/x").resolve(
                in: [session("prod"), session("prod")])
        }
    }

    /// The UUID is the stable handle: names can be renamed, ids cannot.
    @Test func resolvesByUUID() throws {
        let id = UUID()
        let wanted = session("prod", id: id)
        let resolved = try SessionReference.parse("\(id.uuidString):/x").resolve(
            in: [wanted, session("prod")])
        #expect(resolved.id == id)
    }

    @Test func resolvingALocalReferenceThrows() {
        #expect(throws: SessionReferenceError.unknown("./x")) {
            try SessionReference.parse("./x").resolve(in: [session("prod")])
        }
    }
}
