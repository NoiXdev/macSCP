import Foundation
import MacSCPTestSupport
import Testing

/// Holds the decision that there is NO object-ACL write anywhere in the
/// package's sources.
///
/// **If this suite is red:** a source file now names the ACL sub-resource, an
/// ACL header, or an acl/grant-named function or enum case that the lists
/// below do not know. If it is another ACL READER (a display, a second
/// conformer), update the expected set in
/// `theAclAndGrantNamedDeclarationsAreExactlyTheKnownReaders` on purpose,
/// in the same change. If it is a WRITE, that is what this suite exists to
/// hold against: spec section 3 removed the control because the rig's
/// store answers `PUT ?acl` with `200` and keeps nothing.
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
/// (parentheses, declaration names) from the strict view, which shares its
/// indexing (both views preserve length).
///
/// ## What each check holds, and the positive beside it
///
/// CLAUDE.md, "Guards that name what they watch": only a NEGATIVE check can
/// go stale in silence. Every scan below runs over ALL of `Sources/`, the
/// four targets, because the request builder is public Core API
/// (`S3RequestBuilder`: `signedRequest(...)` and `perform(_:)`), so a write
/// is two lines in the App, the CLI or the entry point as much as in Core.
///
/// 1. The literal `"acl"` appears exactly once in `Sources/`, in
///    `S3FileSystem.swift`. A count, so a second one fails loudly and names
///    its file. Positive: the scan reaches every target's files.
/// 2. That occurrence sits in a call whose `method:` is the literal `"GET"`,
///    inside a function named `acl`. Both are DERIVED from the code around
///    the occurrence and asserted as values, not as absences.
/// 3. No `amz-acl` / `amz-grant` header name and no `?acl`, `&acl` or `acl=`
///    inside a literal anywhere in `Sources/`. This one IS negative; its
///    positive is that the same view still holds other header literals,
///    which the strict view would have blanked.
/// 4. The EXACT set of function and enum-case declarations in `Sources/`
///    whose names mention `acl` or `grant`. An exact set fails loudly on an
///    addition whatever it is called; a list of write verbs cannot, because
///    it is out-thought by the next verb (the first version of this check
///    was such a list, and `overwriteACL` was not on it).
/// 5. Each scan function is driven over fixtures that are not under any
///    scanned directory, both ways.
///
/// ## What this does not see
///
/// A write that spells none of the above: a sub-resource name taken from
/// somewhere that is not a literal `"acl"` and not an enum case or function
/// named for acl/grant (a name assembled from parts at run time other than a
/// split-off literal, which check 1's count catches); a variable, type or
/// property named for acl/grant, since only functions and enum cases are
/// pinned; a store reached by a request that never names the ACL at all; and
/// anything outside `Sources/` (resource files, the Tests tree).
@Suite("No object-ACL write guard")
struct NoACLWriteGuardTests {
    private static var sourcesRoot: URL { SourceCorpus.url(of: .sources) }

    private static var s3FileSystem: URL {
        sourcesRoot.appendingPathComponent("macSCPCore/S3/S3FileSystem.swift")
    }

    private static func allSwiftSources() throws -> [URL] {
        try SourceCorpus.files(under: sourcesRoot).filter { $0.pathExtension == "swift" }
    }

    // MARK: - Check 1: the sub-resource name appears exactly once

    @Test func theAclQueryNameAppearsExactlyOnceInSources() throws {
        var found: [String] = []
        for file in try Self.allSwiftSources() {
            let view = try SourceCorpus.commentFree(of: file)
            for _ in ACLWriteScan.queryNameOffsets(inCommentFree: view) {
                found.append(file.lastPathComponent)
            }
        }
        #expect(found == ["S3FileSystem.swift"], "\(found)")
    }

    @Test func theScanReachesEveryTargetAndTheFilesThatWouldCarryAWrite() throws {
        let files = try Self.allSwiftSources()
        #expect(files.count >= 100, "\(files.count)")
        for target in ["macSCPCore", "MacSCPAppKit", "MacSCPCLI", "MacSCPMain"] {
            let prefix = Self.sourcesRoot.appendingPathComponent(target).path + "/"
            #expect(files.contains { $0.path.hasPrefix(prefix) }, "no file under \(target)")
        }
        #expect(files.contains { $0.lastPathComponent == "S3FileSystem.swift" })
        #expect(files.contains { $0.lastPathComponent == "S3Uploader.swift" })
        #expect(files.contains { $0.lastPathComponent == "ObjectMetadataProvider.swift" })
    }

    // MARK: - Check 2: that one occurrence is a GET, in a function named acl

    @Test func theOneAclRequestIsAGetInsideTheFunctionNamedAcl() throws {
        let file = Self.s3FileSystem
        let inspections = try ACLWriteScan.inspect(
            code: SourceCorpus.code(of: file), commentFree: SourceCorpus.commentFree(of: file))
        #expect(inspections.count == 1, "\(inspections)")
        #expect(inspections.first?.method == "GET", "\(inspections)")
        #expect(inspections.first?.functionName == "acl", "\(inspections)")
    }

    // MARK: - Check 3: no ACL header name, in any spelling

