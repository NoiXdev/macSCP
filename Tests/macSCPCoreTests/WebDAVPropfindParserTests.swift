import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVPropfindParser")
struct WebDAVPropfindParserTests {
    private let base = WebDAVURL(
        baseURL: URL(string: "https://dav.example.com/dav")!, nextcloudUser: nil)

    /// Apache mod_dav, Depth: 1 on the root. Note the collection itself is the
    /// first response — it must not appear in the result.
    private let apacheListing = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:getlastmodified>Mon, 04 Aug 2026 07:00:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/a.txt</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength>12</D:getcontentlength>
            <D:getlastmodified>Mon, 04 Aug 2026 08:30:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/sub/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """.utf8)

    @Test func parsesApacheListingWithoutTheCollectionItself() throws {
        let items = try WebDAVPropfindParser.parse(
            apacheListing, base: base, requestedPath: "/")

        #expect(items.count == 2)
        let file = try #require(items.first { $0.name == "a.txt" })
        #expect(file.kind == .file)
        #expect(file.path == "/a.txt")
        #expect(file.size == 12)
        #expect(file.modifiedAt != nil)

        let directory = try #require(items.first { $0.name == "sub" })
        #expect(directory.kind == .directory)
        #expect(directory.path == "/sub")
        #expect(directory.size == nil)
    }

    /// Nextcloud answers with its own namespaces alongside DAV:. A parser that
    /// keys on the qualified name, or that chokes on unknown elements, drops
    /// every entry here. This fixture is the guard a pure-Apache rig cannot be.
    @Test func parsesNextcloudListingDespiteForeignNamespaces() throws {
        let nextcloud = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"
                       xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/tim/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:id>00000015ocxlyqnbtcsm</oc:id>
                <oc:permissions>RGDNVCK</oc:permissions>
                <nc:has-preview>false</nc:has-preview>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/tim/Readme.md</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>136</d:getcontentlength>
                <d:getlastmodified>Sat, 02 Aug 2026 11:12:13 GMT</d:getlastmodified>
                <oc:size>136</oc:size>
                <oc:owner-display-name>Tim</oc:owner-display-name>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><d:quota-available-bytes/></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
        let cloudBase = WebDAVURL(
            baseURL: URL(string: "https://cloud.example.com")!, nextcloudUser: "tim")

        let items = try WebDAVPropfindParser.parse(
            nextcloud, base: cloudBase, requestedPath: "/")

        #expect(items.count == 1)
        let file = try #require(items.first)
        #expect(file.name == "Readme.md")
        #expect(file.path == "/Readme.md")
        #expect(file.kind == .file)
        #expect(file.size == 136)
    }

    /// A propstat reporting 404 for a property must not discard the entry —
    /// Nextcloud does exactly this for properties it does not carry, and the
    /// fixture above relies on the 200 propstat being the one that counts.
    @Test func propertiesReported404DoNotDropTheEntry() throws {
        let items = try WebDAVPropfindParser.parse(
            Data("""
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/</d:href>
                <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
              </d:response>
              <d:response>
                <d:href>/dav/x.bin</d:href>
                <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>5</d:getcontentlength></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
                <d:propstat><d:prop><d:getetag/></d:prop>
                  <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8), base: base, requestedPath: "/")

        #expect(items.count == 1)
        #expect(items.first?.name == "x.bin")
    }

    @Test func emptyCollectionYieldsNoEntries() throws {
        let items = try WebDAVPropfindParser.parse(
            Data("""
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/empty/</d:href>
                <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8), base: base, requestedPath: "/empty")

        #expect(items.isEmpty)
    }

    @Test func malformedXMLThrowsProtocolError() {
        #expect(throws: RemoteFSError.self) {
            try WebDAVPropfindParser.parse(
                Data("not xml at all".utf8), base: base, requestedPath: "/")
        }
    }
}
