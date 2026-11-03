import Foundation
import MacSCPTestSupport
import Testing

/// Holds the decision that there is NO object-ACL write anywhere in Core.
///
/// Spec section 3 removed the control because the rig's store answers
/// `PUT ?acl` with `200` and keeps nothing, which is the one failure mode a
/// later contributor cannot see by testing against the rig. A source scan is
/// the only thing that notices a write coming back.
///
/// ## Why this is a count and a derivation rather than a search for `?acl`
///
/// The obvious guard, "no S3 source contains `?acl`", scans for a spelling
/// this project does not use. The ACL read spells its sub-resource as a
/// query item, `query: [(name: "acl", value: "")]`, and the signer turns that
/// into the query string; the characters `?acl` never occur. A write written
/// in the same idiom would pass that scan untouched. Worse, the strict view
/// (`SourceCorpus.code(of:)`) blanks string literals, and the sub-resource
/// name and the header name are both literals: a scan for either over that
/// view looks at spaces. So the scans here read the comment-blanked view
/// (`commentFree(of:)`), which keeps literals, and take their STRUCTURE
/// (parentheses, `func` names) from the strict view, which shares its
/// indexing (both views preserve length).
///
/// What each check holds, and the positive beside it (CLAUDE.md, "Guards
/// that name what they watch": only a NEGATIVE check can go stale in
/// silence):
///
/// 1. The literal `"acl"` appears exactly once under `Sources/macSCPCore/S3/`.
///    A count, so a second one fails loudly and names its file. Beside it:
///    the scan reaches the S3 files, and the one it finds is in
///    `S3FileSystem.swift`.
/// 2. That one occurrence sits in a call whose `method:` is the literal
///    `"GET"`, inside a function named `acl`. Both are DERIVED from the code
///    around the occurrence, and both are asserted as values, not as
///    absences.
/// 3. No `amz-acl` or `amz-grant` header spelling, and no `?acl` / `&acl` /
///    `acl=` inside a literal, under that directory. This one IS negative;
///    its positive is that the same view still holds other header literals,
///    which the strict view would have blanked.
/// 4. `RemoteFS/ObjectMetadataProvider.swift` lives outside the directory the
///    checks above scan, so a `setACL` requirement on the protocol is
///    invisible to them. Checked over every file in Core: no function whose
///    name reads as writing an ACL or a grant, with the positive that
///    exactly the two files that declare `acl` are found.
/// 5. Each scan function is driven over fixtures that are not under any
///    scanned directory, both ways.
///
/// What this does not see, stated so nobody reads more into it than is
/// there: a request built without the literal (a name assembled from parts
/// at run time; a split-off prefix such as `"x-amz-" + "acl"` is caught only
/// because the `"acl"` literal count in check 1 goes to two), a write in
/// `Sources/MacSCPAppKit`, and a protocol member that is not a `func`.
@Suite("No object-ACL write guard")
struct NoACLWriteGuardTests {
    private static var coreRoot: URL {
        SourceCorpus.url(of: .sources).appendingPathComponent("macSCPCore", isDirectory: true)
    }

