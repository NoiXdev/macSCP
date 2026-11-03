import Foundation
import Testing

@testable import macSCPCore

/// `S3ACLXML.parse` against bodies shaped like the ones spec section 4.6.1
/// took from the rig. Every id here is a made-up 64-character hex string: the
/// shape the rig's owner id has, and nothing that belongs to any account.
@Suite("S3ACLXML", .timeLimit(.minutes(5)))
struct S3ACLXMLTests {
    /// A canonical-user id's shape (64 lowercase hex characters), synthetic.
    static let ownerID = String(repeating: "0f1e2d3c4b5a69788796a5b4c3d2e1f0", count: 2)
    static let otherID = String(repeating: "a1b2c3d4e5f60718293a4b5c6d7e8f90", count: 2)

    /// Spec section 4.6.1's body, character for character apart from the id:
    /// one line with nothing between the elements, a `Grantee` that carries
    /// `xsi:type="CanonicalUser"` and is NOT self-closing but has no children,
    /// and an `Owner` whose `DisplayName` comes BEFORE its `ID`.
    static let ownerOnlyEmptyGranteeText =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<AccessControlPolicy xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        + "<AccessControlList><Grant>"
        + "<Grantee xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:type=\"CanonicalUser\"></Grantee>"
        + "<Permission>FULL_CONTROL</Permission></Grant></AccessControlList>"
        + "<Owner><DisplayName>rustfs</DisplayName><ID>\(ownerID)</ID></Owner>"
        + "</AccessControlPolicy>"
    static var ownerOnlyEmptyGrantee: Data { Data(ownerOnlyEmptyGranteeText.utf8) }

