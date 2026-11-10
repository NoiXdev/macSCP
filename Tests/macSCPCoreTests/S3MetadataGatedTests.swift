import Foundation
import Testing

@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`, started from the
/// main checkout and never from a worktree).
///
/// **What this file is.** The measurements the metadata and ACL work had to
/// take by hand, once, with curl — spec sections 4.5, 4.6, 4.6.1 and 4.10 —
/// taken again by code that runs. Each case names, in its doc comment, the
/// decision in shipped source that depends on its answer. The rig is RustFS,
/// not AWS: every answer below is a statement about THAT store at that
/// version, and a result that differs from AWS's documentation is a finding
/// about the rig and not about macSCP.
///
/// **One case is a canary and not a regression test.** Spec 4.6 measured that
/// the store accepts `PUT /<bucket>/<key>?acl` with a `200` and keeps nothing,
/// and that finding is what removed the visibility toggle from this project
/// (spec section 3, `ObjectMetadataProvider`'s "there is no `setACL`, and that
/// is a decision, not an omission"). If this store ever starts honouring that
/// write, `anObjectACLWriteIsAcceptedAndTheStoreKeepsNothing` turns red, and
/// the red is the signal that a shipped decision wants revisiting.
///
/// **Three cases take measurements nobody had taken**, assumed during Tasks 2
/// and 5: whether the store keeps an empty custom metadata value (it does,
/// empty), whether it keeps one outside ASCII (macSCP now sends such a value as
/// an RFC 2047 encoded-word and decodes it on the way back, so it reads back as
/// typed; three further cases measure a long value, a value another tool
/// wrote raw, and the raw request that used to fail), and whether
/// a metadata `REPLACE` copy changes an object's effective ACL (it does not,
/// byte for byte). Each of them says in its own doc comment what it measured
/// and what it did NOT.
///
/// **Task 4 of the non-ASCII plan (2026-11-10) withdraws** the middle clause
/// of the sentence above, which read, verbatim: "whether it keeps one outside
/// ASCII (macSCP's own request never gets there — 403 `SignatureDoesNotMatch`,
/// which is a defect the case records)". The defect is fixed in shipped code
/// (the value is encoded before it is signed), and the case that recorded it
/// asserts the round trip now. The same sentence's opening, "Three cases take
/// measurements nobody had taken", is unchanged and still counts three
/// measurements, not three cases: the non-ASCII measurement is four cases now.
///
/// Creates and deletes its OWN throwaway buckets (`macscp-mg-<purpose>-<hex>`);
/// the rig's `macscp-seed`, `macscp-second` and `macscp-probe-lock` are never
/// named by a request. That is why the connection is opened in bucket-list
/// mode (`startsAtBucketList`): `connect` in bucket mode probes with a listing
/// of the config's own bucket, which is `macscp-seed`, and the FIVE sibling
/// gated suites do send that read-only probe — counted 2026-11-04 with
/// `/usr/bin/grep -rln 'S3FileSystem.connect(S3SettingsRig.config' Tests/macSCPCoreTests/S3*GatedTests.swift`,
/// which names `S3BucketSettingsGatedTests`, `S3CORSGatedTests`,
/// `S3CreateBucketGatedTests`, `S3ObjectLockGatedTests` and
/// `S3VersionsGatedTests` — and, since this sentence quotes the pattern, THIS
/// file as a sixth, which is this line and not a call. Re-run after writing
/// it: the listing is six files and `-rno … | wc -l` counts 12 occurrences,
/// of which 11 are call sites in the five suites and the twelfth is the
/// sentence you are reading. **No retention of any kind is ever set
/// here**, and COMPLIANCE least of all: a bucket this suite means to delete
/// must stay deletable, and a COMPLIANCE retention on one it created could not
/// be lifted by anyone. The cleanup removes every version and delete marker
/// before the bucket, and refuses a bucket whose name this suite did not mint.
///
/// **The owner's canonical user id never leaves this process.** `#expect`
/// reports the source text of the expression it checks, so every property of
/// the ACL body is reduced to a `Bool` before the expectation, and the printed
/// lines carry booleans and lengths — never a body, an id, a credential or an
/// endpoint.
///
/// **Figures go to standard output** as `[S3MetadataGated] ...` lines, beside
/// the assertion that does not depend on them. No case asserts a wall-clock
/// ceiling: a duration is printed, never bounded.
///
/// **The plants that measured these cases' sensitivity**, run 2026-11-04 with
/// the rig up and the tree clean, each reported `RED` and named the case that
/// caught it. They are written here in the form they were run, so a later
/// reader lands on the same result rather than on a retyped approximation
/// (`scripts/mutation-probe` reverts index-safely and refuses a dirty tree,
/// and reports `PLANT CHANGED NOTHING` when an anchor has moved — which is the
/// loud miss a hand-rolled plant does not give you):
///
/// ```
/// MACSCP_ITEST=1 scripts/mutation-probe --filter 'S3MetadataGatedTests/(anObjectACLWriteIsAcceptedAndTheStoreKeepsNothing|whetherAMetadataReplaceCopyChangesTheObjectsACL)' --label 'PA the policy read back differs' --apply "sed -i '' 's/unchanged = before.1 == after.1\$/unchanged = false/' Tests/macSCPCoreTests/S3MetadataGatedTests.swift"
/// MACSCP_ITEST=1 scripts/mutation-probe --filter S3MetadataGatedTests/aMetadataReplaceAddsOneVersionWhoseEntityTagIsTheOneItWasCopiedFrom --label 'PB the tags disagree' --apply "sed -i '' 's/tagsAgree = sourceTag != nil \&\& sourceTag == newTag/tagsAgree = false/' Tests/macSCPCoreTests/S3MetadataGatedTests.swift"
/// MACSCP_ITEST=1 scripts/mutation-probe --filter S3MetadataGatedTests/theLiveObjectACLBodyHasTheFourPropertiesTheParserWasWrittenFor --label 'PC the policy came back with text nodes' --apply "sed -i '' 's/whitespaceBetweenElements = Self.hasWhitespaceBetweenElements(body)\$/whitespaceBetweenElements = true/' Tests/macSCPCoreTests/S3MetadataGatedTests.swift"
/// ```
///
/// PA reddened BOTH cases it filtered, which is the point of running it as one
/// plant: the same comparison carries the canary and the ruling-5.2
/// measurement. Four earlier plants of the same cases, applied by script
/// rather than by a committed command line, each also came back RED: the
/// policy after the write made to differ by appending `<Grant/>` (the canary),
/// the same in the copy case, `newTag` made to carry a minted suffix, and the
/// body handed to `hasWhitespaceBetweenElements` with `"> <"` appended.
///
/// What no plant here establishes: SCOPE. These probes show the cases notice
/// the answers changing; they say nothing about an answer this file never
/// asks for.
@Suite(
    "S3 object metadata and ACLs against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
struct S3MetadataGatedTests {

    /// The custom metadata value a case sends and reads back. Named so that
    /// the comparison is one expression and the value is written once.
    private static let noteValue = "set-by-suite"
    /// A value outside ASCII, for the round-trip nobody had measured. HTTP
    /// header values are not UTF-8 by default, so this can round-trip, be
    /// mangled, or be refused.
    private static let nonASCIIValue = "Jahresübersicht-日本語"
    /// A value whose single encoded-word is past RFC 2047's 75-character cap:
    /// 40 repetitions of a 14-character, 21-byte unit.
    private static let longNonASCIIValue = String(repeating: "übersicht-日本語-", count: 40)

    // MARK: Spec 4.5 — a metadata change is a copy

    /// Spec 4.5, first half: the `REPLACE` copy onto the same key answers 200
    /// and a `HEAD` afterwards reports what was sent.
    ///
    /// The decision that rests on it: `S3FileSystem.setMetadata` IS this copy
    /// (`x-amz-metadata-directive: REPLACE`, one `x-amz-meta-` header per
    /// custom pair) followed by a `HEAD` whose answer must agree with what was
    /// sent — `setMetadataUnconfirmedReason` is thrown when it does not. A
    /// store that accepted the copy and dropped the headers would make every
    /// metadata edit in the app report "not confirmed".
    ///
    /// The raw copy is sent first, built the way a person reading the store's
    /// documentation would write it, so the answer is the STORE's and not
    /// `setMetadata`'s read-back; the capability is then run on the same key.
    @Test func aMetadataReplaceCopyIsAcceptedAndTheHeadAfterwardsReportsWhatWasSent() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "replace")
        guard let rig else { return }

        var failure: (any Error)?
        var copyStatus: Int?
        var bodyIsCopyResult: Bool?
        var headStatus: Int?
        var headContentType: String?
        var headNote: String?
        var capabilityError: (any Error)?
        var capabilityRead: ObjectMetadata?
        do {
            _ = try await rig.put("doc.txt", Data("hello".utf8), contentType: "text/plain")
            let (body, response) = try await rig.replaceCopy(
                "doc.txt",
                headers: ["content-type": "text/markdown", "x-amz-meta-note": Self.noteValue])
            copyStatus = response.statusCode
            bodyIsCopyResult = String(decoding: body, as: UTF8.self).contains("<CopyObjectResult")
            let head = try await rig.head("doc.txt")
            headStatus = head.statusCode
            headContentType = head.value(forHTTPHeaderField: "Content-Type")
            headNote = head.value(forHTTPHeaderField: "x-amz-meta-note")

            // The capability, on the same key, sending a second set of values
            // so a green result cannot be the raw copy's leftovers.
            let sent = ObjectMetadata(
                contentType: "application/json", cacheControl: "max-age=60",
                contentDisposition: nil, custom: ["stage": "capability"], entityTag: nil)
            do {
                try await rig.fs.setMetadata(sent, ofKey: "doc.txt", inBucket: rig.bucket)
                capabilityRead = try await rig.fs.metadata(ofKey: "doc.txt", inBucket: rig.bucket)
            } catch {
                capabilityError = error
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.5 replace copy: status=\(copyStatus.map(String.init) ?? "-")"
                + " headStatus=\(headStatus.map(String.init) ?? "-")"
                + " headType=\(headContentType ?? "-") notePresent=\(headNote != nil)"
                + " capabilityThrew=\(capabilityError != nil)")
        #expect(failure == nil)
        #expect(copyStatus == 200)
        #expect(bodyIsCopyResult == true)
        #expect(headStatus == 200)
        #expect(headContentType == "text/markdown")
        #expect(headNote == Self.noteValue)
        #expect(capabilityError == nil)
        #expect(capabilityRead?.contentType == "application/json")
        #expect(capabilityRead?.cacheControl == "max-age=60")
        #expect(capabilityRead?.custom == ["stage": "capability"])
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// Spec 4.5, second half: the version listing grows by one, and the new
    /// version's `ETag` is IDENTICAL to the one it was copied from.
    ///
    /// The decisions that rest on it: spec 6.1's version sheet tells a
    /// metadata-only version from a content change by exactly that equal
    /// ETag, and `S3FileSystem.metadata(_:confirms:)` deliberately does NOT
    /// compare the entity tag for the same reason. A store that minted a new
    /// ETag for a metadata copy would make every metadata edit read as a
    /// content change in the sheet.
    @Test func aMetadataReplaceAddsOneVersionWhoseEntityTagIsTheOneItWasCopiedFrom() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "version")
        guard let rig else { return }

        var failure: (any Error)?
        var versionsBefore = 0
        var versionsAfter = 0
        var sourceTag: String?
        var newTag: String?
        var newVersionIsAnother: Bool?
        do {
            let v1 = try await rig.put("doc.txt", Data("content".utf8), contentType: "text/plain")
            let before = try await rig.fs.versions(ofKey: "doc.txt", inBucket: rig.bucket)
            versionsBefore = before.count
            sourceTag = before.first(where: { $0.versionId == v1 })?.entityTag
            _ = try await rig.replaceCopy(
                "doc.txt", headers: ["content-type": "text/markdown"])
            let after = try await rig.fs.versions(ofKey: "doc.txt", inBucket: rig.bucket)
            versionsAfter = after.count
            let latest = after.first(where: \.isLatest)
            newTag = latest?.entityTag
            newVersionIsAnother = latest.map { $0.versionId != v1 }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        let tagsAgree = sourceTag != nil && sourceTag == newTag
        print(
            "[S3MetadataGated] 4.5 versions: before=\(versionsBefore) after=\(versionsAfter)"
                + " newVersionIsAnother=\(newVersionIsAnother.map(String.init) ?? "-")"
                + " etagUnchanged=\(tagsAgree)")
        #expect(failure == nil)
        #expect(versionsBefore == 1)
        #expect(versionsAfter == versionsBefore + 1)
        #expect(newVersionIsAnother == true)
        #expect(tagsAgree, "the metadata copy minted a new entity tag")
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Spec 4.6 and 4.6.1 — ACLs answer and do not store

    /// Spec 4.6 and 4.6.1: both ACL reads answer 200, and 4.6.1 measured
    /// their bodies byte-identical.
    ///
    /// The decision that rests on it: `ObjectMetadataProvider.acl` returns
    /// `nil` for a `501` and a policy for a `200`, and `S3ACLXML.parse`
    /// decides that on the status alone. A store answering `?acl` with
    /// anything but a policy would send the sheet's ACL section down its
    /// not-offered arm.
    @Test func bothACLReadsAnswerWithAPolicy() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "aclread")
        guard let rig else { return }

        var failure: (any Error)?
        var bucketStatus: Int?
        var objectStatus: Int?
        var bodiesIdentical: Bool?
        var bodyLength: Int?
        var rootIsPolicy: Bool?
        do {
            _ = try await rig.put("a.txt", Data("a".utf8), contentType: "text/plain")
            let bucketACL = try await rig.bucketACL()
            let objectACL = try await rig.objectACL("a.txt")
            bucketStatus = bucketACL.0
            objectStatus = objectACL.0
            bodiesIdentical = bucketACL.1 == objectACL.1
            bodyLength = objectACL.1.count
            rootIsPolicy = objectACL.1.contains("<AccessControlPolicy")
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.6 acl reads: bucket=\(bucketStatus.map(String.init) ?? "-")"
                + " object=\(objectStatus.map(String.init) ?? "-")"
                + " bodiesIdentical=\(bodiesIdentical.map(String.init) ?? "-")"
                + " objectBodyCharacters=\(bodyLength.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(bucketStatus == 200)
        #expect(objectStatus == 200)
        #expect(rootIsPolicy == true)
        #expect(bodiesIdentical == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// **The canary.** Spec 4.6: `PUT /<bucket>/<key>?acl` with
    /// `x-amz-acl: public-read` answers 200, and the policy read back
    /// afterwards is UNCHANGED — the store accepts an ACL write and keeps
    /// nothing.
    ///
    /// The decision that rests on it: `ObjectMetadataProvider` has no
    /// `setACL`, the visibility toggle was removed from the app (spec section
    /// 3), and `NoACLWriteGuardTests` holds the absence structurally. A red
    /// here means this store started honouring the write, which is the one
    /// piece of evidence that would reopen that decision.
    ///
    /// Neither policy body is printed or named in an expectation: the
    /// comparison is a `Bool` computed before the expectation, so the owner's
    /// canonical user id cannot reach a failure message.
    @Test func anObjectACLWriteIsAcceptedAndTheStoreKeepsNothing() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "aclwrite")
        guard let rig else { return }

        var failure: (any Error)?
        var writeStatus: Int?
        var unchanged: Bool?
        var grantCount: Int?
        var singleGrantIsUnnamedFullControl: Bool?
        do {
            _ = try await rig.put("a.txt", Data("a".utf8), contentType: "text/plain")
            let before = try await rig.objectACL("a.txt")
            writeStatus = try await rig.putObjectACL("a.txt", canned: "public-read")
            let after = try await rig.objectACL("a.txt")
            unchanged = before.1 == after.1
            let parsed = try S3ACLXML.parse(Data(after.1.utf8), status: after.0)
            grantCount = parsed?.grants.count
            singleGrantIsUnnamedFullControl = parsed?.grants.count == 1
                && parsed?.grants.first?.permission == "FULL_CONTROL"
                && parsed?.grants.first?.holderIsUnnamed == true
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.6 acl write: status=\(writeStatus.map(String.init) ?? "-")"
                + " policyUnchanged=\(unchanged.map(String.init) ?? "-")"
                + " grants=\(grantCount.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(writeStatus == 200)
        #expect(
            unchanged == true,
            "the store kept an ACL write: the no-ACL-write decision rests on it keeping none")
        #expect(singleGrantIsUnnamedFullControl == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// Spec 4.6 and 4.6.1: `GET /<bucket>?ownershipControls` answers 501 with
    /// `NotImplemented`.
    ///
    /// The decision that rests on it: `S3FileSystem.mapErrorStatus` handles
    /// that status, and the `501`-is-`nil` arm of `S3ACLXML.parse` was
    /// generalised from exactly this neighbouring call — the ACL read itself
    /// answers 200 here, which the case above measures.
    @Test func theOwnershipControlsReadIsNotImplemented() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "ownership")
        guard let rig else { return }

        var failure: (any Error)?
        var status: Int?
        var code: String?
        do {
            let answer = try await rig.ownershipControls()
            status = answer.0
            code = S3VersionsGatedTests.element("Code", in: answer.1)
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.6 ownershipControls: status=\(status.map(String.init) ?? "-")"
                + " code=\(code ?? "-")")
        #expect(failure == nil)
        #expect(status == 501)
        #expect(code == "NotImplemented")
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// Spec 4.6.1's four parser properties, against the body the store
    /// returns NOW rather than against the committed fixture: a test that
    /// compares the parser's fixture to itself measures nothing.
    ///
    /// The decisions that rest on it are the four `S3ACLXML` doc comment
    /// states: attributes are not read, so `xsi:type="CanonicalUser"` on an
    /// empty `Grantee` cannot be mistaken for a named holder; fields are keyed
    /// on the element path, so `DisplayName` before `ID` inside `Owner` is
    /// read correctly; no text node is relied on for structure; and a 501 is
    /// decided on the status (the case above).
    ///
    /// The fourth check is the agreement one: the live body is fed through
    /// `S3ACLXML.parse` and the parse is compared with the live bytes — the
    /// owner's two fields against the text of the elements in the body
    /// itself, never against a literal, so no id is written into this file or
    /// into a failure message.
    @Test func theLiveObjectACLBodyHasTheFourPropertiesTheParserWasWrittenFor() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "aclshape")
        guard let rig else { return }

        var failure: (any Error)?
        var granteePresent: Bool?
        var granteeIsSelfClosing: Bool?
        var granteeCarriesCanonicalUserType: Bool?
        var granteeNamesNobodyInside: Bool?
        var displayNameBeforeID: Bool?
        var whitespaceBetweenElements: Bool?
        var parseAgreesWithTheBody: Bool?
        var parsedHolderIsUnnamed: Bool?
        do {
            _ = try await rig.put("a.txt", Data("a".utf8), contentType: "text/plain")
            let (status, body) = try await rig.objectACL("a.txt")
            #expect(status == 200)
            let grantee = Self.granteeProperties(in: body)
            granteePresent = grantee != nil
            granteeIsSelfClosing = grantee?.selfClosing
            granteeCarriesCanonicalUserType = grantee?.canonicalUserType
            granteeNamesNobodyInside = grantee?.namesNobodyInside
            displayNameBeforeID = Self.ownerListsDisplayNameBeforeID(in: body)
            whitespaceBetweenElements = Self.hasWhitespaceBetweenElements(body)

            let parsed = try S3ACLXML.parse(Data(body.utf8), status: status)
            let owner = Self.ownerElement(in: body)
            parseAgreesWithTheBody =
                parsed?.ownerID == owner.flatMap { S3VersionsGatedTests.element("ID", in: $0) }
                && parsed?.ownerDisplayName
                    == owner.flatMap { S3VersionsGatedTests.element("DisplayName", in: $0) }
                && parsed?.grants.count == 1
                && parsed?.grants.first?.permission
                    == S3VersionsGatedTests.element("Permission", in: body)
            parsedHolderIsUnnamed = parsed?.grants.first?.holderIsUnnamed
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.6.1 parser properties:"
                + " granteePresent=\(granteePresent.map(String.init) ?? "-")"
                + " selfClosing=\(granteeIsSelfClosing.map(String.init) ?? "-")"
                + " canonicalUserType=\(granteeCarriesCanonicalUserType.map(String.init) ?? "-")"
                + " namesNobodyInside=\(granteeNamesNobodyInside.map(String.init) ?? "-")"
                + " displayNameBeforeID=\(displayNameBeforeID.map(String.init) ?? "-")"
                + " whitespaceBetweenElements=\(whitespaceBetweenElements.map(String.init) ?? "-")"
                + " parseAgrees=\(parseAgreesWithTheBody.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(granteePresent == true)
        #expect(granteeIsSelfClosing == false)
        #expect(granteeCarriesCanonicalUserType == true)
        #expect(granteeNamesNobodyInside == true)
        #expect(displayNameBeforeID == true)
        #expect(whitespaceBetweenElements == false)
        #expect(parseAgreesWithTheBody == true)
        #expect(parsedHolderIsUnnamed == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Spec 4.10 — a single-part REPLACE copy of 8 MiB

    /// Spec 4.10: an 8 MiB object, then a `REPLACE` copy onto itself answers
    /// 200, and `HEAD` reports `content-length: 8388608` with the new
    /// `content-type`. So the mechanism is not limited at small sizes.
    ///
    /// The decision that rests on it: `setMetadata` sends ONE single-part
    /// copy and never falls back to a multipart copy, so a store that refused
    /// a copy of this size would make metadata uneditable on ordinary files.
    ///
    /// **No case near the 5 GiB ceiling.** Spec 4.10 names it as not
    /// measured and section 3 names the consequence; an unmeasured ceiling
    /// stays unmeasured rather than becoming a test that takes minutes and
    /// proves nothing. The elapsed time is PRINTED, beside assertions that do
    /// not depend on it: a ceiling would measure the runner.
    @Test func aReplaceCopyOfEightMiBIsAcceptedAndTheObjectKeepsItsLength() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "large")
        guard let rig else { return }
        let size = 8 * 1024 * 1024

        var failure: (any Error)?
        var copyStatus: Int?
        var headLength: String?
        var headContentType: String?
        var elapsed: Duration = .zero
        do {
            _ = try await rig.put(
                "big.bin", Data(repeating: 0x7A, count: size),
                contentType: "application/octet-stream")
            let clock = ContinuousClock()
            let started = clock.now
            let (_, response) = try await rig.replaceCopy(
                "big.bin", headers: ["content-type": "video/mp4"])
            elapsed = clock.now - started
            copyStatus = response.statusCode
            let head = try await rig.head("big.bin")
            headLength = head.value(forHTTPHeaderField: "Content-Length")
            headContentType = head.value(forHTTPHeaderField: "Content-Type")
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] 4.10 copy of \(size) bytes: status=\(copyStatus.map(String.init) ?? "-")"
                + " headLength=\(headLength ?? "-") headType=\(headContentType ?? "-")"
                + " copyTook=\(elapsed)")
        #expect(failure == nil)
        #expect(copyStatus == 200)
        #expect(headLength == String(size))
        #expect(headContentType == "video/mp4")
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Three measurements nobody had taken

    /// **Measurement, not previously taken.** Does the store keep a custom
    /// metadata value that is EMPTY? The metadata sheet lets a pair carry a
    /// name and an empty value and a `REPLACE` copy sends it, so a store that
    /// drops the header and one that keeps it as an empty string are both
    /// reachable from the UI — and the read-back path behaves differently for
    /// each: `S3FileSystem.metadata(_:confirms:)` compares the custom pairs as
    /// a whole, so a dropped header makes `setMetadata` throw
    /// `setMetadataUnconfirmedReason` on a write the store accepted.
    ///
    /// Both halves are measured: the raw copy and `HEAD` (the store's own
    /// answer), then the capability (what the person would see).
    ///
    /// **The answer, 2026-11-04 on rustfs 1.0.4:** the store keeps the header
    /// AND keeps it empty, so neither `setMetadata` nor the sheet has anything
    /// to handle — the write confirms and the pair reads back as it was sent.
    /// The assumption this retires is that it might not.
    @Test func aCustomMetadataValueThatIsEmpty() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "emptyvalue")
        guard let rig else { return }

        var failure: (any Error)?
        var copyStatus: Int?
        var headerPresent: Bool?
        var headerValueIsEmpty: Bool?
        var readCustom: [String: String]?
        var capabilityError: (any Error)?
        var capabilityReason: String?
        do {
            _ = try await rig.put("e.txt", Data("e".utf8), contentType: "text/plain")
            let (_, response) = try await rig.replaceCopy(
                "e.txt", headers: ["content-type": "text/plain", "x-amz-meta-empty": ""])
            copyStatus = response.statusCode
            let head = try await rig.head("e.txt")
            let value = head.value(forHTTPHeaderField: "x-amz-meta-empty")
            headerPresent = value != nil
            headerValueIsEmpty = value?.isEmpty

            let sent = ObjectMetadata(
                contentType: "text/plain", cacheControl: nil, contentDisposition: nil,
                custom: ["empty": ""], entityTag: nil)
            do {
                try await rig.fs.setMetadata(sent, ofKey: "e.txt", inBucket: rig.bucket)
            } catch {
                capabilityError = error
                if case .protocolError(let reason) = error as? RemoteFSError {
                    capabilityReason = reason
                }
            }
            readCustom = try await rig.fs.metadata(ofKey: "e.txt", inBucket: rig.bucket).custom
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] empty custom value: copy=\(copyStatus.map(String.init) ?? "-")"
                + " headerPresent=\(headerPresent.map(String.init) ?? "-")"
                + " headerValueIsEmpty=\(headerValueIsEmpty.map(String.init) ?? "-")"
                + " capabilityThrew=\(capabilityError != nil)"
                + " unconfirmed=\(capabilityReason == S3FileSystem.setMetadataUnconfirmedReason)"
                + " readBackKeys=\(readCustom.map { $0.keys.sorted().joined(separator: ",") } ?? "-")")
        #expect(failure == nil)
        #expect(copyStatus == 200)
        // Measured 2026-11-04 on rustfs 1.0.4: the store KEEPS the header and
        // keeps it empty, so nothing drops out from under the read-back and
        // `setMetadata` confirms the write.
        #expect(headerPresent == true)
        #expect(headerValueIsEmpty == true)
        #expect(capabilityError == nil)
        #expect(readCustom == ["empty": ""])
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// **Measurement: a custom metadata value outside ASCII round-trips.**
    /// Does the store keep a custom metadata value outside ASCII, and does the
    /// capability hand it back as typed? HTTP header values are not UTF-8 by
    /// default, so a store can keep one, mangle it, or refuse it.
    ///
    /// The decisions in shipped source that rest on it:
    /// `S3FileSystem.replacementHeaders(for:)` sends such a value as an
    /// RFC 2047 encoded-word, so the header the signer signs and the transport
    /// sends is ASCII; `S3FileSystem.objectMetadata(from:)` decodes it on the
    /// way back; and `metadata(_:confirms:)` compares the decoded value with
    /// what was typed. This case sends through the capability, reads the raw
    /// header off a `HEAD` to see the wire form, and reads it back through the
    /// capability.
    ///
    /// **What it asserts:** the write is confirmed (`setMetadata` does not
    /// throw), the value read back equals what was typed, the header the store
    /// holds is plain ASCII and decodes to what was typed.
    ///
    /// **What it does NOT assert:** which encoding the store reports. The
    /// encoded-word is printed as a length and a boolean, never as a value.
    ///
    /// **Task 4 of the non-ASCII plan (2026-11-10) withdraws** the record this
    /// case used to be, in place. The case was named
    /// `aCustomMetadataValueOutsideASCII` and its doc comment said, verbatim:
    ///
    /// > **Measurement, not previously taken, and it found a defect.** Does the
    /// > store keep a custom metadata value outside ASCII? HTTP header values
    /// > are not UTF-8 by default, so this can round-trip, be mangled, or be
    /// > refused. `S3FileSystem.replacementHeaders` refuses only control
    /// > characters, so the sheet does not restrict the value's characters and
    /// > whichever of the three it is, it is already reachable from the UI.
    /// >
    /// > **What was measured here, 2026-11-04 on rustfs 1.0.4.** The request
    /// > never reaches the store's metadata handling: it is answered **403**
    /// > with `<Code>SignatureDoesNotMatch</Code>`, and the capability maps that
    /// > to `.authenticationFailed`. So what a person typing an umlaut into the
    /// > sheet is told is to check their access key. The 403 is this project's
    /// > own request being inconsistent — what the signer signed and what the
    /// > transport put on the wire disagree for a non-ASCII header value — and
    /// > `S3FileSystem.signedRequest`'s doc comment already names that shape:
    /// > "indistinguishable, from the outside, from a key that lacks a
    /// > permission".
    /// >
    /// > **And the store would have kept it.** Measured by hand the same day,
    /// > with curl's own SigV4 (which signs exactly the bytes it sends, and
    /// > listed `x-amz-meta-label` in `SignedHeaders`), on a throwaway bucket
    /// > that was deleted afterwards: the same `REPLACE` copy answered **200**,
    /// > and `HEAD` reported the value as an RFC 2047 encoded-word,
    /// > `=?UTF-8?B?...?=`, whose payload decodes to the bytes that were sent.
    /// > So the store accepts such a value and reports it encoded. **Not
    /// > measured:** what `setMetadata` would do once the 403 is fixed — its
    /// > read-back compares the value as typed, and an encoded-word is not that
    /// > string, which reads like a second layer but has not been run.
    /// >
    /// > **This case therefore asserts a defect, deliberately.** The figures are
    /// > the record; the day the request is made consistent, this case turns red
    /// > and the measurement is taken again rather than assumed.
    ///
    /// Withdrawn: the sentence "This case therefore asserts a defect,
    /// deliberately" and the assertions under it (`copy == 403`,
    /// `refusalCode == "SignatureDoesNotMatch"`, `capabilityError != nil`,
    /// `capabilityErrorIsAuthenticationFailed == true`). The defect it recorded
    /// is fixed in shipped code, as that paragraph said the day it would turn
    /// red. The "Not measured" sentence is answered by this case: the read-back
    /// compares the decoded value, and there was no second layer once both
    /// sides are decoded. The 403 itself is still true of a raw non-ASCII
    /// header signed by the project's signer, and that is no longer the
    /// product's path; it is kept as a canary by
    /// `aRawNonASCIIHeaderFromTheProjectsOwnSignerIsStillRefused`.
    @Test func aCustomMetadataValueOutsideASCIIRoundTripsThroughTheCapability() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "nonascii")
        guard let rig else { return }

        var failure: (any Error)?
        var capabilityError: (any Error)?
        var capabilityRoundTrips: Bool?
        var wireValueCharacters: Int?
        var wireValueIsASCII: Bool?
        var wireValueDecodesToTheSentValue: Bool?
        var wireValueIsAnEncodedWord: Bool?
        do {
            _ = try await rig.put("n.txt", Data("n".utf8), contentType: "text/plain")
            let sent = ObjectMetadata(
                contentType: "text/plain", cacheControl: nil, contentDisposition: nil,
                custom: ["label": Self.nonASCIIValue], entityTag: nil)
            do {
                try await rig.fs.setMetadata(sent, ofKey: "n.txt", inBucket: rig.bucket)
                let after = try await rig.fs.metadata(ofKey: "n.txt", inBucket: rig.bucket)
                capabilityRoundTrips = after.custom["label"] == Self.nonASCIIValue
            } catch {
                capabilityError = error
            }
            let head = try await rig.head("n.txt")
            if let wire = head.value(forHTTPHeaderField: "x-amz-meta-label") {
                wireValueCharacters = wire.count
                wireValueIsASCII = wire.unicodeScalars.allSatisfy { $0.value < 0x80 }
                wireValueDecodesToTheSentValue = RFC2047.decoded(wire) == Self.nonASCIIValue
                wireValueIsAnEncodedWord = wire.hasPrefix("=?") && wire.hasSuffix("?=")
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] non-ASCII custom value via the capability:"
                + " capabilityThrew=\(capabilityError != nil)"
                + " capabilityRoundTrips=\(capabilityRoundTrips.map(String.init) ?? "-")"
                + " wireValueCharacters=\(wireValueCharacters.map(String.init) ?? "-")"
                + " wireValueIsASCII=\(wireValueIsASCII.map(String.init) ?? "-")"
                + " wireValueIsAnEncodedWord=\(wireValueIsAnEncodedWord.map(String.init) ?? "-")"
                + " wireValueDecodesToTheSentValue="
                + "\(wireValueDecodesToTheSentValue.map(String.init) ?? "-")"
                + " sentCharacters=\(Self.nonASCIIValue.count)")
        #expect(failure == nil)
        #expect(capabilityError == nil)
        #expect(capabilityRoundTrips == true)
        #expect(wireValueIsASCII == true)
        #expect(wireValueDecodesToTheSentValue == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// Review Focus 4 of the non-ASCII plan: a value long enough that ONE
    /// encoded-word is far past RFC 2047's 75-character cap. `RFC2047.encodedWord`
    /// emits one word of any length (the decoder accepts adjacent words), so
    /// whether a store cares was **unmeasured** until this case.
    ///
    /// The value is 560 characters and 840 bytes of UTF-8, so its single
    /// encoded-word is 1132 characters: 1120 of base64 and 12 of framing. The
    /// encoded copy is sent first, by hand, so that the store's own answer
    /// (status and `<Code>`) is on record; the capability then writes and reads
    /// the same value back, and the case asserts that the decoded read-back
    /// equals what was sent.
    ///
    /// **Measured 2026-11-10 on the rig:** the store ACCEPTS the one long word
    /// (copy 200, no refusal code), so what is asserted is acceptance and the
    /// round trip. Had it refused, the status and code it answered would have
    /// been the measurement to assert instead.
    @Test func aValueTooLongForOneEncodedWordRoundTrips() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "longvalue")
        guard let rig else { return }
        let value = Self.longNonASCIIValue
        let encoded = RFC2047.encodedWord(value)

        var failure: (any Error)?
        var rawStatus: Int?
        var rawCode: String?
        var capabilityError: (any Error)?
        var capabilityRoundTrips: Bool?
        do {
            _ = try await rig.put("long.txt", Data("n".utf8), contentType: "text/plain")
            let (body, response) = try await rig.replaceCopy(
                "long.txt", headers: ["content-type": "text/plain", "x-amz-meta-label": encoded])
            rawStatus = response.statusCode
            rawCode = S3VersionsGatedTests.element("Code", in: String(decoding: body, as: UTF8.self))
            let sent = ObjectMetadata(
                contentType: "text/plain", cacheControl: nil, contentDisposition: nil,
                custom: ["label": value], entityTag: nil)
            do {
                try await rig.fs.setMetadata(sent, ofKey: "long.txt", inBucket: rig.bucket)
                let after = try await rig.fs.metadata(ofKey: "long.txt", inBucket: rig.bucket)
                capabilityRoundTrips = after.custom["label"] == value
            } catch {
                capabilityError = error
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] long non-ASCII custom value:"
                + " sentCharacters=\(value.count) sentBytes=\(value.utf8.count)"
                + " encodedCharacters=\(encoded.count)"
                + " rawCopy=\(rawStatus.map(String.init) ?? "-") rawCode=\(rawCode ?? "-")"
                + " capabilityThrew=\(capabilityError != nil)"
                + " capabilityRoundTrips=\(capabilityRoundTrips.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(encoded.count > 75, "the value no longer exceeds the encoded-word cap this case is about")
        #expect(rawStatus == 200)
        #expect(rawCode == nil)
        #expect(capabilityError == nil)
        #expect(capabilityRoundTrips == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// Review Focus 2 of the non-ASCII plan: a value ANOTHER TOOL wrote, with
    /// raw UTF-8 bytes in the header and no encoding, must read back through
    /// the capability as what was typed, whichever form the store reports it
    /// in. curl signs exactly the bytes it sends (`--aws-sigv4`), so the write
    /// is accepted where the project's own signer's raw request is not, and
    /// the store's answer to a `HEAD` is what macSCP's read path really meets.
    ///
    /// The write is run through `SubprocessRunner`, which awaits the child
    /// without parking a cooperative-pool thread; the rig's credentials are
    /// the fixture ones spelled in `S3SettingsRig.config` and
    /// `docker/test-server/compose.yml`. Only the status and the refusal
    /// `<Code>` of curl's answer are read, never a body.
    ///
    /// **What it asserts:** curl's copy is answered 200, and the capability's
    /// read of the object returns the typed value. **What it prints and does
    /// not assert:** whether the store reported the header encoded or raw to
    /// the project's transport.
    @Test func aValueAnotherToolWroteRawReadsBackThroughTheCapabilityAsTyped() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "rawcurl")
        guard let rig else { return }

        var failure: (any Error)?
        var curlStatus: Int?
        var curlCode: String?
        var capabilityError: (any Error)?
        var capabilityReadsAsTyped: Bool?
        var wireValueIsAnEncodedWord: Bool?
        var wireValueIsASCII: Bool?
        do {
            _ = try await rig.put("c.txt", Data("n".utf8), contentType: "text/plain")
            let answer = try await rig.curlReplaceCopy(
                "c.txt", headers: ["content-type": "text/plain", "x-amz-meta-label": Self.nonASCIIValue])
            curlStatus = answer.status
            curlCode = answer.code
            do {
                let after = try await rig.fs.metadata(ofKey: "c.txt", inBucket: rig.bucket)
                capabilityReadsAsTyped = after.custom["label"] == Self.nonASCIIValue
            } catch {
                capabilityError = error
            }
            let head = try await rig.head("c.txt")
            if let wire = head.value(forHTTPHeaderField: "x-amz-meta-label") {
                wireValueIsAnEncodedWord = wire.hasPrefix("=?") && wire.hasSuffix("?=")
                wireValueIsASCII = wire.unicodeScalars.allSatisfy { $0.value < 0x80 }
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] non-ASCII custom value written raw by curl:"
                + " curlCopy=\(curlStatus.map(String.init) ?? "-") curlCode=\(curlCode ?? "-")"
                + " capabilityThrew=\(capabilityError != nil)"
                + " capabilityReadsAsTyped=\(capabilityReadsAsTyped.map(String.init) ?? "-")"
                + " storeReportsAnEncodedWord=\(wireValueIsAnEncodedWord.map(String.init) ?? "-")"
                + " storeReportsASCII=\(wireValueIsASCII.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(curlStatus == 200)
        #expect(capabilityError == nil)
        #expect(capabilityReadsAsTyped == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// **A canary, and the part of the old record that is still true.** A
    /// non-ASCII header value handed raw to the project's own signer and
    /// transport, bypassing the capability, is what used to be answered 403
    /// `SignatureDoesNotMatch` (see the withdrawn record in
    /// `aCustomMetadataValueOutsideASCIIRoundTripsThroughTheCapability`'s doc
    /// comment). The capability no longer sends such a request, so this is no
    /// user-visible defect; it is the reason the encoding exists. If this ever
    /// stops being refused, the signer and the transport have been made to
    /// agree on a raw non-ASCII value, and the encoding wants revisiting
    /// rather than assuming.
    ///
    /// **What it asserts:** the raw request is refused, as 403
    /// `SignatureDoesNotMatch`, which is what was measured on 2026-11-04 and
    /// again on 2026-11-10 on the same rig, and that nothing was stored raw.
    @Test func aRawNonASCIIHeaderFromTheProjectsOwnSignerIsStillRefused() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "rawsigner")
        guard let rig else { return }

        var failure: (any Error)?
        var copyStatus: Int?
        var refusalCode: String?
        var rawRoundTrips: Bool?
        do {
            _ = try await rig.put("r.txt", Data("n".utf8), contentType: "text/plain")
            let (body, response) = try await rig.replaceCopy(
                "r.txt",
                headers: ["content-type": "text/plain", "x-amz-meta-label": Self.nonASCIIValue])
            copyStatus = response.statusCode
            // Only the `<Code>` is read out, never the body: a refusal body of
            // this shape can name the request's own signing material.
            refusalCode = S3VersionsGatedTests.element("Code", in: String(decoding: body, as: UTF8.self))
            let head = try await rig.head("r.txt")
            rawRoundTrips = head.value(forHTTPHeaderField: "x-amz-meta-label") == Self.nonASCIIValue
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] non-ASCII custom value, raw through the project's signer:"
                + " copy=\(copyStatus.map(String.init) ?? "-") refusalCode=\(refusalCode ?? "-")"
                + " rawRoundTrips=\(rawRoundTrips.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(copyStatus == 403)
        #expect(refusalCode == "SignatureDoesNotMatch")
        #expect(rawRoundTrips == false)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// **Measurement, not previously taken, and the one that matters most.**
    /// Does a metadata `REPLACE` copy change an object's effective ACL?
    ///
    /// `ObjectMetadataSheet.save()` re-reads the access list after a
    /// confirmed write, and its comment says that read is DEFENSIVE rather
    /// than a measured need, because "whether that changes the file's access
    /// list is NOT measured on the rig (the measurement is carried to Task
    /// 7)". This is that measurement: the ACL is read, a metadata copy is run
    /// onto the object, and the ACL is read again.
    ///
    /// Neither body is printed or named in an expectation; the comparison is
    /// a `Bool` computed before it.
    @Test func whetherAMetadataReplaceCopyChangesTheObjectsACL() async throws {
        let rig = try await MetadataRigBucket.make(purpose: "aclcopy")
        guard let rig else { return }

        var failure: (any Error)?
        var copyStatus: Int?
        var unchanged: Bool?
        var grantsBefore: Int?
        var grantsAfter: Int?
        var holderUnnamedBefore: Bool?
        var holderUnnamedAfter: Bool?
        do {
            _ = try await rig.put("c.txt", Data("c".utf8), contentType: "text/plain")
            let before = try await rig.objectACL("c.txt")
            let parsedBefore = try S3ACLXML.parse(Data(before.1.utf8), status: before.0)
            grantsBefore = parsedBefore?.grants.count
            holderUnnamedBefore = parsedBefore?.grants.first?.holderIsUnnamed
            let (_, response) = try await rig.replaceCopy(
                "c.txt", headers: ["content-type": "text/markdown", "x-amz-meta-note": Self.noteValue])
            copyStatus = response.statusCode
            let after = try await rig.objectACL("c.txt")
            let parsedAfter = try S3ACLXML.parse(Data(after.1.utf8), status: after.0)
            grantsAfter = parsedAfter?.grants.count
            holderUnnamedAfter = parsedAfter?.grants.first?.holderIsUnnamed
            unchanged = before.1 == after.1
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3MetadataGated] acl across a metadata copy: copy=\(copyStatus.map(String.init) ?? "-")"
                + " bodyUnchanged=\(unchanged.map(String.init) ?? "-")"
                + " grantsBefore=\(grantsBefore.map(String.init) ?? "-")"
                + " grantsAfter=\(grantsAfter.map(String.init) ?? "-")"
                + " holderUnnamedBefore=\(holderUnnamedBefore.map(String.init) ?? "-")"
                + " holderUnnamedAfter=\(holderUnnamedAfter.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(copyStatus == 200)
        // Measured 2026-11-04 on rustfs 1.0.4: the policy comes back
        // BYTE-IDENTICAL across the copy, so the failure direction Task 5's
        // sheet comment argued for is the direction this store takes. The
        // re-read in `save()` stays defensive, and is now defensive against
        // something measured not to happen HERE rather than against the
        // unknown.
        #expect(
            unchanged == true,
            "a metadata copy changed the object's access list: the sheet's re-read is load-bearing")
        #expect(grantsBefore == 1)
        #expect(grantsAfter == 1)
        #expect(holderUnnamedBefore == true)
        #expect(holderUnnamedAfter == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: - Reading the live policy body

    /// The `Grantee` element's four properties, read from the body as text:
    /// `nil` when there is no such element at all.
    static func granteeProperties(in body: String)
        -> (selfClosing: Bool, canonicalUserType: Bool, namesNobodyInside: Bool)?
    {
        guard let open = body.range(of: "<Grantee"),
            let openEnd = body.range(of: ">", range: open.upperBound..<body.endIndex)
        else { return nil }
        let attributes = String(body[open.upperBound..<openEnd.lowerBound])
        let selfClosing = attributes.hasSuffix("/")
        let type = attributes.contains("xsi:type=\"CanonicalUser\"")
        guard !selfClosing,
            let close = body.range(of: "</Grantee>", range: openEnd.upperBound..<body.endIndex)
        else {
            return (selfClosing: selfClosing, canonicalUserType: type, namesNobodyInside: true)
        }
        let inside = String(body[openEnd.upperBound..<close.lowerBound])
        let namesNobody = !inside.contains("<ID>") && !inside.contains("<DisplayName>")
        return (selfClosing: selfClosing, canonicalUserType: type, namesNobodyInside: namesNobody)
    }

    /// The text between `<Owner>` and `</Owner>`, which is where the two
    /// fields whose ORDER 4.6.1 measured live.
    static func ownerElement(in body: String) -> String? {
        S3VersionsGatedTests.element("Owner", in: body)
    }

    /// Whether `DisplayName` precedes `ID` inside `Owner` — the reverse of
    /// AWS's documented order, which is why `S3ACLXML` keys on the element
    /// path and never on position.
    static func ownerListsDisplayNameBeforeID(in body: String) -> Bool? {
        guard let owner = ownerElement(in: body),
            let displayName = owner.range(of: "<DisplayName>"), let id = owner.range(of: "<ID>")
        else { return nil }
        return displayName.lowerBound < id.lowerBound
    }

    /// Whether any `>` is separated from the following `<` by whitespace. A
    /// document with none has no text nodes a parser could key on for
    /// structure.
    static func hasWhitespaceBetweenElements(_ body: String) -> Bool {
        var afterCloseAngle = false
        var sawWhitespace = false
        for character in body {
            if character == ">" {
                afterCloseAngle = true
                sawWhitespace = false
                continue
            }
            if afterCloseAngle, character.isWhitespace {
                sawWhitespace = true
                continue
            }
            if character == "<", afterCloseAngle, sawWhitespace { return true }
            afterCloseAngle = false
            sawWhitespace = false
        }
        return false
    }
}

