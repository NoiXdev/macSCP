import Foundation

/// Reads an object's `AccessControlPolicy` into the types
/// `ObjectMetadataProvider` speaks. Foundation's `XMLParser`, no new
/// dependency, the same approach as `S3VersionsXML`.
///
/// **This type only reads.** Core has no ACL write (see
/// `ObjectMetadataProvider`), and nothing here builds a policy.
///
/// Written against spec section 4.6.1, which took an object's ACL body from
/// the rig (a `200`) and lists the properties a parser has to handle. Three
/// are properties of that body, and a fourth is about a status answered by a
/// neighbouring call, not by this one. What this parser does about each:
///
/// - **An empty `Grantee` is a grant with no named holder.** The element is
///   present, not self-closing, and carries an `xsi:type` attribute of
///   `CanonicalUser`; the emptiness is in its CHILDREN, which hold neither an
///   `ID` nor a `DisplayName`. Attributes are not read at all, so the type
///   cannot be mistaken for a name, and the grant comes back with both fields
///   `nil`, which is what `ACLGrant.holderIsUnnamed` means.
/// - **`Owner` lists `DisplayName` before `ID`**, the reverse of the order
///   AWS documents. Fields are keyed on the element's path, never on its
///   position.
/// - **No whitespace between elements.** No text node is relied on for
///   structure; text is read only where a leaf element ends.
/// - **A `501` is an `<Error>` document, not a policy.** Section 4.6.1
///   measured that for the neighbouring ownership-controls call; the ACL read
///   itself answered `200` there, so a `501` for the ACL read is NOT
///   measured. `parse` decides it on the status alone and so never has to
///   guess from a body.
enum S3ACLXML {
    /// Reads one answer to a read of an object's ACL.
    ///
    /// - `501` is `nil`: the store does not offer object ACLs. That is a
    ///   status decision and the body is not looked at. (The `501` shape was
    ///   measured for a neighbouring call, not for this one: see
    ///   `ObjectMetadataProvider.acl`.)
    /// - Any other non-2xx goes through `S3FileSystem.mapErrorStatus`, so a
    ///   named refusal keeps its finding. `path` is what a `.notFound` would
    ///   carry; callers that know the object pass it, and the default is the
    ///   empty path `S3VersionsXML` also uses.
    /// - A 2xx whose root is not `AccessControlPolicy`, one that is not
    ///   well-formed, and a `Grant` with no `Permission` are
    ///   `.protocolError`: reading any of them as "no grants" would tell the
    ///   person nobody holds access on the strength of a document that was not
    ///   a policy.
    /// - `ID`, `DisplayName` and `Permission` are trimmed of surrounding
    ///   whitespace, and an element that is empty after that names nobody.
    ///   The permission is kept as the store spells it.
    /// - A grantee named by a `URI` and not an `ID` (a group) comes back with
    ///   the `URI` as its `granteeID`, because `ACLGrant` has no field of its
    ///   own for it; reading it as "unnamed" would present a group grant as a
    ///   grant whose holder the store did not say. An `ID`, where there is
    ///   one, wins. **This group mapping is inferred, not measured:** section
    ///   4.6.1 measured only the empty `Grantee`, and no group grantee has
    ///   been seen from this store.
    static func parse(_ body: Data, status: Int, path: String = "") throws -> ObjectACL? {
        if status == 501 { return nil }
        guard (200..<300).contains(status) else {
            throw S3FileSystem.mapErrorStatus(status, body: body, path: path)
        }
        let delegate = PolicyDelegate()
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            // An abort is the delegate's own doing, so Foundation's
            // description of it would be about the abort.
            let reason =
                delegate.abortReason
                ?? parser.parserError?.localizedDescription
                ?? "no AccessControlPolicy element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 object ACL response: \(reason)")
        }
        return ObjectACL(
            ownerID: delegate.ownerID, ownerDisplayName: delegate.ownerDisplayName,
            grants: delegate.grants)
    }

    private final class PolicyDelegate: NSObject, XMLParserDelegate {
        private(set) var sawRoot = false
        private(set) var abortReason: String?
        private(set) var ownerID: String?
        private(set) var ownerDisplayName: String?
        private(set) var grants: [ACLGrant] = []

        /// Element names from the root to the element being read.
        private var path: [String] = []
        private var currentText = ""
        private var granteeID: String?
        private var granteeDisplayName: String?
        private var granteeURI: String?
        private var permission: String?

        private static let owner = ["AccessControlPolicy", "Owner"]
        private static let grant = ["AccessControlPolicy", "AccessControlList", "Grant"]
        private static let grantee = grant + ["Grantee"]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if path.isEmpty {
                guard elementName == "AccessControlPolicy" else {
                    // Not a policy: stop reading and let the caller report it.
                    abortReason = "no AccessControlPolicy element"
                    parser.abortParsing()
                    return
                }
                sawRoot = true
            }
            path.append(elementName)
            if path == Self.grant {
                granteeID = nil
                granteeDisplayName = nil
                granteeURI = nil
                permission = nil
            }
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            let value = Self.named(currentText)
            switch path {
            case Self.owner + ["ID"]: ownerID = value
            case Self.owner + ["DisplayName"]: ownerDisplayName = value
            case Self.grantee + ["ID"]: granteeID = value
            case Self.grantee + ["DisplayName"]: granteeDisplayName = value
            case Self.grantee + ["URI"]: granteeURI = value
            case Self.grant + ["Permission"]: permission = value
            case Self.grant: finishGrant(parser)
            default: break
            }
            path.removeLast()
            currentText = ""
        }

        /// The text of a leaf, trimmed; empty is no value at all.
        private static func named(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func finishGrant(_ parser: XMLParser) {
            guard let permission else {
                abortReason = "Grant has no Permission"
                parser.abortParsing()
                return
            }
            grants.append(
                ACLGrant(
                    granteeID: granteeID ?? granteeURI, granteeDisplayName: granteeDisplayName,
                    permission: permission))
        }
    }
}