    private static var s3Directory: URL { coreRoot.appendingPathComponent("S3", isDirectory: true) }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        try SourceCorpus.files(under: directory).filter { $0.pathExtension == "swift" }
    }

    // MARK: - Check 1: the sub-resource name appears exactly once

    @Test func theAclQueryNameAppearsExactlyOnceUnderS3() throws {
        var found: [String] = []
        for file in try Self.swiftFiles(under: Self.s3Directory) {
            let view = try SourceCorpus.commentFree(of: file)
            for _ in ACLWriteScan.queryNameOffsets(inCommentFree: view) {
                found.append(file.lastPathComponent)
            }
        }
        #expect(found == ["S3FileSystem.swift"], "\(found)")
    }

    @Test func theScanUnderS3ReachesTheFilesThatWouldCarryAWrite() throws {
        let files = try Self.swiftFiles(under: Self.s3Directory)
        #expect(files.count >= 10, "\(files.count)")
        #expect(files.contains { $0.lastPathComponent == "S3FileSystem.swift" })
        #expect(files.contains { $0.lastPathComponent == "S3Uploader.swift" })
    }

    // MARK: - Check 2: that one occurrence is a GET, in a function named acl

    @Test func theOneAclRequestIsAGetInsideTheFunctionNamedAcl() throws {
        let file = Self.s3Directory.appendingPathComponent("S3FileSystem.swift")
        let inspections = try ACLWriteScan.inspect(
            code: SourceCorpus.code(of: file), commentFree: SourceCorpus.commentFree(of: file))
        #expect(inspections.count == 1, "\(inspections)")
        #expect(inspections.first?.method == "GET", "\(inspections)")
        #expect(inspections.first?.functionName == "acl", "\(inspections)")
    }

    // MARK: - Check 3: no ACL header name, in any spelling

    @Test func noS3SourceNamesAnAclOrGrantHeader() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles(under: Self.s3Directory) {
            let view = try SourceCorpus.commentFree(of: file)
            if !ACLWriteScan.headerSpellings(inCommentFree: view).isEmpty {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func theHeaderScanReadsLiteralsThatTheStrictViewBlanks() throws {
        // The positive beside the negative above. A header name is a string
        // literal; the strict view blanks it, so a scan over that view finds
        // nothing whether or not a violation is there.
        let file = Self.s3Directory.appendingPathComponent("S3FileSystem.swift")
        let kept = try SourceCorpus.commentFree(of: file)
        let blanked = try SourceCorpus.code(of: file)
        #expect(kept.contains("x-amz-metadata-directive"))
        #expect(!blanked.contains("x-amz-metadata-directive"))
    }

    // MARK: - Check 4: no write-shaped ACL member anywhere in Core

    @Test func noFunctionInCoreIsShapedLikeAnAclWrite() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles(under: Self.coreRoot) {
            let code = try SourceCorpus.code(of: file)
            for name in ACLWriteScan.writeShapedACLFunctionNames(inCode: code) {
                offenders.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func theProviderProtocolDeclaresTheAclReadAndNoOtherAclMember() throws {
        let file = Self.coreRoot.appendingPathComponent("RemoteFS/ObjectMetadataProvider.swift")
        let names = ACLWriteScan.functionNames(inCode: try SourceCorpus.code(of: file))
        #expect(names.contains("acl"), "\(names)")
        let aclShaped = names.filter(ACLWriteScan.mentionsAclOrGrant)
        #expect(aclShaped == ["acl"], "\(aclShaped)")
    }

    @Test func exactlyTheProtocolAndTheS3ConformerDeclareAnAclFunction() throws {
        // The positive that proves the Core-wide walk above reached the
        // places an ACL function lives.
        var declaring: [String] = []
        for file in try Self.swiftFiles(under: Self.coreRoot) {
            let code = try SourceCorpus.code(of: file)
            if ACLWriteScan.functionNames(inCode: code).contains("acl") {
                declaring.append(file.lastPathComponent)
            }
        }
        #expect(
            Set(declaring) == ["ObjectMetadataProvider.swift", "S3FileSystem.swift"], "\(declaring)")
    }

    // MARK: - Check 5: the scans, driven over fixtures outside any scanned directory

    /// The realistic violation: this project's own idiom, a query item named
    /// for the sub-resource, paired with a mutating method.
    private static let plantedWrite = #"""
        func setACL(ofKey key: String, inBucket bucket: String) async throws {
            let request = try buildSignedRequest(
                bucket: bucket, method: "PUT", key: key, query: [(name: "acl", value: "")],
                payloadHash: SigV4Signer.emptyPayloadHash)
            _ = try await send(request)
        }
        """#

    private static let plantedWriteWithDynamicMethod = #"""
        func acl(ofKey key: String, inBucket bucket: String) async throws {
            let request = try buildSignedRequest(
                bucket: bucket, method: verb, key: key, query: [(name: "acl", value: "")],
                payloadHash: SigV4Signer.emptyPayloadHash)
        }
        """#

    private static let plantedWriteHiddenInAnotherFunction = #"""
        func acl(ofKey key: String, inBucket bucket: String) async throws {
            return nil
        }
        func applyCannedPolicy(key: String) async throws {
            let request = try buildSignedRequest(
                bucket: bucket, method: "GET", key: key, query: [(name: "acl", value: "")],
                payloadHash: SigV4Signer.emptyPayloadHash)
        }
        """#

    private static let theRead = #"""
        func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL? {
            let request = try buildSignedRequest(
                bucket: bucket, method: "GET", key: key, query: [(name: "acl", value: "")],
                payloadHash: SigV4Signer.emptyPayloadHash)
        }
        """#

    private static func inspect(_ source: String) throws -> [ACLWriteScan.Inspection] {
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let commentFree = try SwiftSource.blankingComments(source)
        return try ACLWriteScan.inspect(code: code, commentFree: commentFree)
    }

    @Test func theInspectionReadsAPlantedPutAsAPut() throws {
        let found = try Self.inspect(Self.plantedWrite)
        #expect(found.count == 1, "\(found)")
        #expect(found.first?.method == "PUT")
        #expect(found.first?.functionName == "setACL")
    }

    @Test func theInspectionDoesNotMistakeADynamicMethodForAGet() throws {
        let found = try Self.inspect(Self.plantedWriteWithDynamicMethod)
        #expect(found.count == 1, "\(found)")
        #expect(found.first?.method == nil, "\(found)")
    }

    @Test func theInspectionNamesTheFunctionThatActuallyHoldsTheOccurrence() throws {
        let found = try Self.inspect(Self.plantedWriteHiddenInAnotherFunction)
        #expect(found.first?.method == "GET")
        #expect(found.first?.functionName == "applyCannedPolicy")
    }

    @Test func theInspectionAcceptsTheRealShapeOfTheRead() throws {
        let found = try Self.inspect(Self.theRead)
        #expect(found.count == 1, "\(found)")
        #expect(found.first?.method == "GET")
        #expect(found.first?.functionName == "acl")
    }

    @Test func aCommentExplainingTheAbsenceIsNotAnOccurrence() throws {
        let source = #"""
            // There is no write: never send query: [(name: "acl", value: "")] with a PUT.
            /// And no "x-amz-acl" header either.
            func nothing() {}
            """#
        let commentFree = try SwiftSource.blankingComments(source)
        #expect(ACLWriteScan.queryNameOffsets(inCommentFree: commentFree).isEmpty)
        #expect(ACLWriteScan.headerSpellings(inCommentFree: commentFree).isEmpty)
    }

    @Test func theQueryNameCountSeesBothCasesAndASplitOffPrefix() throws {
        let both = try SwiftSource.blankingComments(
            #"let a = (name: "ACL", value: ""); let b = (name: "acl", value: "")"#)
        #expect(ACLWriteScan.queryNameOffsets(inCommentFree: both).count == 2)
        let split = try SwiftSource.blankingComments(#"let h = "x-amz-" + "acl""#)
        #expect(ACLWriteScan.queryNameOffsets(inCommentFree: split).count == 1)
    }

    @Test func theHeaderScanCatchesEverySpellingItClaimsTo() throws {
        for header in ["x-amz-acl", "X-Amz-Acl", "x-amz-grant-read", "X-AMZ-GRANT-FULL-CONTROL"] {
            let commentFree = try SwiftSource.blankingComments(
                "let h: [String: String] = [\"\(header)\": \"public-read\"]")
            #expect(
                !ACLWriteScan.headerSpellings(inCommentFree: commentFree).isEmpty,
                "not caught: \(header)")
        }
        let benign = try SwiftSource.blankingComments(#"let h = "x-amz-metadata-directive""#)
        #expect(ACLWriteScan.headerSpellings(inCommentFree: benign).isEmpty)
    }

    @Test func theQuerySpellingsOfTheSubresourceAreCaughtInsideLiterals() throws {
        for literal in ["/b/k?acl", "/b/k?versionId=1&acl", "acl=", "?acl="] {
            let commentFree = try SwiftSource.blankingComments("let u = \"\(literal)\"")
            #expect(
                !ACLWriteScan.headerSpellings(inCommentFree: commentFree).isEmpty,
                "not caught: \(literal)")
        }
    }

    @Test func theFunctionNameScanFlagsWriteShapesAndSparesReadsAndParsers() throws {
        let flagged = [
            "setACL", "setObjectACL", "putAcl", "putObjectAcl", "writeACL", "aclSet",
            "applyACL", "replaceGrants", "grantRead", "updateAclGrants",
        ]
        for name in flagged {
            let code = try SwiftSource.blankingCommentsAndStrings("func \(name)(key: String) {}")
            #expect(
                ACLWriteScan.writeShapedACLFunctionNames(inCode: code) == [name],
                "not flagged: \(name)")
        }
        let spared = ["acl", "finishGrant", "aclFromXML", "metadata", "setMetadata", "parseGrants"]
        for name in spared {
            let code = try SwiftSource.blankingCommentsAndStrings("func \(name)(key: String) {}")
            #expect(
                ACLWriteScan.writeShapedACLFunctionNames(inCode: code).isEmpty,
                "wrongly flagged: \(name)")
        }
    }

    @Test func aWriteRequirementOnTheProviderProtocolIsFlagged() throws {
        let code = try SwiftSource.blankingCommentsAndStrings(
            """
            public protocol ObjectMetadataProvider: Sendable {
                func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL?
                func setACL(_ acl: ObjectACL, ofKey key: String, inBucket bucket: String) async throws
            }
            """)
        #expect(ACLWriteScan.writeShapedACLFunctionNames(inCode: code) == ["setACL"])
    }
}

/// The scans, as pure functions of source text, so the suite can drive each
/// one over a fixture as well as over the tree.
enum ACLWriteScan {
    struct Inspection: Equatable, CustomStringConvertible {
        /// The literal `method:` argument of the call the occurrence sits in,
        /// or `nil` when there is no such call or its method is not a literal.
        let method: String?
        /// The function whose declaration most recently precedes the
        /// occurrence.
        let functionName: String?
        var description: String { "method=\(method ?? "nil") in func=\(functionName ?? "nil")" }
    }

    enum ScanFailure: Error { case viewsDiffer }

    /// Character offsets of every string literal that is exactly `acl`, in
    /// either case. Read from the comment-blanked view, which keeps literals.
    static func queryNameOffsets(inCommentFree view: String) -> [Int] {
        offsets(of: #"(?i)"acl""#, in: view)
    }

    /// Header and query spellings of an ACL write that are not the
    /// query-item idiom: `amz-acl` and `amz-grant` header names, and `?acl`,
    /// `&acl` or `acl=` inside a literal.
    static func headerSpellings(inCommentFree view: String) -> [Int] {
        offsets(of: #"(?i)amz-(?:acl|grant)"#, in: view)
            + offsets(of: #"(?i)"[^"\n]*(?:[?&]acl\b|\bacl=)[^"\n]*""#, in: view)
    }

    /// For each `acl` query-name literal: the `method:` literal of the
    /// innermost enclosing call that has one, and the enclosing function.
    /// Structure is read from `code`; literals from `commentFree`; the two
    /// share an indexing.
    static func inspect(code: String, commentFree: String) throws -> [Inspection] {
        let codeChars = Array(code)
        let freeChars = Array(commentFree)
        guard codeChars.count == freeChars.count else { throw ScanFailure.viewsDiffer }
        let functions = try regexMatches(#"\bfunc\s+(\w+)"#, in: code)
        return queryNameOffsets(inCommentFree: commentFree).map { offset in
            var depth = 0
            var method: String?
            var index = offset - 1
            while index >= 0 {
                let character = codeChars[index]
                if character == ")" {
                    depth += 1
                } else if character == "(" {
                    if depth > 0 {
                        depth -= 1
                    } else if let close = matchingClose(of: index, in: codeChars),
                        String(codeChars[index...close]).contains("method:")
                    {
                        let literal = String(freeChars[index...close])
                        let methods =
                            (try? regexMatches(#"\bmethod:\s*"([A-Za-z]+)""#, in: literal)) ?? []
                        if methods.count == 1 { method = methods[0].group }
                        break
                    }
                }
                index -= 1
            }
            return Inspection(
                method: method, functionName: functions.last { $0.offset < offset }?.group)
        }
    }

    static func functionNames(inCode code: String) -> [String] {
        ((try? regexMatches(#"\bfunc\s+(\w+)"#, in: code)) ?? []).map(\.group)
    }

    /// Function names that read as writing an ACL or a grant: they mention
    /// one, and either carry a write verb as a word or open with `grant`.
    static func writeShapedACLFunctionNames(inCode code: String) -> [String] {
        functionNames(inCode: code).filter { name in
            guard mentionsAclOrGrant(name) else { return false }
            return words(of: name).enumerated().contains { position, word in
                writeVerbs.contains(word) || (word == "grant" && position == 0)
            }
        }
    }

    static func mentionsAclOrGrant(_ name: String) -> Bool {
        words(of: name).contains { ["acl", "acls", "grant", "grants"].contains($0) }
    }

    private static let writeVerbs: Set<String> = [
        "set", "put", "write", "apply", "replace", "update", "change", "modify", "revoke",
        "add", "save", "store", "post", "make", "create", "remove", "delete", "send", "edit",
    ]

    /// camelCase split, lower-cased: `setObjectACL` -> set, object, acl.
    private static func words(of name: String) -> [String] {
        let pieces = (try? regexMatches(#"([A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+)"#, in: name)) ?? []
        return pieces.map { $0.group.lowercased() }
    }

    private struct Match {
        let offset: Int
        let group: String
    }

    private static func regexMatches(_ pattern: String, in text: String) throws -> [Match] {
        let regex = try CompiledPattern.regex(pattern)
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groupRange = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text) : nil
            return Match(
                offset: text.distance(from: text.startIndex, to: range.lowerBound),
                group: String(text[groupRange ?? range]))
        }
    }

    private static func offsets(of pattern: String, in text: String) -> [Int] {
        ((try? regexMatches(pattern, in: text)) ?? []).map(\.offset)
    }

    private static func matchingClose(of open: Int, in characters: [Character]) -> Int? {
        var depth = 0
        for index in open..<characters.count {
            if characters[index] == "(" {
                depth += 1
            } else if characters[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