    @Test func noSourceNamesAnAclOrGrantHeader() throws {
        var offenders: [String] = []
        for file in try Self.allSwiftSources() {
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
        let kept = try SourceCorpus.commentFree(of: Self.s3FileSystem)
        let blanked = try SourceCorpus.code(of: Self.s3FileSystem)
        #expect(kept.contains("x-amz-metadata-directive"))
        #expect(!blanked.contains("x-amz-metadata-directive"))
    }

    // MARK: - Check 4: the exact set of acl/grant-named declarations

    /// Every function and enum case in `Sources/` whose name mentions `acl`
    /// or `grant`, as `file: name`. Another reader is added HERE, on purpose.
    private static let knownAclAndGrantDeclarations = [
        "ObjectMetadataProvider.swift: acl",
        "ProtocolCapabilities.swift: acl",
        "S3ACLXML.swift: finishGrant",
        "S3FileSystem.swift: acl",
    ]

    @Test func theAclAndGrantNamedDeclarationsAreExactlyTheKnownReaders() throws {
        var found: [String] = []
        for file in try Self.allSwiftSources() {
            let code = try SourceCorpus.code(of: file)
            for name in ACLWriteScan.aclOrGrantDeclarations(inCode: code) {
                found.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(
            found.sorted() == Self.knownAclAndGrantDeclarations,
            """
            The set of acl/grant-named functions and enum cases changed. Another \
            ACL reader: update knownAclAndGrantDeclarations on purpose. A write: \
            this guard holds against it. Found: \(found.sorted())
            """)
    }

    @Test func theProviderFileDeclaresTheAclReadAndNoOtherAclNamedFunction() throws {
        let file = Self.sourcesRoot.appendingPathComponent(
            "macSCPCore/RemoteFS/ObjectMetadataProvider.swift")
        let names = ACLWriteScan.functionNames(inCode: try SourceCorpus.code(of: file))
        #expect(names.contains("acl"), "\(names)")
        let aclShaped = names.filter(ACLWriteScan.mentionsAclOrGrant)
        #expect(aclShaped == ["acl"], "\(aclShaped)")
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

    @Test func theDeclarationScanFlagsEveryAclOrGrantNamedFunctionWhateverItsVerb() throws {
        // Including the verbs a denylist did not list, and a name that is
        // only a read: the set is exact, so the scan reports all of them and
        // the suite decides.
        let names = [
            "setACL", "overwriteACL", "uploadACL", "copyACL", "clearACL", "attachGrants",
            "makePublicACL", "acl", "finishGrant",
        ]
        for name in names {
            let code = try SwiftSource.blankingCommentsAndStrings("func \(name)(key: String) {}")
            #expect(ACLWriteScan.aclOrGrantDeclarations(inCode: code) == [name], "missed: \(name)")
        }
        let unrelated = try SwiftSource.blankingCommentsAndStrings(
            "func setMetadata() {}\nfunc makePublic() {}\nfunc aclide() {}")
        #expect(ACLWriteScan.aclOrGrantDeclarations(inCode: unrelated).isEmpty)
    }

    @Test func theDeclarationScanSeesAnAclEnumCaseInEveryShapeItCanTake() throws {
        let shapes = [
            "enum PlantSubresource: String { case acl }",
            "enum Model { case posixMode, acl, none }",
            "enum Sub: String {\n    case acl = \"acl\"\n}",
            "enum Sub {\n    case aclSub(name: String)\n}",
            "enum Sub {\n    case none, grantRead\n}",
        ]
        for source in shapes {
            let code = try SwiftSource.blankingCommentsAndStrings(source)
            #expect(!ACLWriteScan.aclOrGrantDeclarations(inCode: code).isEmpty, "missed: \(source)")
        }
        let notDeclarations = try SwiftSource.blankingCommentsAndStrings(
            "switch x {\ncase .acl:\n    break\ncase .none, .other:\n    break\n}")
        #expect(ACLWriteScan.aclOrGrantDeclarations(inCode: notDeclarations).isEmpty)
    }

    @Test func aWriteRequirementOnTheProviderProtocolIsSeen() throws {
        let code = try SwiftSource.blankingCommentsAndStrings(
            """
            public protocol ObjectMetadataProvider: Sendable {
                func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL?
                func setACL(_ acl: ObjectACL, ofKey key: String, inBucket bucket: String) async throws
            }
            """)
        #expect(ACLWriteScan.aclOrGrantDeclarations(inCode: code) == ["acl", "setACL"])
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

    /// Every function and enum-case name in `code` that mentions `acl` or
    /// `grant` as a camelCase word, in source order. Enum cases are read
    /// from `case` lists that carry no pattern syntax: `case .acl:` of a
    /// `switch` starts with a dot and is skipped.
    static func aclOrGrantDeclarations(inCode code: String) -> [String] {
        let cases = ((try? regexMatches(#"\bcase\s+([^\n:{}]*)"#, in: code)) ?? []).flatMap {
            match -> [Match] in
            match.group.split(separator: ",").compactMap { piece in
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                guard let name = (try? regexMatches(#"^([A-Za-z_]\w*)"#, in: trimmed))?.first
                else { return nil }
                return Match(offset: match.offset, group: name.group)
            }
        }
        let declarations = ((try? regexMatches(#"\bfunc\s+(\w+)"#, in: code)) ?? []) + cases
        return declarations.sorted { $0.offset < $1.offset }.map(\.group).filter(mentionsAclOrGrant)
    }

    static func mentionsAclOrGrant(_ name: String) -> Bool {
        words(of: name).contains { ["acl", "acls", "grant", "grants"].contains($0) }
    }

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
