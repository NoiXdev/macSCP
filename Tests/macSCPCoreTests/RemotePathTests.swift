import Testing
@testable import macSCPCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test func joinAppendsComponent() {
        #expect(RemotePath.join("/home/user", "docs") == "/home/user/docs")
    }

    @Test func joinHandlesTrailingSlash() {
        #expect(RemotePath.join("/home/user/", "docs") == "/home/user/docs")
    }

    @Test func joinOnRoot() {
        #expect(RemotePath.join("/", "etc") == "/etc")
    }

    @Test func parentOfNestedPath() {
        #expect(RemotePath.parent(of: "/home/user/docs") == "/home/user")
    }

    @Test func parentOfTopLevelIsRoot() {
        #expect(RemotePath.parent(of: "/etc") == "/")
    }

    @Test func parentOfRootIsRoot() {
        #expect(RemotePath.parent(of: "/") == "/")
    }
}
