import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVURL")
struct WebDAVURLTests {
    private let plain = WebDAVURL(
        baseURL: URL(string: "https://dav.example.com/dav")!, nextcloudUser: nil)

    /// The root is the exact case M20 got wrong for SFTP (`stat("/")` yielded
    /// `//`). A collection URL ends in exactly one slash.
    @Test func rootIsTheBaseWithASingleTrailingSlash() {
        #expect(plain.url(forPath: "/", isDirectory: true).absoluteString
            == "https://dav.example.com/dav/")
    }

    @Test func fileUnderRootHasNoTrailingSlash() {
        #expect(plain.url(forPath: "/a.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/a.txt")
    }

    @Test func directoryGetsExactlyOneTrailingSlash() {
        #expect(plain.url(forPath: "/sub", isDirectory: true).absoluteString
            == "https://dav.example.com/dav/sub/")
    }

    /// Space, umlaut, plus and hash each break a different naive
    /// implementation: a space breaks the URL outright, `+` is silently read
    /// as a space by some servers, and `#` truncates the path at the fragment.
    @Test func specialCharactersArePercentEncoded() {
        #expect(plain.url(forPath: "/a b.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/a%20b.txt")
        #expect(plain.url(forPath: "/Ärger.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/%C3%84rger.txt")
        #expect(plain.url(forPath: "/a+b.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/a%2Bb.txt")
        #expect(plain.url(forPath: "/a#b.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/a%23b.txt")
    }

    /// A base URL that already ends in a slash must not produce a doubled one.
    @Test func trailingSlashOnTheBaseIsNotDoubled() {
        let base = WebDAVURL(
            baseURL: URL(string: "https://dav.example.com/dav/")!, nextcloudUser: nil)
        #expect(base.url(forPath: "/a.txt", isDirectory: false).absoluteString
            == "https://dav.example.com/dav/a.txt")
    }

    /// The Nextcloud accommodation: the user enters only the server origin and
    /// ticks the preset; the prefix and the user name are appended here.
    @Test func nextcloudPrefixIsAppendedWithTheUserName() {
        let cloud = WebDAVURL(
            baseURL: URL(string: "https://cloud.example.com")!, nextcloudUser: "tim")
        #expect(cloud.url(forPath: "/", isDirectory: true).absoluteString
            == "https://cloud.example.com/remote.php/dav/files/tim/")
        #expect(cloud.url(forPath: "/notes/a.txt", isDirectory: false).absoluteString
            == "https://cloud.example.com/remote.php/dav/files/tim/notes/a.txt")
    }

    /// A user name needing encoding must be encoded in the prefix too.
    @Test func nextcloudUserNameIsPercentEncoded() {
        let cloud = WebDAVURL(
            baseURL: URL(string: "https://cloud.example.com")!, nextcloudUser: "a b")
        #expect(cloud.url(forPath: "/", isDirectory: true).absoluteString
            == "https://cloud.example.com/remote.php/dav/files/a%20b/")
    }

    /// The reverse direction: a PROPFIND response reports hrefs, and the
    /// browser needs them back as its own paths. Round-tripping is what keeps
    /// listing and navigation consistent.
    @Test func hrefMapsBackToABrowserPath() {
        #expect(plain.path(forURL: URL(string: "https://dav.example.com/dav/sub/a.txt")!)
            == "/sub/a.txt")
        #expect(plain.path(forURL: URL(string: "https://dav.example.com/dav/")!) == "/")
        #expect(plain.path(forURL: URL(string: "https://dav.example.com/dav/a%20b.txt")!)
            == "/a b.txt")
    }

    /// An href outside the base is not ours — reporting it as a path would
    /// invent a browser entry that navigation cannot reach.
    @Test func hrefOutsideTheBaseIsRejected() {
        #expect(plain.path(forURL: URL(string: "https://dav.example.com/other/a.txt")!) == nil)
    }
}