// MARK: - The throwaway bucket

/// This suite's own small helper on `S3SettingsRig`, in the shape the four
/// sibling gated settings suites use: `RigBucket` in `S3VersionsGatedTests` is
/// private to that file and speaks different verbs (a copy naming a source
/// version, a multipart upload, raw version listings), and extracting it would
/// churn a closed suite whose cases only run behind a gate. The verbs here are
/// the metadata ones: a `REPLACE` copy, a `HEAD`, and the raw `?acl` reads and
/// write.
///
/// **Bucket-list mode, deliberately.** `connect` in bucket mode probes with a
/// listing of `S3SettingsRig.config.bucket`, which is the rig's seeded
/// `macscp-seed`; this suite names none of the rig's own buckets in any
/// request, so it starts at the account's bucket list instead, where the probe
/// is `GET /` and names no bucket. Every request below carries its bucket
/// explicitly, so the mode changes nothing else.
private struct MetadataRigBucket {
    static let namePrefix = "macscp-mg-"
    static let reserved: Set<String> = ["macscp-seed", "macscp-second", "macscp-probe-lock"]

    let fs: S3FileSystem
    let bucket: String

    /// The rig's config, starting at the bucket list so that no seeded bucket
    /// is named by the dial's probe.
    static var config: S3ConnectionConfig {
        var config = S3SettingsRig.config
        config.startsAtBucketList = true
        return config
    }