    /// The 501 body of section 4.6.1: an `<Error>` document.
    static let notImplementedBody = Data(
        ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>NotImplemented</Code>"
            + "<Message>not implemented</Message></Error>").utf8)

    static func policy(owner: String, grants: String) -> Data {
        Data(
            ("<AccessControlPolicy xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                + owner + "<AccessControlList>" + grants + "</AccessControlList></AccessControlPolicy>").utf8)
    }

    // MARK: - The measured body

    /// The positive beside the cases below: they are only worth anything if
    /// the fixture still has the three properties that made 4.6.1 worth
    /// writing. Without this, an edit that tidied the fixture would turn the
    /// parser tests into tests of a body the store never sends.
    @Test func theFixtureHasTheShapeSectionFourSixOneMeasured() {
        let text = Self.ownerOnlyEmptyGranteeText
        #expect(text.contains("xsi:type=\"CanonicalUser\"></Grantee>"))
        #expect(text.contains("/>") == false)
        #expect(text.contains(">\n") == false)
        let display = text.range(of: "<DisplayName>")
        let id = text.range(of: "<ID>")
        #expect(display != nil && id != nil)
        if let display, let id { #expect(display.lowerBound < id.lowerBound) }
    }

    @Test func anEmptyGranteeParsesAsAnUnnamedHolderAndNotAsNothing() throws {
        let acl = try #require(try S3ACLXML.parse(Self.ownerOnlyEmptyGrantee, status: 200))
        #expect(acl.grants.count == 1)
        #expect(acl.grants[0].holderIsUnnamed)
        #expect(acl.grants[0].permission == "FULL_CONTROL")
        #expect(acl.ownerDisplayName != nil)
    }

    @Test func theXsiTypeIsNotReadAsNamingAHolder() throws {
        let acl = try #require(try S3ACLXML.parse(Self.ownerOnlyEmptyGrantee, status: 200))
        #expect(acl.grants[0].granteeID == nil)
        #expect(acl.grants[0].granteeDisplayName == nil)
    }

    @Test func theOwnerIsReadWhicheverOrderItsChildrenComeIn() throws {
        let rigOrder = try #require(try S3ACLXML.parse(Self.ownerOnlyEmptyGrantee, status: 200))
        #expect(rigOrder.ownerID == Self.ownerID)
        #expect(rigOrder.ownerDisplayName == "rustfs")

        let documentedOrder = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID><DisplayName>rustfs</DisplayName></Owner>",
            grants: "")
        let reversed = try #require(try S3ACLXML.parse(documentedOrder, status: 200))
        #expect(reversed.ownerID == Self.ownerID)
        #expect(reversed.ownerDisplayName == "rustfs")
    }

    // MARK: - Named holders

    @Test func aGranteeThatNamesItselfKeepsItsOwnIdAndNameApartFromTheOwners() throws {
        let body = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID><DisplayName>owner-name</DisplayName></Owner>",
            grants:
                "<Grant><Grantee xsi:type=\"CanonicalUser\"><ID>\(Self.otherID)</ID>"
                + "<DisplayName>grantee-name</DisplayName></Grantee><Permission>READ</Permission></Grant>")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.ownerID == Self.ownerID)
        #expect(acl.ownerDisplayName == "owner-name")
        #expect(acl.grants.count == 1)
        #expect(acl.grants[0].granteeID == Self.otherID)
        #expect(acl.grants[0].granteeDisplayName == "grantee-name")
        #expect(acl.grants[0].permission == "READ")
        #expect(acl.grants[0].holderIsUnnamed == false)
    }

    @Test func grantsComeBackInDocumentOrderWithAPermissionTheProjectHasNotSeen() throws {
        let body = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID></Owner>",
            grants:
                "<Grant><Grantee><ID>\(Self.ownerID)</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant>"
                + "<Grant><Grantee><ID>\(Self.otherID)</ID></Grantee><Permission>SOMETHING_NEW</Permission></Grant>")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.grants.map(\.permission) == ["FULL_CONTROL", "SOMETHING_NEW"])
        #expect(acl.ownerDisplayName == nil)
    }

    /// A group grantee is named by a `URI`, not an `ID`. Reading it as "no
    /// holder named" would show a public-read grant as an unnamed holder,
    /// which is the opposite of what the store said. (Carried in `granteeID`,
    /// because `ACLGrant` has no field of its own for it.)
    @Test func aGroupGranteeIsNamedByItsUriAndIsNotUnnamed() throws {
        let uri = "http://acs.amazonaws.com/groups/global/AllUsers"
        let body = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID></Owner>",
            grants:
                "<Grant><Grantee xsi:type=\"Group\"><URI>\(uri)</URI></Grantee><Permission>READ</Permission></Grant>")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.grants[0].granteeID == uri)
        #expect(acl.grants[0].holderIsUnnamed == false)
    }

    /// A swap in how the two are combined would show a group's URI in place
    /// of a named holder.
    @Test func anIdWinsOverAUriWhenAGranteeCarriesBoth() throws {
        let body = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID></Owner>",
            grants:
                "<Grant><Grantee><ID>\(Self.otherID)</ID><URI>http://example.invalid/group</URI></Grantee>"
                + "<Permission>READ</Permission></Grant>")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.grants[0].granteeID == Self.otherID)
    }

    @Test func anEmptyIdElementNamesNobody() throws {
        let body = Self.policy(
            owner: "<Owner><ID></ID><DisplayName></DisplayName></Owner>",
            grants:
                "<Grant><Grantee><ID></ID><DisplayName></DisplayName></Grantee><Permission>READ</Permission></Grant>")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.ownerID == nil)
        #expect(acl.ownerDisplayName == nil)
        #expect(acl.grants[0].holderIsUnnamed)
    }

    // MARK: - Status

    @Test func aStoreThatDoesNotImplementAclsAnswersNilAndNotAnError() throws {
        #expect(try S3ACLXML.parse(Self.notImplementedBody, status: 501) == nil)
    }

    @Test func a501IsDecidedOnTheStatusAloneWhateverTheBodyHolds() throws {
        #expect(try S3ACLXML.parse(Data(), status: 501) == nil)
    }

    @Test func aRefusalKeepsItsFindingAndTheCallersPath() {
        #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try S3ACLXML.parse(Data(), status: 403)
        }
        #expect(throws: RemoteFSError.notFound(path: "/b/k")) {
            _ = try S3ACLXML.parse(Data(), status: 404, path: "/b/k")
        }
        #expect(throws: RemoteFSError.finding(.operationNotSupported)) {
            _ = try S3ACLXML.parse(Self.notImplementedBody, status: 400)
        }
    }

    // MARK: - Documents that are not a policy

    @Test func aDocumentThatIsNotAPolicyIsAProtocolErrorAndNotAnEmptyAcl() {
        let notAPolicy = Data("<html><body>proxy error</body></html>".utf8)
        for body in [notAPolicy, Data(), Data("<AccessControlPolicy><Owner>".utf8)] {
            do {
                _ = try S3ACLXML.parse(body, status: 200)
                Issue.record("a body that is not a policy was accepted")
            } catch RemoteFSError.protocolError {
            } catch {
                Issue.record("expected .protocolError, got \(error)")
            }
        }
    }

    @Test func aGrantWithNoPermissionIsAProtocolError() {
        let body = Self.policy(
            owner: "<Owner><ID>\(Self.ownerID)</ID></Owner>",
            grants: "<Grant><Grantee><ID>\(Self.otherID)</ID></Grantee></Grant>")
        do {
            _ = try S3ACLXML.parse(body, status: 200)
            Issue.record("a grant with no permission was accepted")
        } catch RemoteFSError.protocolError {
        } catch {
            Issue.record("expected .protocolError, got \(error)")
        }
    }

    @Test func aPolicyWithNoGrantsIsAnEmptyAclAndNotNil() throws {
        let body = Self.policy(owner: "<Owner><ID>\(Self.ownerID)</ID></Owner>", grants: "")
        let acl = try #require(try S3ACLXML.parse(body, status: 200))
        #expect(acl.grants.isEmpty)
    }
}
