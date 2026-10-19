import Foundation
import Testing
@testable import macSCPCore

@Suite("S3SettingsXML")
struct S3SettingsXMLTests {
    @Test func anAbsentVersioningElementReadsAsNever() throws {
        let xml = Data("<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>".utf8)
        #expect(try S3SettingsXML.parseVersioning(xml) == .never)
    }

    @Test(arguments: [("Enabled", BucketVersioning.enabled), ("Suspended", BucketVersioning.suspended)])
    func aStatusReadsAsItsState(text: String, expected: BucketVersioning) throws {
        let xml = Data("<VersioningConfiguration><Status>\(text)</Status></VersioningConfiguration>".utf8)
        #expect(try S3SettingsXML.parseVersioning(xml) == expected)
    }

    @Test func aStatusSurroundedByWhitespaceStillReads() throws {
        let xml = Data("<VersioningConfiguration><Status>\n  Enabled\n</Status></VersioningConfiguration>".utf8)
        #expect(try S3SettingsXML.parseVersioning(xml) == .enabled)
    }

    @Test func aStatusTheStoreInventedIsAProtocolError() {
        let xml = Data("<VersioningConfiguration><Status>Paused</Status></VersioningConfiguration>".utf8)
        #expect(throws: RemoteFSError.self) { try S3SettingsXML.parseVersioning(xml) }
    }

    @Test func aDocumentThatIsNotXMLIsAProtocolError() {
        #expect(throws: RemoteFSError.self) { try S3SettingsXML.parseVersioning(Data("<Versioning".utf8)) }
    }

    @Test func aMfaDeleteElementDoesNotChangeTheStatus() throws {
        let xml = Data(
            "<VersioningConfiguration><Status>Suspended</Status><MfaDelete>Disabled</MfaDelete></VersioningConfiguration>"
                .utf8)
        #expect(try S3SettingsXML.parseVersioning(xml) == .suspended)
    }

    @Test(arguments: [("Enabled", BucketVersioning.enabled), ("Suspended", BucketVersioning.suspended)])
    func aWritableStateIsBuiltAsItsStatus(text: String, state: BucketVersioning) throws {
        let body = try S3SettingsXML.versioningBody(state)
        let rendered = try #require(String(data: body, encoding: .utf8))
        #expect(rendered.contains("<Status>\(text)</Status>"))
        #expect(rendered.contains("<VersioningConfiguration"))
        // What was built reads back as what it was built from.
        #expect(try S3SettingsXML.parseVersioning(body) == state)
    }

    @Test func neverCannotBeWritten() {
        #expect(throws: RemoteFSError.self) { try S3SettingsXML.versioningBody(.never) }
    }

    @Test func neverIsRefusedAsAnUnsupportedOperation() {
        do {
            _ = try S3SettingsXML.versioningBody(.never)
            Issue.record("versioningBody(.never) returned a body")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.operationNotSupported))
        }
    }
}
