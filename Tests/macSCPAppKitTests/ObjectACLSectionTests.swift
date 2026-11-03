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
///
/// ## How sensitive these are: sixteen plants, committed with their commands
///
/// The commit that introduced this file has a compile failure as its red (the
/// tests were written before the types they name), so the behavioural weight
/// of "these tests would notice" is carried by plants. Each ran through
/// `scripts/mutation-probe` from the repository root on a clean tree, which
/// refuses a dirty one and reverts index-safely; each printed, verbatim, the
/// control line (the unplanted tree's run) and the verdict below it. Run
/// 2026-11-03 on the tree of `fix(app): access-list section review round 1,
/// the re-read is pinned and hedged, the form scrolls`.
///
/// **P5 is the one that changed the suite.** Run first against the tree before
/// the type read existed, it was caught by
/// `theSectionsSourceDeclaresNoWayToChangeAnything()` alone: the hosted-view
/// walk stayed green with a Button planted, because a default-styled SwiftUI
/// Button is not an AppKit control. The type read in
/// `theSectionOffersNoControlThatWrites` was added because of it.
///
/// **P11 and P12 pin the condition the re-read was accepted on**, that it runs
/// after a CONFIRMED write and nowhere else. Before
/// `theListIsReadAgainAfterAConfirmedWriteAndOnlyThen` existed, adding the call
/// to the write's `catch`, or to the COMPLIANCE refusal, was GREEN across 62
/// tests.
///
/// **P15's first attempt was GREEN and was a bad plant, not a blind test.** Its
/// perl removed the FIRST `ProgressView().controlSize(.small)` in the file,
/// which is the sheet's own reading line, not the section's (the pattern had
/// no `g` and two lines match it). The block below is the second, anchored
/// attempt.
///
/// **Not pinned, deliberately:** that the list is read LAST in `load()`
/// (review item 8). It is latency only (`readLockBeforeTheWrite` keeps the
/// acknowledgement correct whatever the order), and a test of the order would
/// assert the shape of the code and not a behaviour.
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P1 a storage with no access lists is shown as a policy with no entries' \
///   --apply "perl -0pi -e 's/                accessList = \.notOffered\n/                accessList = .policy(ObjectACL(ownerID: nil, ownerDisplayName: nil, grants: []))\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aStoreWithoutAclsSaysSoInsteadOfShowingNoGrants()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P2 an unnamed holder is drawn as an empty line' \
///   --apply "perl -0pi -e 's/return lines\.isEmpty \? \[whenUnnamed\.text\] : lines/return lines.isEmpty ? [\"\"] : lines/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/anOwnerTheStoreDidNotNameIsSaidToo()
///   macSCPAppKitTests.ObjectACLSectionTests/anUnnamedHolderIsSaidRatherThanDrawnBlank()
///   macSCPAppKitTests.ObjectACLSectionTests/theUnnamedSentenceIsTheOneForTheShapeCoreReports()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P3 the identifier is labelled ID in the English catalogue' \
///   --apply "perl -pi -e 's/^(\"s3\.acl\.identifier %@\" = )\"Identifier: %@\"/\$1\"ID: %@\"/' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aHolderIdentifierIsLabelledAsAnIdentifierWhetherItIsAnIdOrAUrl()
///   macSCPAppKitTests.ObjectACLSectionTests/aHolderThatHasANameShowsTheNameFirstAndTheIdentifierBeneathIt()
///   macSCPAppKitTests.ObjectACLSectionTests/aPolicyWithNoGrantsStillNamesItsOwner()
///   macSCPAppKitTests.ObjectACLSectionTests/everyLineResolvesInEveryLanguageAndTheEnglishIsTheSourceText()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P4 a failed read quotes the error' \
///   --apply "perl -0pi -e 's/        default:\n            return readFailed\.text\n        \}\n    \}\n\}\n\n\/\/\/ What the access-list section shows/        default:\n            return \"\\\\(error)\"\n        }\n    }\n}\n\n\/\/\/ What the access-list section shows/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aFailedAccessListReadIsSaidInAFixedSentenceAndTakesNothingElseWithIt()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P5 the section offers a button' \
///   --apply "perl -0pi -e 's/(            Text\(ObjectACLLines\.heading\.text\)\.font\(\.subheadline\)\n)/\$1            Button(\"Make public\") {}\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theSectionOffersNoControlThatWrites()
///   macSCPAppKitTests.ObjectACLSectionTests/theSectionsSourceDeclaresNoWayToChangeAnything()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P6 the entries no longer sit behind a height of their own' \
///   --apply "perl -0pi -e 's/                \.frame\(maxHeight: Self\.listHeight\)\n//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aLongListSitsBehindAScrollBecauseABoundedSheetClipsInsteadOfGrowing()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P7 no re-read of the list after a confirmed write' \
///   --apply "perl -0pi -e 's/            await readAccessList\(\)\n            return \.written/            return .written/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theAccessListIsReadForTheFileWhenTheSheetOpensAndAgainAfterASave()
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P8 a failed list read takes the whole sheet down with it' \
///   --apply "perl -0pi -e 's/            accessList = \.failed\(ObjectACLLines\.readMessage\(for: error\)\)\n/            accessList = .failed(ObjectACLLines.readMessage(for: error))\n            phase = .failed(ObjectACLLines.readMessage(for: error))\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aFailedAccessListReadIsSaidInAFixedSentenceAndTakesNothingElseWithIt()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P9 the permission is changed on its way to the row' \
///   --apply "perl -0pi -e 's/                permission: \\\$0\.permission\)/                permission: \\\$0.permission.lowercased())/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aPermissionTheStoreSpellsInAWayNobodyHasSeenIsShownAsSpelled()
///   macSCPAppKitTests.ObjectACLSectionTests/anUnnamedHolderIsSaidRatherThanDrawnBlank()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P10 a holder identified by a URL is not shown' \
///   --apply "perl -0pi -e 's/        if let identifier \{\n/        if let identifier, !identifier.hasPrefix(\"http\") {\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aHolderIdentifierIsLabelledAsAnIdentifierWhetherItIsAnIdOrAUrl()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P11 the list is read again after a write the store refused' \
///   --apply "perl -0pi -e 's/(            applyFailure = ObjectLockLines\.message\(for: error, during: \.applyingDefault\)\n)/\$1            await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P12 the list is read again after a save refused for the acknowledgement' \
///   --apply "perl -0pi -e 's/(            if !acknowledged \{\n                refusedSaves \+= 1\n)/\$1                await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P13 the form no longer scrolls behind a height of its own' \
///   --apply "perl -0pi -e 's/            \.frame\(maxHeight: Self\.formHeight\)\n//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theTallestStateStaysWithinTheTallestBoundInTheApp()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P14 the section says the shared denied sentence again' \
///   --apply "perl -0pi -e 's/            return denied\.text\n/            return ObjectLockLines.denied.text\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/aMissingPermissionIsSaidInTheSectionsOwnWordsAndPromisesNoChange()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P15 the access-list reading line loses its spinner' \
///   --apply "perl -0pi -e 's/                ProgressView\(\)\.controlSize\(\.small\)\n(                Text\(ObjectACLLines\.reading)/\$1/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theReadingStateIsOnScreenWhileTheListIsBeingRead()
///   macSCPAppKitTests.ObjectACLSectionTests/theTypeReadSeesWhatTheSectionIsMadeOfAndAControlWhenThereIsOne()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P16 a catalogue key is spelled exactly as the sub-resource' \
///   --apply "perl -0pi -e 's/\z/\"acl\" = \"x\";\n/' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"
/// ── control: 28 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 28 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/noCatalogueKeyAnywhereIsSpelledExactlyAsTheSubresourceName()
/// ```
///
/// ## Round 2: eleven more plants, on the tree of `fix(app): access-list section review round 2, every exit of save() is held, the failed-read figure follows the catalogue`
///
/// The block above ran with a control of 28 tests; the suite is now 32, so the
/// plants whose catcher changed (P7, P11 and P12) are re-run here with the new
/// control. P17 to P20 are the four exits of `save()` that the first version of
/// `theListIsReadAgainAfterAConfirmedWriteAndOnlyThen` did not pin (the
/// pre-write lock read failing, a stale acknowledgement, a draft that changed
/// nothing, a blocked draft): before the test ranged over every exit, P17 and
/// P18 were GREEN. P21 is the test that replaced a tautology: it is red if the
/// failed-read sentence goes back to the process language. P22 and P23 bracket
/// `listHeight` from both sides, P24 removes the keyboard-focus modifier (the
/// test pins that the modifier is present; that it works is unverified).
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P7 no re-read of the list after a confirmed write' \
///   --apply "perl -0pi -e 's/            await readAccessList\(\)\n            return \.written/            return .written/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theAccessListIsReadForTheFileWhenTheSheetOpensAndAgainAfterASave()
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P11 the list is read again after a write the store refused' \
///   --apply "perl -0pi -e 's/(            applyFailure = ObjectLockLines\.message\(for: error, during: \.applyingDefault\)\n)/\$1            await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P12 the list is read again after a save refused for the acknowledgement' \
///   --apply "perl -0pi -e 's/(            if !acknowledged \{\n                refusedSaves \+= 1\n)/\$1                await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P17 the list is read again after a lock read that failed before the write' \
///   --apply "perl -0pi -e 's/(            applyFailure = ObjectLockLines\.message\(for: error, during: \.reading\)\n)/\$1            await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P18 the list is read again after a stale acknowledgement' \
///   --apply "perl -0pi -e 's/(            if acknowledgementIsStale \{\n                refusedSaves \+= 1\n)/\$1                await readAccessList()\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P19 the list is read again after a save that changed nothing' \
///   --apply "perl -0pi -e 's/        guard hasChanges else \{ return \.refused\(\.nothingChanged\) \}\n/        guard hasChanges else {\n            await readAccessList()\n            return .refused(.nothingChanged)\n        }\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P20 the list is read again after a blocked draft' \
///   --apply "perl -0pi -e 's/        guard draftProblem == nil else \{ return \.blocked \}\n/        guard draftProblem == nil else {\n            await readAccessList()\n            return .blocked\n        }\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListIsReadAgainAfterAConfirmedWriteAndOnlyThen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P21 the failed-read sentence is read in the process language' \
///   --apply "perl -0pi -e 's/(    static func findingMessage\(_ finding: RemoteFSFinding, locale: String\) -> String \{\n)/\$1        return finding.message\n/' Tests/macSCPAppKitTests/BoundedViewRegistry.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theLongestFailureSentenceFollowsTheCatalogueUnderMeasurement()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P22 the list is capped so high that a fourth entry shows in full' \
///   --apply "perl -0pi -e 's/static let listHeight: CGFloat = 130/static let listHeight: CGFloat = 170/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListShowsThreeEntriesAndPartOfAFourth()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P23 the list is capped so low that a fourth entry shows nothing' \
///   --apply "perl -0pi -e 's/static let listHeight: CGFloat = 130/static let listHeight: CGFloat = 100/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theListShowsThreeEntriesAndPartOfAFourth()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectACLSectionTests \
///   --label 'P24 the entries list is not focusable' \
///   --apply "perl -0pi -e 's/\n                \.focusable\(\)//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 32 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 32 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectACLSectionTests/theEntriesListIsFocusableSoTheKeyboardCanScrollIt()
/// ```
///
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
            "the list is read again after a confirmed write: defensive, since whether a write changes it is unmeasured")
    }

    /// How many access-list requests a rig has made after `save()` ended in
    /// `outcome`: two after a confirmed write (the read at open, and the read
    /// after the write) and one after every other exit. **The switch has no
    /// `default`**, so a case added to `SaveOutcome` does not compile until
    /// someone has said what the list does after it.
    private static func expectedAccessListReads(
        after outcome: ObjectMetadataModel.SaveOutcome
    ) -> Int {
        switch outcome {
        case .written: 2
        case .refused, .blocked, .failed: 1
        }
    }

    /// One way of leaving `save()`: a name, and what running it gave (how it
    /// ended, and how many access-list requests the rig had made by then).
    private typealias Scenario = (
        name: String,
        run: @MainActor () async -> (outcome: ObjectMetadataModel.SaveOutcome, reads: Int)
    )

    @MainActor private static var saveScenarios: [Scenario] {
        let compliance = FakeBucketSettings.ObjectLockFixture(
            hasLock: true, bucketDefault: .init(days: 30, mode: .compliance))
        let unreadableLock = FakeBucketSettings.ObjectLockFixture(
            hasLock: true, bucketDefault: .init(days: 30, mode: .governance),
            readError: RemoteFSError.protocolError(reason: storeWords))
        return [
            ("a confirmed write", {
                let rig = ObjectMetadataSheetTests.Rig(stored: stored, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.contentType = "text/markdown"
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("a write the store refused", {
                let rig = ObjectMetadataSheetTests.Rig(
                    stored: stored, writeError: RemoteFSError.protocolError(reason: storeWords),
                    aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.contentType = "text/markdown"
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("a lock read that failed before the write", {
                let rig = ObjectMetadataSheetTests.Rig(
                    stored: stored, lock: unreadableLock, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.contentType = "text/markdown"
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("a COMPLIANCE default nobody acknowledged", {
                let rig = ObjectMetadataSheetTests.Rig(
                    stored: stored, lock: compliance, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.contentType = "text/markdown"
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("an acknowledgement given for another day", {
                let rig = ObjectMetadataSheetTests.Rig(
                    stored: stored, lock: compliance, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.contentType = "text/markdown"
                rig.model.acknowledged = true
                rig.clock.date = rig.clock.date.addingTimeInterval(2 * 86_400)
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("a save that changed nothing", {
                let rig = ObjectMetadataSheetTests.Rig(stored: stored, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
            ("a draft that cannot be sent", {
                let rig = ObjectMetadataSheetTests.Rig(stored: stored, aclAnswer: .policy(theRigsPolicy))
                await rig.model.load()
                rig.model.addCustomRow()
                rig.model.custom[rig.model.custom.count - 1].value = "no name"
                return (await rig.model.save(), rig.provider.aclReads.count)
            }),
        ]
    }

    /// The names of the cases `SaveOutcome` declares, read from its
    /// declaration in the sheet's source and not written out here.
    private static func declaredSaveOutcomeCases() throws -> Set<String> {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectMetadataSheet.swift")
        let code = try SourceCorpus.code(of: url)
        let body = try #require(SourceSpan.body(after: "enum SaveOutcome", in: code))
        return Set(body.matches(of: #/\bcase\s+(\w+)/#).map { String($0.output.1) })
    }

    private static func kind(of outcome: ObjectMetadataModel.SaveOutcome) -> String {
        switch outcome {
        case .written: "written"
        case .refused: "refused"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    /// The list is read again after a confirmed write and after NO other exit
    /// of `save()`. That is the condition the re-read was accepted on.
    ///
    /// **Every exit, not the ones its author thought of.** The first version
    /// of this test enumerated five by hand and a reviewer found two
    /// reachable exits it missed (a re-read after the pre-write lock read
    /// fails, and one on `.refused(.acknowledgementStale)`), both GREEN. It
    /// now drives a scenario to each exit and compares what it reached with
    /// what the types declare: the cases of `SaveOutcome` from its source,
    /// and the refusals from `SaveRefusal.allCases`. An exit added later has
    /// no scenario that reaches it, so this test is red until one is added.
    @MainActor @Test func theListIsReadAgainAfterAConfirmedWriteAndOnlyThen() async throws {
        var reachedKinds: Set<String> = []
        var reachedRefusals: Set<String> = []
        for scenario in Self.saveScenarios {
            let (outcome, reads) = await scenario.run()
            #expect(
                reads == Self.expectedAccessListReads(after: outcome),
                "\(scenario.name) ended in \(outcome) with \(reads) access-list requests")
            reachedKinds.insert(Self.kind(of: outcome))
            if case .refused(let reason) = outcome { reachedRefusals.insert("\(reason)") }
        }
        #expect(reachedKinds == (try Self.declaredSaveOutcomeCases()), "an exit of save() has no scenario")
        #expect(
            reachedRefusals == Set(ObjectMetadataModel.SaveRefusal.allCases.map { "\($0)" }),
            "a refusal has no scenario")
    }

    /// The positive beside the derivation above: the scan reads real cases.
    @Test func theDeclaredExitsAreTheOnesTheRefusalsAndOutcomesNameToday() throws {
        #expect(try Self.declaredSaveOutcomeCases() == ["written", "refused", "blocked", "failed"])
        #expect(ObjectMetadataModel.SaveRefusal.allCases.count == 3)
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

    /// The sheet's shared denied sentence says the key may not "read or
    /// change" the file; this section's own note says macSCP changes nothing
    /// here, so the section says only what the read needed.
    @MainActor @Test func aMissingPermissionIsSaidInTheSectionsOwnWordsAndPromisesNoChange() async {
        let (model, _) = await Self.loadedModel(.failure(RemoteFSError.permissionDenied(path: "k")))
        #expect(model.accessList == .failed(Self.inEnglish { ObjectACLLines.denied.text }))
        for locale in Self.locales {
            let (own, shared) = L10n.$localeOverride.withValue(locale) {
                (ObjectACLLines.denied.text, ObjectLockLines.denied.text)
            }
            #expect(own != shared, "\(locale)")
        }
        let english = Self.inEnglish { ObjectACLLines.denied.text.lowercased() }
        let mentionsChange = english.contains("change")
        #expect(!mentionsChange)
        #expect(english.contains("read"))
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

    /// **The hosted walk alone is not enough, and that was measured.** With a
    /// SwiftUI `Button` planted into the section, the walk above stayed green:
    /// a default-styled `Button` is drawn by SwiftUI and is not an AppKit
    /// control the walk can find (plant P5, run on the tree of the commit that
    /// introduced the section, was caught only by the source scan). So the
    /// check is the walk (anything AppKit-backed and editable) AND the type of
    /// the view the section actually builds, below.
    @MainActor @Test func theSectionOffersNoControlThatWrites() {
        for display in Self.everyDisplay {
            #expect(Self.controls(in: display) == [], "\(display)")
            let controls = Self.controlTypes(in: ObjectACLSection(display: display))
            #expect(controls == [], "\(display)")
        }
    }

    /// The control types named in the STATIC type of the section's body: the
    /// views the section's own `body`, its `@ViewBuilder` branches and its
    /// `ForEach` closures spell, whatever state is shown.
    ///
    /// **It is a secondary net, not the primary one.** The property that
    /// nothing here writes is held structurally by `NoACLWriteGuardTests`: no
    /// setter, no function that takes a policy, and the only store call a
    /// GET. This check reads what the section is made of, and it has limits
    /// that were measured (2026-11-03, by a reviewer planting ten kinds of
    /// control; eight were caught):
    ///
    /// - `AnyView` erases the body type, so a control wrapped in one is not
    ///   spelled here (the source scan below still sees it).
    /// - A named child view in the same file holding the control is spelled
    ///   as its own name, not its contents, and the source scan's span stops
    ///   at `struct ObjectACLSection`: widening it would start reporting the
    ///   metadata sheet's own legitimate controls in the rest of the file.
    /// - Gesture coverage is the list of names below; `.gesture(DragGesture()
    ///   .onEnded { ... })` is not on it.
    ///
    /// A contributor extending this section should treat all three as limits
    /// of this check and not as properties of the section.
    @MainActor private static func controlTypes(in section: ObjectACLSection) -> [String] {
        let tree = String(reflecting: type(of: section.body))
        return [
            "Button", "Toggle", "TextField", "TextEditor", "SecureField", "Picker", "Menu",
            "Stepper", "Slider", "DatePicker", "ColorPicker", "Link", "TapGesture",
            "CheckboxRow", "DisclosureGroup",
        ].filter { tree.contains($0) }
    }

    /// The positive beside the type read above: it does name the views the
    /// section is made of, and it does name a control when one is there.
    @MainActor @Test func theTypeReadSeesWhatTheSectionIsMadeOfAndAControlWhenThereIsOne() {
        let tree = String(
            reflecting: type(of: ObjectACLSection(display: .notOffered).body))
        for name in ["Text", "ScrollView", "ForEach", "ProgressView"] {
            #expect(tree.contains(name), "\(name) not in the type of the section's body")
        }
        let withAButton = String(
            reflecting: type(of: VStack { Text("x"); Button("y") {} }))
        #expect(withAButton.contains("Button"))
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

    // MARK: - The sheet around it

    /// The registry's list of findings is the whole of Core's, so "the
    /// longest sentence a failed read can carry" is measured over all of them.
    @MainActor @Test func theRegistrysFindingsAreEveryFindingCoreHas() {
        let named = Set(BoundedViewRegistry.everyFinding.map(\.name))
        #expect(named == Set(RemoteFSFinding.Name.allCases))
        #expect(BoundedViewRegistry.everyFinding.count == RemoteFSFinding.Name.allCases.count)
    }

    /// What can turn this red: building the sentence through
    /// `RemoteFSFinding.message`, which answers in the PROCESS language. Then
    /// every locale gets the same sentence, and the English and German
    /// catalogues (103 and 135 characters on the longest finding) stop
    /// differing. Measured 2026-11-03: that was the first version of the
    /// registry's helper, and nothing noticed.
    @MainActor @Test func theLongestFailureSentenceFollowsTheCatalogueUnderMeasurement() {
        var longest: [String: String] = [:]
        for locale in Self.locales {
            longest[locale] = L10n.$localeOverride.withValue(locale) {
                BoundedViewRegistry.longestAccessListFailure()
            }
        }
        // Each is the longest of THAT catalogue's own sentences: read the
        // catalogue file again, independently of the helper.
        for locale in Self.locales {
            let url = SourceCorpus.url(of: .sources)
                .appendingPathComponent("macSCPCore/Resources/\(locale).lproj/Localizable.strings")
            let table = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            let findings = table.filter { $0.key.hasPrefix("core.finding.") }
            #expect(findings.count == RemoteFSFinding.Name.allCases.count, "\(locale)")
            let widest = findings.values.map(\.count).max() ?? 0
            // A placeholder is replaced by a path or a number, so allow its
            // difference: the sentence is at least the widest template minus
            // the two characters of `%@`.
            #expect((longest[locale]?.count ?? 0) >= widest - 2, "\(locale)")
        }
        // And the catalogues differ, which a host-language read cannot show.
        #expect(Set(longest.values).count == Self.locales.count, "\(longest)")
    }

    /// A finding's payload and its sentence's placeholder agree: a finding that
    /// gains a payload the registry's `argument(of:)` does not know would be
    /// measured with a raw `%@` in it.
    @MainActor @Test func theFindingsPayloadsMatchTheirSentences() {
        for finding in BoundedViewRegistry.everyFinding {
            let url = SourceCorpus.url(of: .sources)
                .appendingPathComponent("macSCPCore/Resources/en.lproj/Localizable.strings")
            let table = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            let template = table[finding.messageKey] ?? ""
            #expect(!template.isEmpty, "\(finding.messageKey)")
            #expect(
                template.contains("%@") == (BoundedViewRegistry.argument(of: finding) != nil),
                "\(finding.messageKey)")
            let filled = BoundedViewRegistry.findingMessage(finding, locale: "en")
            let unfilled = filled.contains("%@")
            #expect(!unfilled, "\(finding.messageKey)")
        }
    }

    // MARK: - The entries' reach

    /// Three entries show in full and part of a fourth, which is what 130 pt
    /// (`ObjectACLSection.listHeight`) was chosen for. Measured on the section
    /// alone with three, four and five entries: a fourth adds SOME height
    /// (the clip shows part of it) but less than a whole entry's step, and a
    /// fifth adds none (the list scrolls). The figures are printed so they
    /// travel with this command:
    /// `swift test --filter theListShowsThreeEntriesAndPartOfAFourth`.
    @MainActor @Test func theListShowsThreeEntriesAndPartOfAFourth() {
        func height(_ count: Int) -> CGFloat {
            let grants = (0..<count).map {
                ACLGrant(
                    granteeID: Self.groupURI, granteeDisplayName: "Reviewer \($0)",
                    permission: "READ")
            }
            return LayoutMeasure.minimumHeight(locale: "en", at: 480) {
                ObjectACLSection(
                    display: L10n.$localeOverride.withValue("en") {
                        ObjectACLDisplay.of(
                            .policy(ObjectACL(ownerID: nil, ownerDisplayName: "Owner", grants: grants)))
                    }
                ).fixedSize(horizontal: false, vertical: true)
            }
        }
        let (one, two, three, four, five) = (height(1), height(2), height(3), height(4), height(5))
        print("access-list section, en, 480 pt wide, entries 1 to 5: \(one), \(two), \(three), \(four), \(five); listHeight \(ObjectACLSection.listHeight)")
        let step = two - one
        #expect(step > 0)
        #expect(three - two == step, "entries are not a constant step: \(one) \(two) \(three)")
        #expect(four > three, "a fourth entry shows no part of itself")
        #expect(four - three < step, "a fourth entry shows in full, so three is not what the cap shows")
        #expect(five == four, "a fifth entry grows the list: it does not scroll")
    }

    /// The entries' scroll view takes keyboard focus, so arrow keys can scroll
    /// it. **This pins that the attempt is made, not that it works:** whether
    /// arrow keys scroll a focusable `ScrollView` of selectable text on screen
    /// is unverified (no sheet can be rendered in the test process) and is on
    /// the closeout sight-check list. The change that turns this red is
    /// removing the modifier.
    @Test func theEntriesListIsFocusableSoTheKeyboardCanScrollIt() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectMetadataSheet.swift")
        let code = try SourceCorpus.code(of: url)
        let body = try #require(SourceSpan.body(after: "struct ObjectACLSection", in: code))
        let scroll = try #require(body.range(of: "ScrollView("))
        #expect(body[scroll.lowerBound...].contains(".focusable()"))
    }

    /// The whole sheet at its tallest, every optional line and a long access
    /// list at once, holds within the tallest bound any sheet in the app is
    /// granted (`BucketCORSSheet.bound`): the form scrolls past
    /// `ObjectMetadataSheet`'s own cap so that content past a bound is
    /// reachable and not clipped. Measured with the same instrument the layout
    /// guard uses; the figure is printed so it travels with this command:
    /// `swift test --filter theTallestStateStaysWithinTheTallestBoundInTheApp`.
    @MainActor @Test func theTallestStateStaysWithinTheTallestBoundInTheApp() throws {
        let ceiling = try #require(BucketCORSSheet.bound.grantedHeight)
        let entry = try #require(
            BoundedViewRegistry.all.first {
                $0.stateName.hasPrefix("metadata at its tallest")
            })
        var figures: [String] = []
        for locale in LayoutMeasure.shippedLocales {
            let height = SheetBound.$isSuspendedForMeasurement.withValue(true) {
                LayoutMeasure.minimumHeight(locale: locale, at: entry.bound.grantedWidth) {
                    entry.content().fixedSize(horizontal: false, vertical: true)
                }
            }
            figures.append("\(locale) \(height)")
            #expect(height <= ceiling, "\(locale): \(height) pt against \(ceiling) pt")
        }
        print("tallest metadata sheet, height at \(entry.bound.grantedWidth) pt wide: \(figures.joined(separator: ", ")); ceiling \(ceiling)")
    }

    /// The reading line is the first state every opened sheet shows (the form
    /// is ready before the list is read). It is on screen when, and only when,
    /// the list is being read: the spinner is a real AppKit view, so it can be
    /// found in the hosted sheet where plain text cannot.
    @MainActor @Test func theReadingStateIsOnScreenWhileTheListIsBeingRead() {
        func spinners(_ reading: ObjectMetadataModel.AccessListReading) -> Int {
            let rig = ObjectMetadataSheetTests.Rig(stored: Self.stored)
            let model = ObjectMetadataModel(
                target: Self.target, recorder: nil,
                provider: rig.provider, settings: rig.settings,
                locks: ObjectLockStateCache(settings: rig.settings),
                versioning: BucketVersioningCache(settings: rig.settings),
                phase: .ready, loaded: Self.stored, bucketLock: .absent,
                versioningReading: .known(.never), accessList: reading)
            return SheetBound.$isSuspendedForMeasurement.withValue(true) {
                Self.count(NSProgressIndicator.self, in: ObjectMetadataSheet(model: model))
            }
        }
        #expect(spinners(.reading) == 1)
        // The positive beside it: no other state shows one.
        #expect(spinners(.notOffered) == 0)
        #expect(spinners(.policy(Self.theRigsPolicy)) == 0)
    }

    @MainActor private static func count<V: NSView, Content: View>(
        _ type: V.Type, in content: Content
    ) -> Int {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found = 0
        @MainActor func walk(_ view: NSView) {
            if view is V { found += 1 }
            for child in view.subviews { walk(child) }
        }
        walk(host)
        return found
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
    static let lineCount = 11

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

    /// Every key of a `.strings` catalogue, without its quotes.
    private static func catalogueKeys(in catalogue: String) -> [String] {
        catalogue.matches(of: #/(?m)^"([^"]+)" *=/#).map { String($0.output.1) }
    }

    /// The keys spelled exactly as the sub-resource name, which
    /// `NoACLWriteGuardTests` counts as a second use of it, with a message
    /// about query names that reads as nonsense for a catalogue key.
    private static func keysSpelledAsTheSubresource(_ keys: [String]) -> [String] {
        keys.filter { $0.lowercased() == "acl" }
    }

    /// Scans the catalogue FILES, not the keys this type declares: a key
    /// declared here is prefixed `s3.acl.` and cannot be spelled `acl`, so a
    /// test over them could never fail (the first version of this test).
    @Test func noCatalogueKeyAnywhereIsSpelledExactlyAsTheSubresourceName() throws {
        let catalogues = try SourceCorpus.files(under: SourceCorpus.url(of: .sources))
            .filter { $0.pathExtension == "strings" }
        // The positive: the scan reaches the four App catalogues and the four
        // Core ones, and reads real keys out of each.
        #expect(catalogues.count == 8, "\(catalogues.count)")
        for url in catalogues {
            let keys = Self.catalogueKeys(
                in: try String(contentsOf: url, encoding: .utf8))
            #expect(keys.count > 100, "\(url.lastPathComponent): \(keys.count) keys")
            #expect(Self.keysSpelledAsTheSubresource(keys).isEmpty, "\(url.path)")
        }
        // And the scan can fail: driven over a catalogue that does it.
        let planted = Self.catalogueKeys(in: "\"s3.acl.heading\" = \"x\";\n\"ACL\" = \"y\";\n")
        #expect(Self.keysSpelledAsTheSubresource(planted) == ["ACL"])
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
