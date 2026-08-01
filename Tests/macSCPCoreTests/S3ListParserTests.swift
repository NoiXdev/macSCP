import Foundation
import Testing
@testable import macSCPCore

@Suite("S3ListParser")
struct S3ListParserTests {
    /// A root-listing (`prefix=""`, `delimiter=/`) response: one file
    /// (`a.txt`, size 12) and one directory grouped by the delimiter
    /// (`sub/` reported as a `CommonPrefixes`, never a `Contents` entry —
    /// this is what proves the delimiter grouping worked upstream, not
    /// something this parser does itself).
    private let rootListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>macscp-seed</Name>
        <Prefix></Prefix>
        <KeyCount>2</KeyCount>
        <MaxKeys>1000</MaxKeys>
        <Delimiter>/</Delimiter>
        <IsTruncated>false</IsTruncated>
        <Contents>
            <Key>a.txt</Key>
            <LastModified>2024-01-02T03:04:05.000Z</LastModified>
            <ETag>&quot;9a0364b9e99bb480dd25e1f0284c8555&quot;</ETag>
            <Size>12</Size>
            <StorageClass>STANDARD</StorageClass>
        </Contents>
        <CommonPrefixes>
            <Prefix>sub/</Prefix>
        </CommonPrefixes>
    </ListBucketResult>
    """

    @Test func mapsFilesAndDirectoriesFromRootListing() throws {
        let result = try S3ListParser.parse(Data(rootListingXML.utf8), prefix: "")

        #expect(result.items.count == 2)

        let file = try #require(result.items.first { $0.name == "a.txt" })
        #expect(file.kind == .file)
        #expect(file.size == 12)
        #expect(file.path == "/a.txt")
        #expect(file.modifiedAt != nil)

        let directory = try #require(result.items.first { $0.name == "sub" })
        #expect(directory.kind == .directory)
        #expect(directory.path == "/sub")
        #expect(directory.size == nil)

        #expect(result.continuationToken == nil)
    }

    @Test func continuationTokenIsNilWhenNotTruncated() throws {
        let result = try S3ListParser.parse(Data(rootListingXML.utf8), prefix: "")
        #expect(result.continuationToken == nil)
    }

    @Test func continuationTokenSurvivesWhenTruncated() throws {
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>abc123</NextContinuationToken>
            <Contents>
                <Key>a.txt</Key>
                <Size>12</Size>
            </Contents>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(Data(truncatedXML.utf8), prefix: "")
        #expect(result.continuationToken == "abc123")
        #expect(result.items.map(\.name) == ["a.txt"])
    }

    @Test func nestedPrefixStripsToLeafNamesAndSkipsTheFolderMarkerItself() throws {
        // Listing under "sub/": the folder-marker object at the prefix
        // itself (Key == prefix, a zero-byte object some tools create) is
        // skipped, while a real object under the prefix is kept with its
        // prefix stripped to a leaf name.
        let nestedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>sub/</Key>
                <Size>0</Size>
            </Contents>
            <Contents>
                <Key>sub/b.txt</Key>
                <Size>5</Size>
            </Contents>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(Data(nestedXML.utf8), prefix: "sub/")
        #expect(result.items.count == 1)
        #expect(result.items.first?.name == "b.txt")
        #expect(result.items.first?.path == "/sub/b.txt")
    }

    @Test func malformedXMLThrowsProtocolError() throws {
        let garbage = Data("not xml at all <<<".utf8)
        #expect(throws: RemoteFSError.self) {
            _ = try S3ListParser.parse(garbage, prefix: "")
        }
    }
}
