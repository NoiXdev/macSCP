import AppKit
import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The read-only access-list section of the metadata sheet (S3 metadata,
/// Task 5; spec section 6.5).
///
/// The section shows a policy the store reported, and offers nothing that
/// changes it: the rig's store accepts an ACL write and keeps nothing (spec
/// section 4.6), so there is no honest control to offer.
///
/// Four distinctions are held here, each of which a plausible implementation
/// gets wrong without anything going red elsewhere:
///
/// 1. `nil` from Core ("this storage offers no access lists") is not "a
///    policy that holds no grants".
/// 2. A grant whose holder the store did not name is SAID, not drawn blank.
///    That is the shape the rig really returns (spec section 4.6.1).
/// 3. A holder's identifier is labelled as an identifier, not as an id: Core
///    maps a group's URI into the same field (`ACLGrant.granteeID`), so a
///    label that said "ID" would be false of a group.
/// 4. The section holds no control: not as a rule written down, but as what
///    the hosted view contains.
@Suite("Object access-list section")
struct ObjectACLSectionTests {
    private static let locales = ["en", "de", "fr", "pl"]
    private static let target = ObjectLockTarget(bucket: "macscp-seed", key: "docs/report.txt")

    /// A synthetic canonical user id: 64 hex characters that spell a pattern
    /// no store would mint, so a fixture never looks like a real account.
    private static let syntheticOwnerID = String(repeating: "0123456789abcdef", count: 4)
    /// A group URI of the documented policy format. **Inferred, not measured
    /// on the rig** (`ACLGrant.granteeID`): the rig only ever returned the
    /// empty grantee.
    private static let groupURI = "http://acs.amazonaws.com/groups/global/AllUsers"
    private static let storeWords = "store-words-canary-7d2a"

    /// The one shape the rig returns (spec section 4.6.1).
    private static var theRigsPolicy: ObjectACL {
        ObjectACL(
            ownerID: syntheticOwnerID, ownerDisplayName: "rustfs",
            grants: [ACLGrant(granteeID: nil, granteeDisplayName: nil, permission: "FULL_CONTROL")])
    }

    private static let stored = ObjectMetadata(
        contentType: "text/plain", cacheControl: nil, contentDisposition: nil, custom: [:],
        entityTag: nil)

    @MainActor private static func loadedModel(
        _ answer: FakeObjectMetadataProvider.ACLAnswer
    ) async -> (ObjectMetadataModel, FakeObjectMetadataProvider) {
        let rig = ObjectMetadataSheetTests.Rig(stored: stored, aclAnswer: answer)
        await rig.model.load()
        return (rig.model, rig.provider)
    }

    private static func inEnglish<T>(_ body: () -> T) -> T {
        L10n.$localeOverride.withValue("en", operation: body)
    }

    // MARK: - An unnamed holder

    @MainActor @Test func anUnnamedHolderIsSaidRatherThanDrawnBlank() async throws {
        let (model, _) = await Self.loadedModel(.policy(Self.theRigsPolicy))
        for locale in Self.locales {
            let display = L10n.$localeOverride.withValue(locale) {
                ObjectACLDisplay.of(model.accessList)
            }
            guard case .policy(_, let rows) = display else {
                Issue.record("not a policy in \(locale): \(display)")
                continue
            }
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            let sentence = L10n.$localeOverride.withValue(locale) { ObjectACLLines.holderUnnamed.text }
            #expect(row.holder == [sentence], "\(locale)")
            let blank = row.holder.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            #expect(!blank, "\(locale)")
            #expect(row.permission == "FULL_CONTROL", "the permission is kept as the store spelled it")
        }
    }

    @Test func theUnnamedSentenceIsTheOneForTheShapeCoreReports() {
        let grant = ACLGrant(granteeID: nil, granteeDisplayName: nil, permission: "READ")
        #expect(grant.holderIsUnnamed)
        let row = Self.inEnglish { ObjectACLDisplay.rows(of: [grant]).first }
        #expect(row?.holder == [Self.inEnglish { ObjectACLLines.holderUnnamed.text }])
        // The positive beside it: a grant that names anyone is not told as unnamed.
        for named in [
            ACLGrant(granteeID: Self.syntheticOwnerID, granteeDisplayName: nil, permission: "READ"),
            ACLGrant(granteeID: nil, granteeDisplayName: "Ada", permission: "READ"),
        ] {
            #expect(!named.holderIsUnnamed)
            let lines = Self.inEnglish { ObjectACLDisplay.rows(of: [named]).first?.holder }
            #expect(lines?.contains(Self.inEnglish { ObjectACLLines.holderUnnamed.text }) == false)
        }
    }

    // MARK: - The store that offers none, and the policy that holds none

    @MainActor @Test func aStoreWithoutAclsSaysSoInsteadOfShowingNoGrants() async {
        let (none, provider) = await Self.loadedModel(.notOffered)
        #expect(none.accessList == .notOffered)
        #expect(provider.aclReads == [Self.target.key])

        let (empty, _) = await Self.loadedModel(
            .policy(ObjectACL(ownerID: Self.syntheticOwnerID, ownerDisplayName: "rustfs", grants: [])))

        for locale in Self.locales {
            let (notOffered, noGrants) = L10n.$localeOverride.withValue(locale) {
                (ObjectACLDisplay.of(none.accessList), ObjectACLDisplay.of(empty.accessList))
            }
            #expect(notOffered != noGrants, "\(locale)")
            #expect(notOffered == .notOffered, "\(locale)")
            guard case .policy(_, let rows) = noGrants else {
                Issue.record("zero grants did not display as a policy in \(locale)")
                continue
            }
            #expect(rows.isEmpty)
        }
        // The two sentences are different sentences in every language.
        for locale in Self.locales {
            let (offers, holds) = L10n.$localeOverride.withValue(locale) {
                (ObjectACLLines.notOffered.text, ObjectACLLines.noEntries.text)
            }
            #expect(offers != holds, "\(locale)")
        }
        #expect(ObjectACLLines.notOffered.key != ObjectACLLines.noEntries.key)
    }

    @MainActor @Test func aPolicyWithNoGrantsStillNamesItsOwner() async {
        let (model, _) = await Self.loadedModel(
            .policy(ObjectACL(ownerID: Self.syntheticOwnerID, ownerDisplayName: "rustfs", grants: [])))
        let display = Self.inEnglish { ObjectACLDisplay.of(model.accessList) }
        guard case .policy(let owner, let rows) = display else {
            Issue.record("not a policy: \(display)")
            return
        }
        #expect(rows.isEmpty)
        #expect(owner.first == "rustfs")
        #expect(owner.contains(Self.inEnglish { ObjectACLLines.identifier.english.replacingOccurrences(of: "%@", with: Self.syntheticOwnerID) }))
    }

    @MainActor @Test func anOwnerTheStoreDidNotNameIsSaidToo() async {
        let (model, _) = await Self.loadedModel(
            .policy(ObjectACL(ownerID: nil, ownerDisplayName: nil, grants: [])))
        let display = Self.inEnglish { ObjectACLDisplay.of(model.accessList) }
        guard case .policy(let owner, _) = display else {
            Issue.record("not a policy: \(display)")
            return
        }
        #expect(owner == [Self.inEnglish { ObjectACLLines.ownerUnnamed.text }])
    }

    // MARK: - What a holder's identifier is called

    /// `granteeID` holds a canonical id OR a group's URI, and Core cannot tell
    /// the section which (`ACLGrant.granteeID`). The label has to be true of
    /// both, so it is "Identifier", and it is the same label for both.
    @Test func aHolderIdentifierIsLabelledAsAnIdentifierWhetherItIsAnIdOrAUrl() {
        let english = Self.inEnglish { ObjectACLLines.identifier.english }
        #expect(english == "Identifier: %@")
        for value in [Self.syntheticOwnerID, Self.groupURI] {
            let grant = ACLGrant(granteeID: value, granteeDisplayName: nil, permission: "READ")
            for locale in Self.locales {
                let lines = L10n.$localeOverride.withValue(locale) {
                    ObjectACLDisplay.rows(of: [grant]).first?.holder
                }
                let expected = L10n.$localeOverride.withValue(locale) {
                    String(format: ObjectACLLines.identifier.text, value)
                }
                #expect(lines == [expected], "\(locale)")
            }
        }
        // The word the label must not use: it would be false of a group.
        for locale in Self.locales {
            let label = L10n.$localeOverride.withValue(locale) {
                String(format: ObjectACLLines.identifier.text, "")
            }
            let sayId = label.lowercased().split { !$0.isLetter }.contains("id")
            #expect(!sayId, "\(locale): \(label)")
        }
    }

    @Test func aHolderThatHasANameShowsTheNameFirstAndTheIdentifierBeneathIt() {
        let grant = ACLGrant(
            granteeID: Self.syntheticOwnerID, granteeDisplayName: "Ada", permission: "WRITE")
        let lines = Self.inEnglish { ObjectACLDisplay.rows(of: [grant]).first?.holder }
        #expect(lines == ["Ada", "Identifier: \(Self.syntheticOwnerID)"])
        let nameOnly = ACLGrant(granteeID: nil, granteeDisplayName: "Ada", permission: "WRITE")
        #expect(Self.inEnglish { ObjectACLDisplay.rows(of: [nameOnly]).first?.holder } == ["Ada"])
    }

    @Test func aPermissionTheStoreSpellsInAWayNobodyHasSeenIsShownAsSpelled() {
        let grant = ACLGrant(granteeID: nil, granteeDisplayName: "Ada", permission: "SOMETHING_NEW")
        #expect(Self.inEnglish { ObjectACLDisplay.rows(of: [grant]).first?.permission } == "SOMETHING_NEW")
    }

    @Test func everyGrantIsOneRowInTheOrderTheStoreGaveThem() {
        let grants = (0..<12).map {
            ACLGrant(granteeID: nil, granteeDisplayName: "holder-\($0)", permission: "READ")
        }
        let rows = Self.inEnglish { ObjectACLDisplay.rows(of: grants) }
        #expect(rows.map(\.holder) == (0..<12).map { ["holder-\($0)"] })
    }

    // MARK: - Reading it

    @MainActor @Test func theAccessListIsReadForTheFileWhenTheSheetOpensAndAgainAfterASave() async {
        let rig = ObjectMetadataSheetTests.Rig(
            stored: Self.stored, aclAnswer: .policy(Self.theRigsPolicy))
        #expect(rig.model.accessList == .reading, "nothing is shown as read before it was")
        await rig.model.load()
        #expect(rig.provider.aclReads == [Self.target.key])
        #expect(rig.model.accessList == .policy(Self.theRigsPolicy))

        rig.model.contentType = "text/markdown"
        let outcome = await rig.model.save()
        #expect(outcome == .written)
        #expect(
            rig.provider.aclReads == [Self.target.key, Self.target.key],
            "a write adds a version, and the new version's list is the one on screen")
    }

    @MainActor @Test func aFailedAccessListReadIsSaidInAFixedSentenceAndTakesNothingElseWithIt() async {
        let (model, provider) = await Self.loadedModel(
            .failure(RemoteFSError.protocolError(reason: Self.storeWords)))
        #expect(model.phase == .ready, "the metadata was read and stays editable")
        guard case .failed(let sentence) = model.accessList else {
            Issue.record("not failed: \(model.accessList)")
            return
        }
        #expect(sentence == Self.inEnglish { ObjectACLLines.readFailed.text })
        let leaked = sentence.contains(Self.storeWords)
        #expect(!leaked)
        #expect(provider.aclReads.count == 1)
        model.contentType = "text/markdown"
        #expect(model.hasChanges, "the form is still editable")
    }

    @MainActor @Test func aMissingPermissionIsSaidWithTheSheetsOwnPermissionSentence() async {
        let (model, _) = await Self.loadedModel(.failure(RemoteFSError.permissionDenied(path: "k")))
        #expect(model.accessList == .failed(Self.inEnglish { ObjectLockLines.denied.text }))
    }

    @MainActor @Test func anAccessListIsNotAskedForWhenTheMetadataCouldNotBeRead() async {
        let rig = ObjectMetadataSheetTests.Rig(
            stored: Self.stored, readError: RemoteFSError.protocolError(reason: Self.storeWords),
            aclAnswer: .policy(Self.theRigsPolicy))
        await rig.model.load()
        #expect(rig.provider.aclReads.isEmpty)
    }

    // MARK: - The section offers no control

    @MainActor private static func controls(in display: ObjectACLDisplay) -> [String] {
        hostedControls(ObjectACLSection(display: display))
    }

    /// The class names of every control SwiftUI backs with a real AppKit view
    /// in the hosted content: buttons, pop-ups, segmented controls, switches,
    /// anything editable (scroll bars excepted, below). (Plain `Text` is drawn, not a view, and cannot be
    /// found this way; `BoundedViewStateOnScreenTests` measured that.)
    @MainActor private static func hostedControls<Content: View>(_ content: Content) -> [String] {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [String] = []
        @MainActor func walk(_ view: NSView) {
            if let field = view as? NSTextField {
                if field.isEditable { found.append("editable \(type(of: field))") }
            } else if let text = view as? NSTextView {
                if text.isEditable { found.append("editable \(type(of: text))") }
            } else if view is NSScroller {
                // The scroll bar of the entries' scroll view: an `NSControl`
                // that scrolls and changes nothing. Measured as the only
                // thing the first draft of this walk found (2026-11-03).
            } else if view is NSControl {
                found.append("\(type(of: view))")
            }
            for child in view.subviews { walk(child) }
        }
        walk(host)
        return found
    }

    @MainActor private static var everyDisplay: [ObjectACLDisplay] {
        let many = (0..<10).map {
            ACLGrant(granteeID: groupURI, granteeDisplayName: "holder-\($0)", permission: "READ")
        }
        return inEnglish {
            [
                .reading, .notOffered, .failed(ObjectACLLines.readFailed.text),
                ObjectACLDisplay.of(.policy(theRigsPolicy)),
                ObjectACLDisplay.of(
                    .policy(ObjectACL(ownerID: nil, ownerDisplayName: nil, grants: []))),
                ObjectACLDisplay.of(
                    .policy(ObjectACL(ownerID: syntheticOwnerID, ownerDisplayName: "rustfs", grants: many))),
            ]
        }
    }

    @MainActor @Test func theSectionOffersNoControlThatWrites() {
        for display in Self.everyDisplay {
            #expect(Self.controls(in: display) == [], "\(display)")
        }
    }

    /// The positive beside the walk above: the same walk over the whole sheet
    /// does find controls, so an empty answer for the section is a statement
    /// about the section and not about a walk that sees nothing.
    @MainActor @Test func theWalkThatFindsNoControlInTheSectionFindsTheSheetsOwn() {
        let rig = ObjectMetadataSheetTests.Rig(
            stored: Self.stored, aclAnswer: .policy(Self.theRigsPolicy))
        let model = ObjectMetadataModel(
            target: Self.target, recorder: nil,
            provider: rig.provider, settings: rig.settings,
            locks: ObjectLockStateCache(settings: rig.settings),
            versioning: BucketVersioningCache(settings: rig.settings),
            phase: .ready, loaded: Self.stored, bucketLock: .absent,
            versioningReading: .known(.never), accessList: .policy(Self.theRigsPolicy))
        let found = SheetBound.$isSuspendedForMeasurement.withValue(true) {
            Self.hostedControls(ObjectMetadataSheet(model: model))
        }
        let editable = found.filter { $0.hasPrefix("editable") }
        #expect(editable.count >= 3, "\(found)")
    }

    /// The source of the section, read as code: nothing in it can take a
    /// click, a typed character or a choice.
    @Test func theSectionsSourceDeclaresNoWayToChangeAnything() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectMetadataSheet.swift")
        let code = try SourceCorpus.code(of: url)
        let body = try #require(SourceSpan.body(after: "struct ObjectACLSection", in: code))
        // The positive: the scan is reading the section and not an empty span.
        #expect(body.contains("Text("))
        #expect(body.contains("ForEach("))
        for token in [
            "Button(", "Toggle(", "TextField(", "TextEditor(", "Picker(", "Menu(", "Stepper(",
            "CheckboxRow(", "onTapGesture", "onSubmit", "Binding", "$model", "@State",
        ] {
            let found = body.contains(token)
            #expect(!found, "\(token)")
        }
    }

    @Test func aLongListSitsBehindAScrollBecauseABoundedSheetClipsInsteadOfGrowing() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectMetadataSheet.swift")
        let code = try SourceCorpus.code(of: url)
        let body = try #require(SourceSpan.body(after: "struct ObjectACLSection", in: code))
        #expect(body.contains("ScrollView("))
        #expect(body.contains("maxHeight"))
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInEveryLanguageAndTheEnglishIsTheSourceText() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        for line in ObjectACLLines.all {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, sentinel) }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
                if locale == "en" {
                    #expect(resolved == line.english, "\(line.key)")
                } else {
                    #expect(resolved != line.english, "\(line.key) in \(locale)")
                }
            }
        }
    }

    /// How many keys the family has, written down. **An independent figure**:
    /// `all.count` is a map of the thing it checks. The command that produces
    /// it, from the repository root:
    /// `grep -o '"s3\.acl\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings | wc -l`.
    static let lineCount = 10

    @Test func theFamilyHasTheLinesItIsWrittenDownToHave() throws {
        #expect(ObjectACLLines.all.count == Self.lineCount)
        #expect(Set(ObjectACLLines.all.map(\.key)).count == Self.lineCount, "a key is used twice")
        for locale in Self.locales {
            let url = SourceCorpus.url(of: .sources)
                .appendingPathComponent("MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings")
            let catalogue = try String(contentsOf: url, encoding: .utf8)
            let keys = catalogue.matches(of: #/"(s3\.acl\.[^"]+)" *=/#).map { String($0.output.1) }
            #expect(Set(keys) == Set(ObjectACLLines.all.map(\.key)), "\(locale)")
            #expect(keys.count == Self.lineCount, "\(locale)")
        }
    }

    @Test func noKeyIsSpelledExactlyAsTheSubresourceNameTheWriteGuardWatchesFor() {
        for line in ObjectACLLines.all {
            #expect(line.key.lowercased() != "acl", "\(line.key)")
        }
    }

    @Test func everyTranslationKeepsTheSpecifiersOfTheEnglish() {
        let specifier = #/%(\d+\$)?(lld|@|d)/#
        var withSpecifiers = 0
        for line in ObjectACLLines.all {
            let english = line.english.matches(of: specifier).map { String($0.output.0) }.sorted()
            if !english.isEmpty { withSpecifiers += 1 }
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, "") }
                let found = resolved.matches(of: specifier).map { String($0.output.0) }.sorted()
                #expect(found == english, "\(line.key) in \(locale)")
            }
        }
        // The identifier line.
        #expect(withSpecifiers == 1)
    }

    @Test func theWordsNameNoStoreMechanics() {
        for line in ObjectACLLines.all {
            let text = Self.inEnglish { line.text.lowercased() }
            for jargon in ["acl", "xml", "grantee", "canonical", "501", "403", "x-amz"] {
                let leaked = text.contains(jargon)
                #expect(!leaked, "\(jargon) in \(line.key)")
            }
        }
    }
}