    /// A new bucket with versioning ON, or nil after recording an issue when
    /// the rig would not make one. Versioning is on for every bucket here so
    /// that the cleanup has ONE path, and because spec 4.5's version count is
    /// one of the measurements.
    ///
    /// **No retention is set, of any mode.** A COMPLIANCE retention on a
    /// bucket this suite means to delete could not be lifted by anyone.
    static func make(purpose: String) async throws -> MetadataRigBucket? {
        let fs = try await S3FileSystem.connect(config)
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "mg-" + purpose)
        precondition(bucket.hasPrefix(namePrefix) && !reserved.contains(bucket))
        let created = try await S3SettingsRig.bucketRequest("PUT", bucket, in: fs)
        #expect((200..<300).contains(created), "the rig would not create a throwaway bucket")
        guard (200..<300).contains(created) else {
            await fs.disconnect()
            return nil
        }
        try await fs.setVersioning(.enabled, ofBucket: bucket)
        // The control: versioning really is on, read back from the store.
        let state = try await fs.versioning(ofBucket: bucket)
        #expect(state == .enabled)
        return MetadataRigBucket(fs: fs, bucket: bucket)
    }

    /// Every version and delete marker, then the bucket. `true` when the
    /// bucket is gone. Refuses a bucket this suite did not mint.
    func teardown() async -> Bool {
        guard bucket.hasPrefix(Self.namePrefix), !Self.reserved.contains(bucket) else { return false }
        // Up to three passes: a listing still non-empty after them is
        // reported by the bucket delete failing, which is the check.
        for _ in 0..<3 {
            guard let entries = try? await fs.versionEntries(inBucket: bucket, prefix: "", delimiter: nil),
                !entries.isEmpty
            else { break }
            for entry in entries {
                _ = try? await S3SettingsRig.objectRequest(
                    "DELETE", bucket: bucket, key: entry.key,
                    query: [(name: "versionId", value: entry.versionId)], in: fs)
            }
        }
        let status = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)
        await fs.disconnect()
        return status.map { (200..<300).contains($0) } ?? false
    }

    /// A PUT; the new version's id.
    func put(_ key: String, _ body: Data, contentType: String) async throws -> String {
        let (_, response) = try await S3SettingsRig.objectRequest(
            "PUT", bucket: bucket, key: key, extraHeaders: ["content-type": contentType],
            body: body, in: fs)
        #expect(response.statusCode == 200)
        return response.value(forHTTPHeaderField: "x-amz-version-id") ?? ""
    }

    /// A metadata `REPLACE` copy of the object onto itself, built the way a
    /// person reading the store's documentation would write it and NOT
    /// through `S3FileSystem.setMetadata`, so the answer is the store's alone.
    func replaceCopy(_ key: String, headers: [String: String]) async throws
        -> (Data, HTTPURLResponse)
    {
        var extra = headers
        extra["x-amz-copy-source"] = "/\(bucket)/\(key)"
        extra["x-amz-metadata-directive"] = "REPLACE"
        return try await S3SettingsRig.objectRequest(
            "PUT", bucket: bucket, key: key, extraHeaders: extra, body: Data(), in: fs)
    }

    /// The same metadata `REPLACE` copy, sent by curl's own SigV4 instead of
    /// this project's signer: curl signs exactly the bytes it puts on the
    /// wire, so a raw non-ASCII header value reaches the store the way
    /// another tool would send it. Awaited through `SubprocessRunner`, which
    /// parks no cooperative-pool thread. Returns the status and the refusal
    /// `<Code>` (nil on success); the body is never returned.
    func curlReplaceCopy(_ key: String, headers: [String: String]) async throws
        -> (status: Int, code: String?)
    {
        let config = Self.config
        let url = "\(config.endpoint)/\(bucket)/\(key)"
        var arguments = [
            "--silent", "--show-error", "--request", "PUT", "--data-binary", "",
            "--aws-sigv4", "aws:amz:\(config.region):s3",
            "--user", "\(config.accessKeyID):\(config.secretAccessKey)",
            "--header", "x-amz-copy-source: /\(bucket)/\(key)",
            "--header", "x-amz-metadata-directive: REPLACE",
        ]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            arguments += ["--header", "\(name): \(value)"]
        }
        arguments += ["--write-out", "\n%{http_code}", url]
        // A deadline handed to the child is a ceiling the test did not choose
        // to assert on (CLAUDE.md, "A wall-clock ceiling in a test measures
        // the runner"), so it is the generous figure the loopback FTP cases
        // use.
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/curl"), arguments: arguments, timeout: .seconds(600))
        let text = result.stdoutText
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let status = lines.last.flatMap { Int($0) } ?? -1
        let body = lines.dropLast().joined(separator: "\n")
        return (status, S3VersionsGatedTests.element("Code", in: body))
    }

    func head(_ key: String) async throws -> HTTPURLResponse {
        try await S3SettingsRig.objectRequest("HEAD", bucket: bucket, key: key, in: fs).1
    }

    /// `GET /<bucket>/<key>?acl`: the status and the body as text.
    func objectACL(_ key: String) async throws -> (Int, String) {
        let (data, response) = try await S3SettingsRig.objectRequest(
            "GET", bucket: bucket, key: key, query: [(name: "acl", value: "")], in: fs)
        return (response.statusCode, String(decoding: data, as: UTF8.self))
    }

    /// `PUT /<bucket>/<key>?acl` with a canned ACL; the status.
    func putObjectACL(_ key: String, canned: String) async throws -> Int {
        try await S3SettingsRig.objectRequest(
            "PUT", bucket: bucket, key: key, query: [(name: "acl", value: "")],
            extraHeaders: ["x-amz-acl": canned], body: Data(), in: fs
        ).1.statusCode
    }

    /// `GET /<bucket>?acl`: the status and the body as text.
    func bucketACL() async throws -> (Int, String) {
        try await bucketSubresource("acl")
    }

    /// `GET /<bucket>?ownershipControls`: the status and the body as text.
    func ownershipControls() async throws -> (Int, String) {
        try await bucketSubresource("ownershipControls")
    }

    private func bucketSubresource(_ name: String) async throws -> (Int, String) {
        let request = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: "GET", query: [(name: name, value: "")],
            config: Self.config)
        let (data, response) = try await fs.perform(request)
        return (response.statusCode, String(decoding: data, as: UTF8.self))
    }
}
