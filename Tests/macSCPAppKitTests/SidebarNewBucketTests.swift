import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The connection manager's one entry, "Connect and Create Bucket…" (S3
/// metadata and ACLs plan, Task 6; spec section 6.6).
///
/// Two halves, and they are different kinds of claim.
///
/// **Whether the entry is offered** is a function of a STORED connection, which
/// has no tab and no listing to ask. It is `ConnectionActionRoute.isOffered
/// (onStored:)`, and the rule inside it is not spelled again there: the
/// contribution is found in the backend's own descriptor (never by
/// `ConnectionKind`) and `CreateBucketModel.isOffered` is asked for the
/// verdict, so "a bucket made in a connection rooted in one bucket would be
/// invisible" has one author. Only the root half of that rule varies for a
/// stored record: the pane half is `nil` by construction, a freshly opened
/// connection standing at the root.
///
/// **What choosing it does** is driven on a REAL `ContentView`, with a
/// connector that hands back a bucket-list file system. The sheet itself is
/// `@State`, and a `ContentView` built outside a SwiftUI hierarchy drops writes
/// to those (measured in `ConnectAttemptHandoffTests`' "Isolation, round 2"),
/// so what is asserted is everything BEFORE the sheet: that the connection is
/// owned by a tab, that the hand-off waits for the bucket list, and that it is
/// made exactly once and to the route. That the sheet then appears is the one
/// part no test of this project can see.
///
/// **No clock decides anything.** Every wait is a `pollUntil` on a fact the tab
/// itself publishes, and nothing asserts how long anything took.
///
/// ## How sensitive these are: twenty-two plants, committed with their commands
///
/// The first commit's red is a compile failure (the tests name members that did
/// not exist yet), so the behavioural weight of "these tests would notice" is
/// carried by plants. Each ran through `scripts/mutation-probe` from the
/// repository root on a clean tree, which refuses a dirty one and reverts
/// index-safely; each printed, verbatim, the control line (the unplanted tree's
/// run) and the verdict below it. Run 2026-11-04 on the tree of `test(app): the
/// new-bucket entry's row gate, the Open Anyway pass-through and a failed list
/// are pinned`. The filter spans the five suites a plant can reach, which is why
/// the control counts 88 tests and not this suite's 24. Every plant was RED,
/// each by the test it was aimed at; none was `BUILD FAILED`, `PLANT FAILED` or
/// `PLANT CHANGED`, which would have been a verdict about the plant and not
/// about the tests.
///
/// **Three tests exist because their plant was chosen and no test read the
/// place it changes:** the row's gate (P16), the "Open Anyway" pass-through
/// (P14) and a bucket list that fails to load (P6). Not run against the commit
/// before them; established by reading the suite for a test that touched each
/// place.
///
/// **P15 is the one that fixes the order of the teardown's first line.** The
/// request is cleared before the teardown's first suspension point, not after
/// the connection has closed, and only a test that reads the tab while
/// `disconnect()` is parked can tell the two apart.
///
/// Not pinned, deliberately: that the sheet then APPEARS, which is `@State` and
/// the one part no test of this project can see.
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P1 a stored connection is offered the entry whatever its mode' \
///   --apply "perl -0pi -e 's/rootIsContainerList: session\.s3\?\.startsAtBucketList \?\? false,/rootIsContainerList: true,/' Sources/MacSCPAppKit/ConnectionActionRoute.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theEntryIsNotOfferedForAnS3ConnectionWithNoS3Block()
///   macSCPAppKitTests.SidebarNewBucketTests/theEntryIsNotOfferedInSingleBucketMode()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P2 a record with no S3 block is read as starting at the bucket list' \
///   --apply "perl -0pi -e 's/startsAtBucketList \?\? false/startsAtBucketList ?? true/' Sources/MacSCPAppKit/ConnectionActionRoute.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theEntryIsNotOfferedForAnS3ConnectionWithNoS3Block()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P3 the entry is offered by the record carrying an S3 block, not by the backend' \
///   --apply "perl -0pi -e 's/Self\.contribution\(of: self, for: session\.kind\) != nil/session.s3 != nil/' Sources/MacSCPAppKit/ConnectionActionRoute.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aBucketListBlockOnAnotherKindOfRecordDoesNotOfferIt()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P4 a bucket-level action is offered on a stored connection' \
///   --apply "perl -0pi -e 's/(case \.versioning, \.cors, \.objectLock:\n            )false/\${1}true/' Sources/MacSCPAppKit/ConnectionActionRoute.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/onlyCreateBucketIsOfferedOnAStoredConnection()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P5 the hand-off does not wait for the bucket list' \
///   --apply "perl -0pi -e 's/(switch session\.remote\.state \{\n        case \.loading:\n            )return \.waiting/\${1}break/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aBucketListThatFailedToLoadDropsTheRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/theHandOffWaitsForTheBucketListAndIsMadeOnce()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P6 a bucket list that failed to load keeps the request armed' \
///   --apply "perl -0pi -e 's/(        case \.failed:\n)            tab\.pendingCreateBucket = nil\n            return \.dropped/\${1}            return .waiting/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aBucketListThatFailedToLoadDropsTheRequest()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P7 the request is not cleared before the hand-off' \
///   --apply "perl -0pi -e 's/        tab\.pendingCreateBucket = nil\n(        openCreateContainerSheet\(in: tab, session: session\))/\$1/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/cancellingTheSheetLeavesAnOrdinaryConnectedTab()
///   macSCPAppKitTests.SidebarNewBucketTests/theHandOffWaitsForTheBucketListAndIsMadeOnce()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P8 the hand-off bypasses the route' \
///   --apply "perl -0pi -e 's/        openCreateContainerSheet\(in: tab, session: session\)\n        return \.handedToTheRoute/        createBucketSheetItem = nil\n        return .handedToTheRoute/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theHandOffGoesThroughTheRouteAndBuildsNoSheetOfItsOwn()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P9 the hand-off is made on a tab that is not in front' \
///   --apply "perl -0pi -e 's/        guard tabsModel\.activeTab\.id == tab\.id else \{ return \.waiting \}\n        switch session\.remote\.state/        switch session.remote.state/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aRequestOnABackgroundTabWaitsUntilItIsInFront()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P10 the hand-off is made on a tab connected to another stored connection' \
///   --apply "perl -0pi -e 's/        guard tab\.activeStoredSessionID == pending\.storedSessionID else \{\n            tab\.pendingCreateBucket = nil\n            return \.dropped\n        \}\n//' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aTabConnectedToAnotherStoredConnectionDropsTheRequest()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P11 the request is armed for a stored connection the user did not pick' \
///   --apply "perl -0pi -e 's/SessionTab\.PendingCreateBucket\(\n                storedSessionID: stored\.id\)/SessionTab.PendingCreateBucket(\n                storedSessionID: UUID())/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aBucketListThatFailedToLoadDropsTheRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/aRequestOnABackgroundTabWaitsUntilItIsInFront()
///   macSCPAppKitTests.SidebarNewBucketTests/cancellingTheSheetLeavesAnOrdinaryConnectedTab()
///   macSCPAppKitTests.SidebarNewBucketTests/theHandOffWaitsForTheBucketListAndIsMadeOnce()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P12 the entry arms nothing' \
///   --apply "perl -0pi -e 's/sidebarStart\(stored, paneVisibility: nil, createsBucket: true\)/sidebarStart(stored, paneVisibility: nil, createsBucket: false)/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/aBucketListThatFailedToLoadDropsTheRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/aConnectedFrontTabIsLeftAloneAndAFreshOneIsOpened()
///   macSCPAppKitTests.SidebarNewBucketTests/aFailedConnectDropsTheRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/aRequestOnABackgroundTabWaitsUntilItIsInFront()
///   macSCPAppKitTests.SidebarNewBucketTests/aTabConnectedToAnotherStoredConnectionDropsTheRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/anArmedRequestIsGoneBeforeTheConnectionStartsClosing()
///   macSCPAppKitTests.SidebarNewBucketTests/cancellingTheSheetLeavesAnOrdinaryConnectedTab()
///   macSCPAppKitTests.SidebarNewBucketTests/choosingItOpensATabRatherThanAnOwnerlessConnection()
///   macSCPAppKitTests.SidebarNewBucketTests/teardownDropsAnArmedRequest()
///   macSCPAppKitTests.SidebarNewBucketTests/theAlreadyOpenQuestionCarriesTheRequestAndOpenAnywayArmsIt()
///   macSCPAppKitTests.SidebarNewBucketTests/theHandOffWaitsForTheBucketListAndIsMadeOnce()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P13 the already-open question forgets what was asked for' \
///   --apply "perl -0pi -e 's/pendingSnippet: pendingSnippet, createsBucket: createsBucket\)/pendingSnippet: pendingSnippet, createsBucket: false)/' Sources/MacSCPAppKit/ContentView.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theAlreadyOpenQuestionCarriesTheRequestAndOpenAnywayArmsIt()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P14 Open Anyway starts a plain connect' \
///   --apply "perl -0pi -e 's/createsBucket: request\.createsBucket/createsBucket: false/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/openAnywayPassesTheRequestOnAndBuildsNoSheet()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P15 the teardown clears the request after the connection has closed' \
///   --apply "perl -0pi -e 's/        tab\.pendingCreateBucket = nil\n(        if let session = tab\.session \{\n            \/\/ MUST run before)/\$1/; s/(        tab\.liveness = nil\n)(        \/\/ Same rule, same sentence, for the lost-connection record)/\${1}        tab.pendingCreateBucket = nil\n\$2/' Sources/MacSCPAppKit/TabTeardown.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/anArmedRequestIsGoneBeforeTheConnectionStartsClosing()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P16 the row offers the entry on every connection' \
///   --apply "perl -0pi -e 's/ConnectionActionRoute\.createBucket\.isOffered\(onStored: session\)/true/' Sources/MacSCPAppKit/SessionSidebar.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theRowOffersTheEntryOnlyWhereTheRouteSaysSo()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P17 the menu entry maps to a plain connect' \
///   --apply "perl -0pi -e 's/(case \.newBucketMenuEntry:\n            return )\.selectAndCreateBucket/\${1}.selectAndConnect/' Sources/MacSCPAppKit/SessionRowActivation.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.PerformSessionRowInputTests/eachMenuEntryRunsItsOwnEffectAndNoOther()
///   macSCPAppKitTests.SessionRowActivationTests/eachMenuEntryReachesItsOwnFarEnd()
///   macSCPAppKitTests.SessionRowActivationTests/everyActivationIsReachableFromSomeInput()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P18 the activation runs the connect effect, not the create-bucket one' \
///   --apply "perl -0pi -e 's/(        case \.selectAndCreateBucket:\n            onSelect\.run\(value\)\n            )onCreateBucket\.run\(value\)/\${1}onConnect.run(value)/' Sources/MacSCPAppKit/SessionRowActivation.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.PerformSessionRowInputTests/eachMenuEntryRunsItsOwnEffectAndNoOther()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P19 the create-bucket activation is not counted as macSCP dialling' \
///   --apply "perl -0pi -e 's/\n            \|\| self == \.selectAndCreateBucket//' Sources/MacSCPAppKit/SessionRowActivation.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SessionRowActivationTests/aMenuEntryActsEvenWhileTheRowIsBeingRenamed(input:)
///   macSCPAppKitTests.SessionRowActivationTests/theThreePredicatesAnswerPerCase()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P20 the sidebar hands the window a plain connect for the entry' \
///   --apply "perl -0pi -e 's/SessionRowCreateBucketEffect \{ stored in createBucketFromSidebar\(stored\) \}/SessionRowCreateBucketEffect { stored in connectFromSidebar(stored) }/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SessionRowActivationWiringTests/theSidebarIsHandedEffectsThatActuallyReachTheHost()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P21 the runner is not woken by the bucket list loading' \
///   --apply "perl -0pi -e 's/remoteState: tab\.session\?\.remote\.state,/remoteState: nil,/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'P22 the German title does not say it connects' \
///   --apply "perl -pi -e 's/^(\"sidebar\.connectAndCreateBucket\" = )\"Verbinden und /\$1\"/' Sources/MacSCPAppKit/Resources/de.lproj/Localizable.strings"
/// ── control: 88 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 88 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.SidebarNewBucketTests/theTitleNamesTheConnectingAsWellAsTheCreating()
/// ```
///
/// ## Fix round 1: the review's plants, which the twenty-two did not contain
///
/// The review planted five plants of its own. Three were real violations and
/// came back GREEN against a control of 88 tests: R1, R2 and R3 below. (A
/// fourth, R4, was not a violation: the tab rule makes the tab a request is
/// armed on the active tab or a fresh one that is made active at once, so a
/// request cannot reach another connection, and nothing here pins it.) All
/// three were one shape, a source scan that could not match the violation it is named for
/// (the declaration `func handleConnectionAction(` satisfied a file-wide check
/// for the call and was also its control; a `!contains` over one function body
/// cannot see a second construction site in another file; a scan for the words
/// `PendingCreateBucketRunner(` cannot see how many runners there are). The
/// plants below are re-created from the diffs the review printed and were run
/// on the tree before the fix first (R1, R2, R3 and R5: GREEN, GREEN, GREEN, RED,
/// reproducing the review) and on the tree of `fix(app): new-bucket review round
/// 1, the source scans express the properties they are named for` after it.
/// R1b, R2b and R3b are variants of mine, run after the fix only.
///
/// **R5 is the one that must go GREEN after the fix.** It is a comment that
/// names a type, with no code change; the guard it turned RED was reading prose.
/// R5b is its control, the same name written as code, which must stay RED, so
/// the GREEN of R5 cannot be a guard that stopped matching anything.
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R1 the runner is mounted once for the active tab, not per tab' \
///   --apply "perl -0pi -e 's/        ForEach\(tabsModel\.tabs\) \{ tab in\n            (PendingCreateBucketRunner\(\n)                tab: tab, (activeTabID: tabsModel\.activeTab\.id,\n)                (onDeliver: \{ deliverPendingCreateBucket\(on: [^)]*\) \}\))\n        \}\n/        \$1                tab: tabsModel.activeTab, \$2                \$3\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// before the fix: ── control: 88 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 88 test(s) ran and NONE of them noticed the plant.
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R2 a second create-bucket sheet construction site, in the Go to Existing Tab answer' \
///   --apply "perl -0pi -e 's/(                    jumpToOpenSession\(request\)\n)/\$1                    if request.createsBucket, let tab = tabsModel.tabs.first(where: { tab in tab.id == request.existingTabID }), let session = tab.session, let settings = session.remoteFS as? any S3BucketSettings {\n                        createBucketSheetItem = CreateBucketSheetItem(recorder: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n                    }\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// before the fix: ── control: 88 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 88 test(s) ran and NONE of them noticed the plant.
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R3 openCreateContainerSheet builds the sheet itself instead of handing it to handleConnectionAction' \
///   --apply "perl -0pi -e 's/        handleConnectionAction\(action, in: tab, session: session\)\n    \}\n\n    \/\/\/ Whether the menu row for/        _ = action\n        if let settings = session.remoteFS as? any S3BucketSettings {\n            createBucketSheetItem = CreateBucketSheetItem(recorder: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n        }\n    }\n\n    \/\/\/ Whether the menu row for/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before the fix: ── control: 88 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 88 test(s) ran and NONE of them noticed the plant.
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.EmptyContainerListTests/theButtonIsRoutedThroughTheConnectionAction()
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests' \
///   --label 'R5 a doc comment in SessionSidebar.swift names ConnectionViewModel; no code change' \
///   --apply "perl -0pi -e 's/(    \/\/\/ teardown all belong to the tab the window opens\.\n)/\$1    \/\/\/ Nothing here is a ConnectionViewModel: the window holds that.\n/' Sources/MacSCPAppKit/SessionSidebar.swift"
/// before the fix: ── control: 24 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 24 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theSidebarOwnsNoConnection()
/// after the fix: ── control: 25 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 25 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R1b the runner is mounted for the active tab only, through a one-element ForEach' \
///   --apply "perl -0pi -e 's/        ForEach\(tabsModel\.tabs\) \{ tab in\n(            PendingCreateBucketRunner\()/        ForEach([tabsModel.activeTab]) { tab in\n\$1/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R2b the hand-off function builds a second sheet beside its call to the route' \
///   --apply "perl -0pi -e 's/(        openCreateContainerSheet\(in: tab, session: session\)\n        return \.handedToTheRoute)/        createBucketSheetItem = CreateBucketSheetItem(recorder: tab.auditRecorder, settings: session.remoteFS as! any S3BucketSettings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n\$1/' Sources/MacSCPAppKit/ContentView.swift"
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
///     macSCPAppKitTests.SidebarNewBucketTests/theHandOffGoesThroughTheRouteAndBuildsNoSheetOfItsOwn()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R3b openCreateContainerSheet builds a second sheet beside its call to handleConnectionAction' \
///   --apply "perl -0pi -e 's/(        handleConnectionAction\(action, in: tab, session: session\)\n)(    \}\n\n    \/\/\/ Whether the menu row for)/\$1        if let settings = session.remoteFS as? any S3BucketSettings {\n            createBucketSheetItem = CreateBucketSheetItem(recorder: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n        }\n\$2/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// after the fix: ── control: 89 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 89 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.EmptyContainerListTests/theButtonIsRoutedThroughTheConnectionAction()
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests' \
///   --label 'R5b the sidebar declares a ConnectionViewModel in code (the control for R5)' \
///   --apply "perl -0pi -e 's/(    let onCreateBucket: SessionRowCreateBucketEffect<StoredSession>\n)/\$1    var heldConnection: ConnectionViewModel? { nil }\n/' Sources/MacSCPAppKit/SessionSidebar.swift"
/// after the fix: ── control: 25 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 25 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theSidebarOwnsNoConnection()
/// ```
///
/// ## Fix round 2: the re-review's plants, and what each guard is made of now
///
/// The re-review planted ten more violations and four came back GREEN. Round 1
/// had answered each GREEN with a scan for one more spelling; this round answers
/// with a boundary where one exists and an equality where one does not.
///
/// - **The sheet item** (`N1m`, `N2b`): `CreateBucketSheetItem` is declared in
///   `ContentView+MenuActions.swift` with a `fileprivate` initialiser (on the
///   initialiser, not the type: every file still holds and presents the item).
///   `N1m`, a factory with `.init(` written through
///   `$createBucketSheetItem.wrappedValue` in another file, no longer compiles:
///   `'ContentView.CreateBucketSheetItem' initializer is inaccessible due to
///   'fileprivate' protection level`. The boundary cannot see inside the one
///   file that may construct, and `N2b` is exactly that: it stayed GREEN with the
///   boundary and the literal count, so the count now counts EVERY mention of
///   `createBucketSheetItem` over the App target (three: declaration,
///   presentation, the one store), which any write has to add to.
/// - **The runner** (`R1`, `N4a`-`N4d`): a view-structure property nothing here
///   can execute, so the test compares the WHOLE region of the one mount, from
///   its `.background {` to the closing brace and the modifier after it, with
///   the expected lines, and counts constructions of the runner over the App
///   target under both spellings. That reddened all five. It did not redden
///   `N4e`, a runner built through its metatype in another file, so the runner's
///   initialiser is `fileprivate` too. The equality is the right trade over the
///   alternatives measured here: the region is seven lines, it cannot go quiet,
///   and its price is brittleness to a reformat of that block, which is a
///   one-line edit of the expectation. The access level alone could not have
///   done the job, because the in-file plants (`N4a`, `N4b`, `N4d`, `R1`) are
///   in the one file the initialiser is visible from.
///
/// **Reading the BUILD FAILED lines.** A plant that does not compile measured
/// nothing about the tests, and here that is the intended outcome for a plant the
/// type system now refuses. `N4f` and `N4g` are the clean demonstrations: the
/// same violation placed in a function of its own, so the only error is the
/// access level. `N4c` and `N4e` also came back BUILD FAILED on the final tree,
/// but with `the compiler is unable to type-check this expression in reasonable
/// time` at the surrounding `body` (`ContentView+Sheets.swift:451:13` and
/// `:446:13`), which I did NOT trace to the access level; their verdict on the
/// earlier tree (RED, and GREEN) is the evidence about them. The re-review's
/// `N4a`, `N4b`, `N4c`, `N4d`, `N1m` and `N2b` are reproduced byte for byte by
/// the perl programs below (compared on copies of the files against its own
/// plant files); `R1` is round 1's, `N4e`, `N4f` and `N4g` are mine. The
/// re-review's verdicts at the tree before this round, which I did not re-run:
/// `N4a`-`N4d`, `N1m` and `N2b` GREEN, `R1` RED.
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'R1 the runner is mounted once for the active tab, not per tab' \
///   --apply "perl -0pi -e 's/        ForEach\(tabsModel\.tabs\) \{ tab in\n            (PendingCreateBucketRunner\(\n)                tab: tab, (activeTabID: tabsModel\.activeTab\.id,\n)                (onDeliver: \{ deliverPendingCreateBucket\(on: [^)]*\) \}\))\n        \}\n/        \$1                tab: tabsModel.activeTab, \$2                \$3\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4a a second mount, literal, inside the same ForEach' \
///   --apply "perl -0pi -e 's/(            PendingCreateBucketRunner)(\(\n(?:.*\n){2})/\$1\$2\$1\$2/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4b a second mount spelled PendingCreateBucketRunner.init( inside the same ForEach' \
///   --apply "perl -0pi -e 's/(            PendingCreateBucketRunner)(\(\n(?:.*\n){2})/\$1\$2\$1.init\$2/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4c a second mount in another file (ContentView+Sheets.swift)' \
///   --apply "perl -0pi -e 's/(        content\n)(        \/\/ \(M8a\/T4\))/\$1        .background {\n            ForEach(tabsModel.tabs) { tab in\n                PendingCreateBucketRunner(\n                    tab: tab, activeTabID: tabsModel.activeTab.id,\n                    onDeliver: { deliverPendingCreateBucket(on: \\\$0) })\n            }\n        }\n\$2/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4d the ForEach kept verbatim but gated by an if that is never true' \
///   --apply "perl -0pi -e 's/(        ForEach\(tabsModel\.tabs\) \{ tab in\n            PendingCreateBucketRunner\((?:.*\n){3}        \}\n)/        if tabsModel.tabs.count > 99 {\n\$1        }\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4e a runner constructed through its metatype in another file' \
///   --apply "perl -0pi -e 's/(                    jumpToOpenSession\(request\)\n)/\$1                    let runnerType = PendingCreateBucketRunner.self\n                    _ = runnerType.init(tab: tabsModel.activeTab, activeTabID: tabsModel.activeTab.id, onDeliver: { _ in })\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 90 test(s) ran and NONE of them noticed the plant.
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N1m a sheet item built by a factory with .init( and written through $createBucketSheetItem.wrappedValue, in ContentView+Sheets.swift' \
///   --apply "perl -0pi -e 's/(                    jumpToOpenSession\(request\)\n)/\$1                    \@MainActor func make(_ tab: SessionTab, _ session: BrowserSession, _ settings: any S3BucketSettings) -> CreateBucketSheetItem {\n                        .init(recorder: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n                    }\n                    if let tab = tabsModel.tabs.first(where: { tab in tab.id == request.existingTabID }), let session = tab.session, let settings = session.remoteFS as? any S3BucketSettings {\n                        \\\$createBucketSheetItem.wrappedValue = make(tab, session, settings)\n                    }\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
///         |                          `- error: 'ContentView.CreateBucketSheetItem' initializer is inaccessible due to 'fileprivate' protection level
///     ContentView+Sheets.swift:110:26: error: 'ContentView.CreateBucketSheetItem' initializer is inaccessible due to 'fileprivate' protection level
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
///         |                          `- error: 'ContentView.CreateBucketSheetItem' initializer is inaccessible due to 'fileprivate' protection level
///     ContentView+Sheets.swift:110:26: error: 'ContentView.CreateBucketSheetItem' initializer is inaccessible due to 'fileprivate' protection level
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N2b a helper called from openCreateContainerSheet builds the item with .init( and $createBucketSheetItem.wrappedValue, same file' \
///   --apply "perl -0pi -e 's/(        else \{ return \}\n        handleConnectionAction\(action, in: tab, session: session\)\n)(    \}\n)/\$1        buildExtraSheet(in: tab, session: session)\n    }\n\n    func buildExtraSheet(in tab: SessionTab, session: BrowserSession) {\n        func make(_ settings: any S3BucketSettings) -> CreateBucketSheetItem {\n            .init(recorder: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n        }\n        if let settings = session.remoteFS as? any S3BucketSettings {\n            \\\$createBucketSheetItem.wrappedValue = make(settings)\n        }\n\$2/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// with the region equality and the count, before the initialisers were confined:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 90 test(s) ran and NONE of them noticed the plant.
/// on the final tree:
///   ── control: 90 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 90 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4f a runner constructed by its literal in a function of its own in ContentView+Sheets.swift' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView {\n    func extraRunner(_ tab: SessionTab) -> some View {\n        PendingCreateBucketRunner(tab: tab, activeTabID: tab.id, onDeliver: { _ in })\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// on the final tree:
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
///     ContentView+Sheets.swift:794:9: error: 'PendingCreateBucketRunner' initializer is inaccessible due to 'fileprivate' protection level
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'SidebarNewBucketTests|SessionRowActivationTests|PerformSessionRowInputTests|SessionRowActivationWiringTests|EmptyContainerListTests' \
///   --label 'N4g a runner constructed through its metatype in a function of its own in ContentView+Sheets.swift' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView {\n    func extraRunner(_ tab: SessionTab) -> some View {\n        let runnerType = PendingCreateBucketRunner.self\n        return runnerType.init(tab: tab, activeTabID: tab.id, onDeliver: { _ in })\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// on the final tree:
///   RESULT: BUILD FAILED — no test ran, so this probe measured NOTHING.
///     ContentView+Sheets.swift:795:27: error: 'PendingCreateBucketRunner' initializer is inaccessible due to 'fileprivate' protection level
/// ```
///
/// ## Fix round 3: a correction of the access-level claim, and spans that read too far
///
/// **The correction.** Round 2 adopted `fileprivate` on an initialiser as a
/// structural boundary and wrote, in three comments and this suite, that no
/// other file can construct the type "under any spelling". That is true of the
/// literal call and the call through the metatype, which is what was measured,
/// and false in general: a struct extension in another file can declare an
/// initialiser of its own that assigns the stored properties directly (they are
/// internal), and that compiles (Q8 for the sheet item, Q9 for the runner; both
/// GREEN in the re-review). For the runner that was a real hole; for the sheet
/// item a use is still one more mention of the state's name (Q14), so only the
/// words were wrong. The comments now say what the access level does, the test
/// that overstated it is renamed to what it checks, and the TYPE's name is
/// counted over the App target for both types, read off the type with
/// `String(describing:)`, which does not buy a spelling at a time the way a
/// count of the literal and of the metatype did (it reddens Q5, Q8 and Q9).
/// This sentence read, verbatim: "every way of building a value names its type,
/// so the count does not buy a spelling at a time" -- false of
/// `createBucketSheetItem = .init(...)`, which names the STATE, so it is the
/// state's count standing beside the type's that catches that shape. Round 4
/// corrected the premise in the test's own doc and in
/// `ContentView+MenuActions.swift` and recorded that as "One loose sentence, in
/// two places"; this occurrence and check 1's were the other two, and fix round
/// 5 corrected both.
///
/// **Q7 is GREEN on purpose.** An extra internal initialiser nobody calls
/// constructs nothing. The property is that construction happens in one place;
/// the initialiser's existence is not the violation and its USE is, and a use
/// names the type. **Q1b is GREEN on purpose, and stays open**: `#if false`
/// around the whole layer with every byte of the region unchanged. What
/// separates a live mount from a compiled-out one is execution, nothing in this
/// project executes a view, and another anchor would be one more spelling; the
/// check that stands against it is a person watching the sheet appear
/// (sight-check item 8).
///
/// **The spans.** `ConnectionActionRouteTests` and `CreateBucketSheetTests` read
/// a function body to "the next `func` at the same indent" and an arm to "the
/// next `case .`", both of which run to the end of the file when what is read
/// is the last of its kind. Q10 (a dead `.cors` arm with its store parked in a
/// private function after `handleConnectionAction`) was GREEN, and so were Q16,
/// Q17 and Q18, which I planted into the three `CreateBucketSheetTests` reads
/// the re-review had only read: text the guard looks for, parked after the
/// thing it is named for, satisfied it. `SourceSpans` ends both at a brace.
/// **Q15 goes the other way, on purpose:** it appends a harmless struct and used
/// to turn the guard RED (a false alarm from the same too-wide span); with the
/// span bounded it is GREEN, which is the fix and not a lost catch.
///
/// **Reading these verdicts.**
/// - Filter the plants of any file under `Sources/MacSCPAppKit` by the module
///   (`macSCPAppKitTests`, control 3141 functions at the first commit of the
///   round and 3146 after `SourceSpans` brought its five), not by a list of
///   suites: the five-suite filter of the earlier rounds did not contain
///   `ConnectionActionRouteTests`, and Q15 was GREEN under it and RED under the
///   module. End the round with a plain `swift test`. The price measured by the
///   re-review was about 3:34 to 4:16 per plant against 2:17 to 2:31.
/// - N1cm and R2 of the earlier rounds are BUILD FAILED now where they were
///   RED: the build refuses what the tests used to catch. That is a stronger
///   verdict, but it means those two no longer measure what they measured, and
///   the literal count is exercised only by in-file plants (N2a, N3a, R3).
/// - Q5, Q9 and Q1b show PLANT FAILED at the first commit of the round: the
///   command I generated carried an apostrophe inside its own single quotes
///   ("manager's"). The regenerated command printed below ran at the final tree.
/// - The re-review's `Q-` definitions are executed from its own `gen.py`, and
///   every command below was compared, byte for byte, with the plain
///   `str.replace` semantics of those steps on copies of the tree's files;
///   Q16, Q17 and Q18 are mine, and were compared the same way.
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q2 the runner body never calls onDeliver (mounted, inert)' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)            \.onChange\(of: signal, initial: true\) \{ _, _ in\n                onDeliver\(tab\)\n            \}\n/\$1            .onChange(of: signal, initial: true) { _, _ in\n                _ = tab\n            }\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q3 the runner watches a constant, not its signal (mounted, never fires after first)' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)            \.onChange\(of: signal, initial: true\) \{ _, _ in\n/\$1            .onChange(of: false, initial: false) { _, _ in\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q4 the runner body is EmptyView (mounted, inert)' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)        Color\.clear\n            \.frame\(width: 0, height: 0\)\n            \.allowsHitTesting\(false\)\n            \.onChange\(of: signal, initial: true\) \{ _, _ in\n                onDeliver\(tab\)\n            \}\n/\$1        EmptyView()\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q5 a second per-tab mount in the same file, through the metatype' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView {\n    func extraRunner(_ tab: SessionTab) -> some View {\n        let runnerType = PendingCreateBucketRunner.self\n        return runnerType.init(tab: tab, activeTabID: tab.id, onDeliver: { _ in })\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/    \/\/ The create-bucket sheet after the connection manager\x27s \"Connect and\n/    .background {\n        ForEach(tabsModel.tabs) { tab in\n            extraRunner(tab)\n        }\n    }\n    \/\/ The create-bucket sheet after the connection manager\x27s \"Connect and\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: PLANT FAILED — the --apply command exited non-zero. Nothing was measured.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q8 an initialiser of the sheet item in an extension in ContentView+Sheets.swift' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView.CreateBucketSheetItem {\n    init(viaExtension recorder: AuditRecorder?, settings: any S3BucketSettings, listing: CreateBucketModel.Listing, onCreated: \@escaping () -> Void) {\n        self.recorder = recorder\n        self.settings = settings\n        self.listing = listing\n        self.onCreated = onCreated\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q9 a runner initialiser in an extension in ContentView+Sheets.swift, mounted per tab from ContentView+Detail.swift' \
///   --apply "perl -0pi -e 's/\z/\nextension PendingCreateBucketRunner {\n    init(viaExtension tab: SessionTab, activeTabID: UUID, onDeliver: \@escaping (SessionTab) -> Void) {\n        self.tab = tab\n        self.activeTabID = activeTabID\n        self.onDeliver = onDeliver\n    }\n}\n\nextension ContentView {\n    func extraRunner(_ tab: SessionTab) -> some View {\n        let runner: PendingCreateBucketRunner = .init(viaExtension: tab, activeTabID: tab.id, onDeliver: { _ in })\n        return runner\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift && perl -0pi -e 's/    \/\/ The create-bucket sheet after the connection manager\x27s \"Connect and\n/    .background {\n        ForEach(tabsModel.tabs) { tab in\n            extraRunner(tab)\n        }\n    }\n    \/\/ The create-bucket sheet after the connection manager\x27s \"Connect and\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: PLANT FAILED — the --apply command exited non-zero. Nothing was measured.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q14 the extension initialiser of Q8 used in ContentView+Sheets.swift (store through the state'\''s name)' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView.CreateBucketSheetItem {\n    init(viaExtension recorder: AuditRecorder?, settings: any S3BucketSettings, listing: CreateBucketModel.Listing, onCreated: \@escaping () -> Void) {\n        self.recorder = recorder\n        self.settings = settings\n        self.listing = listing\n        self.onCreated = onCreated\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift && perl -0pi -e 's/                    jumpToOpenSession\(request\)\n/                    jumpToOpenSession(request)\n                    if let tab = tabsModel.tabs.first(where: { tab in tab.id == request.existingTabID }), let session = tab.session, let settings = session.remoteFS as? any S3BucketSettings {\n                        createBucketSheetItem = .init(viaExtension: tab.auditRecorder, settings: settings, listing: CreateBucketModel.listing(of: session.remote), onCreated: {})\n                    }\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// the re-review, at the tree before this round (not re-run by me): RED
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theCreateBucketSheetIsConstructedInExactlyOnePlace()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q6 control: .hidden() added after the mount block' \
///   --apply "perl -0pi -e 's/    \.backgroundPreferenceValue\(SidebarMeasuredWidthKey\.self\) \{ measuredSidebarWidth in\n/    .hidden()\n    .backgroundPreferenceValue(SidebarMeasuredWidthKey.self) { measuredSidebarWidth in\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): RED
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q7 an internal convenience init added next to the fileprivate one' \
///   --apply "perl -0pi -e 's/            self\.onCreated = onCreated\n        \}\n    \}\n\}\n/            self.onCreated = onCreated\n        }\n\n        init(unchecked recorder: AuditRecorder?, settings: any S3BucketSettings, listing: CreateBucketModel.Listing, onCreated: \@escaping () -> Void) {\n            self.init(recorder: recorder, settings: settings, listing: listing, onCreated: onCreated)\n        }\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3141 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3146 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q1b the snippet, create-bucket and width layers behind #if false, both regions'\'' bytes unchanged' \
///   --apply "perl -0pi -e 's/    \/\/ The session overview\x27s \"Run\" on a snippet \(session overview plan,\n/#if false\n    \/\/ The session overview\x27s \"Run\" on a snippet (session overview plan,\n/' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/                    container: proxy\.size\.width, sidebar: measuredSidebarWidth\)\)\n        \}\n    \}\n    \}\n/                    container: proxy.size.width, sidebar: measuredSidebarWidth))\n        }\n    }\n#endif\n    }\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: PLANT FAILED — the --apply command exited non-zero. Nothing was measured.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3146 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q10 the cors arm is dead; its store sits in a private func after handleConnectionAction' \
///   --apply "perl -0pi -e 's/                corsSheetItem = BucketCORSSheetItem\(\n                    recorder: tab\.auditRecorder, bucket: bucket, settings: settings\)\n/                _ = (bucket, settings)\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/            \}\n        \}\n    \}\n\}\n/            }\n        }\n    }\n\n    private func parkedCorsStore(_ tab: SessionTab, _ bucket: String, _ settings: any S3BucketSettings) {\n        corsSheetItem = BucketCORSSheetItem(recorder: tab.auditRecorder, bucket: bucket, settings: settings)\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the re-review, at the tree before this round (not re-run by me): GREEN
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3141 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ConnectionActionRouteTests/theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q15 a struct with `let id = UUID()` after handleConnectionAction, at the end of the file' \
///   --apply "perl -0pi -e 's/\z/\nextension ContentView {\n    struct SpareItem: Identifiable {\n        let id = UUID()\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the re-review, at the tree before this round (not re-run by me): RED
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3141 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ConnectionActionRouteTests/theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor()
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3146 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q16 the sheet is handed an empty listing; the pane listing sits in a private func after handleConnectionAction' \
///   --apply "perl -0pi -e 's/                    listing: CreateBucketModel\.listing\(of: session\.remote\),\n/                    listing: CreateBucketModel.Listing(names: [], isKnown: true),\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/            \}\n        \}\n    \}\n\}\n/            }\n        }\n    }\n\n    private func parkedListing(_ session: BrowserSession) -> CreateBucketModel.Listing {\n        CreateBucketModel.listing(of: session.remote)\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the re-review: not planted
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3141 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.CreateBucketSheetTests/theDispatcherHandsTheSheetTheRemotePanesListing()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q17 a made bucket no longer refreshes the pane; the refresh sits in a private func after handleConnectionAction' \
///   --apply "perl -0pi -e 's/                    onCreated: \{ \[remote = session\.remote\] in\n                        Task \{ await remote\.refresh\(\) \}\n                    \}\)\n/                    onCreated: { [remote = session.remote] in\n                        _ = remote\n                    })\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/            \}\n        \}\n    \}\n\}\n/            }\n        }\n    }\n\n    private func parkedRefresh(_ remote: RemoteBrowserViewModel) async {\n        await remote.refresh()\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the re-review: not planted
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3141 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.CreateBucketSheetTests/aMadeBucketRefreshesThePaneThatListsIt()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'Q18 the route'\''s createBucket gate no longer asks the model; the model'\''s call sits in a private func after isAvailable(in:)' \
///   --apply "perl -0pi -e 's/            context\.settings != nil\n                && CreateBucketModel\.isOffered\(\n                    rootIsContainerList: context\.rootIsContainerList, paneBucket: context\.bucket\)\n        \}\n    \}\n/            context.settings != nil && context.rootIsContainerList && context.bucket == nil\n        }\n    }\n\n    private func parkedGate(_ context: ConnectionActionContext) -> Bool {\n        CreateBucketModel.isOffered(\n            rootIsContainerList: context.rootIsContainerList, paneBucket: context.bucket)\n    }\n/' Sources/MacSCPAppKit/ConnectionActionRoute.swift"
/// the re-review: not planted
/// at the first commit of this round (the two guards still read to the end of the file):
///   ── control: 3141 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3141 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3146 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3146 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.CreateBucketSheetTests/theRoutesGateAsksTheModelsRule()
/// ```
/// ## Fix round 4: a brace in a string literal, and the third suite's span
///
/// **The defect, and a figure the brief got wrong in the safe direction.** This
/// suite's own `functionBody(named:in:)` counted `{` and `}` over the raw
/// characters of the text it was handed, so a brace that was not code decided
/// where a span ended. The brief said "all four of its callers hand it
/// `SourceCorpus.commentFree(of:)`"; there were FIVE, and only two were handed
/// that view -- the other three were handed the RAW text, where a brace in a
/// COMMENT counts as well. One command, from the repository root:
///
///     git show ffbd0678:Tests/macSCPAppKitTests/SidebarNewBucketTests.swift | /usr/bin/grep -n -e 'Self\.functionBody(' -e 'SourceCorpus\.text(of:' -e 'SourceCorpus\.commentFree(of:'
///
/// prints 15 lines at that commit: the five calls (1328, 1444, 1566, 1588,
/// 1612), the five reads that feed them -- `SourceCorpus.text` at 1327, 1587
/// and 1603 (the hand-off, the Open Anyway answer, the row gate), `commentFree`
/// at 1443 and 1535 (the sheet item, the runner) -- and five more reads this
/// helper is not handed at all (1389 and 1524, the per-file reads of the two
/// walks; 1337, the hand-off's control read; 1446 and 1463, the second
/// `ContentView.swift` read and the sidebar scan). 5 + 5 + 5; the first draft
/// of this paragraph said "the other four lines are per-file reads inside the
/// two walks", which was wrong in the count and in the attribution, and
/// re-running the command after writing the sentence is what caught it.
///
/// It is the defect round 3 fixed in `ConnectionActionRouteTests` and
/// `CreateBucketSheetTests` with `SourceSpans`, left in the file round 3 was
/// editing most, reached through a different door: not "the next sibling never
/// comes" but "the brace that would have ended the span was counted inside a
/// sentence". The helper now goes through `SourceSpans.Views`, which counts
/// braces in the string-and-comment-blanked view and slices the literal-keeping
/// one, and it throws rather than return an unbounded span.
///
/// **Check 4 claimed more than it checked.** It asked that the runner's text
/// contain `onDeliver(tab)` and `.onChange(of: signal, initial: true)`, while
/// its comment said the body calls the one from the other -- and R3, the call
/// kept in a method of the runner nobody calls, passed. The bounded span makes
/// the real property expressible, so the call is read from the `.onChange`'s own
/// block now -- and, since fix round 5, from the view where string literals are
/// blanked (plant T1 of that round: an `onChange` body whose whole content was
/// `_ = "onDeliver(tab)"` delivered nothing and passed). The one `contains` left
/// on the runner's own text stays as the positive control that the anchor is
/// spelled as the block is found by. This passage read, verbatim: "the two
/// `contains` checks stay as the positive control that the anchor is spelled as
/// the block is found by" -- the round deleted the other one, so there was one
/// and not two.
///
/// **A third suite had the shape round 3 replaced.**
/// `ObjectLockSheetTests.theFileActionArmAssignsAnItemTheWindowPresents` read
/// `handleBrowserMenuEntry` up to the next `\n    func `, which a `private func`
/// does not end; it reads `SourceSpans.functionBody` now.
///
/// **One loose sentence, in two places**, corrected rather than appended to:
/// "every way of building a value names its type" (this file) and "a use names
/// the type" (`ContentView+MenuActions.swift`) are both false of
/// `createBucketSheetItem = .init(...)`, which names the STATE. It is the state's
/// count that catches that shape, and Q14 and Q19 are red through it with no new
/// mention of the type.
///
/// **Reading these verdicts.** Control 3150 functions throughout: 3146 of round
/// 3 plus the four new `SourceSpans` controls. "Before" is the tree with this
/// round's fix absent. For R1, R1c, R2, R2b and R3 that is the third re-review's
/// own measurement at `ffbd0678`, which I did not re-run; for S1 and S2 it is my
/// run at `e26a116e`, this round's second commit, where `ObjectLockSheetTests`
/// was still unfixed. L4 is the benign control and was run at the final tree
/// only. Every verdict line below is copied from the probe's output.
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'R1 Q2 (the runner never calls onDeliver) plus an opening brace in a string in the runner, the call parked after the struct at the end of the file' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)            \.onChange\(of: signal, initial: true\) \{ _, _ in\n                onDeliver\(tab\)\n            \}\n/\$1            .onChange(of: signal, initial: true) { _, _ in\n                _ = tab\n            }\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)    let onDeliver: \(SessionTab\) -> Void\n/\$1    let onDeliver: (SessionTab) -> Void\n    private let bracePad = \"{\"\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/\z/\nprivate func parkedDeliver(_ tab: SessionTab, _ onDeliver: (SessionTab) -> Void) {\n    onDeliver(tab)\n}\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the third re-review, at `ffbd0678` (not re-run by me): GREEN
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'R1c control for R1: Q2 with the call parked after the struct, NO brace in a string' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)            \.onChange\(of: signal, initial: true\) \{ _, _ in\n                onDeliver\(tab\)\n            \}\n/\$1            .onChange(of: signal, initial: true) { _, _ in\n                _ = tab\n            }\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/\z/\nprivate func parkedDeliver(_ tab: SessionTab, _ onDeliver: (SessionTab) -> Void) {\n    onDeliver(tab)\n}\n/' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the third re-review, at `ffbd0678` (not re-run by me): RED
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'R2b the item initialiser loses fileprivate, an opening brace in a string in the item, a fileprivate init in a second struct inside the same extension' \
///   --apply "perl -0pi -e 's/        fileprivate init\(\n            recorder: AuditRecorder\?/        init(\n            recorder: AuditRecorder?/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/        let onCreated: \(\) -> Void\n\n        init\(/        let onCreated: () -> Void\n        let bracePad = \"{\"\n\n        init(/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/            self\.onCreated = onCreated\n        \}\n    \}\n\}\n/            self.onCreated = onCreated\n        }\n    }\n\n    struct SpareDecoy {\n        fileprivate init() {}\n    }\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the third re-review, at `ffbd0678` (not re-run by me): GREEN
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theSheetItemIsDeclaredOnceBesideItsBuilderWithAFileprivateInitialiser()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'R2 the item initialiser loses fileprivate, a brace in a string in the item, a fileprivate init parked in a struct at the END of the file' \
///   --apply "perl -0pi -e 's/        fileprivate init\(\n            recorder: AuditRecorder\?/        init(\n            recorder: AuditRecorder?/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/        let onCreated: \(\) -> Void\n\n        init\(/        let onCreated: () -> Void\n        let bracePad = \"{\"\n\n        init(/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/\z/\nstruct SpareDecoy {\n    fileprivate init() {}\n}\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the third re-review, at `ffbd0678` (not re-run by me): RED (the over-read stopped at the extension’s brace, short of the decoy)
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theSheetItemIsDeclaredOnceBesideItsBuilderWithAFileprivateInitialiser()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'R3 Q2 (the onChange no longer delivers) with the onDeliver call kept in a method of the runner nobody calls' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)            \.onChange\(of: signal, initial: true\) \{ _, _ in\n                onDeliver\(tab\)\n            \}\n/\$1            .onChange(of: signal, initial: true) { _, _ in\n                _ = tab\n            }\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)    private var signal: Signal \{\n/\$1    private func neverCalled() {\n        onDeliver(tab)\n    }\n\n    private var signal: Signal {\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// the third re-review, at `ffbd0678` (not re-run by me): GREEN
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'L4 benign control: a closing and an opening brace in string literals inside the runner and inside the sheet item, no violation anywhere' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)    let onDeliver: \(SessionTab\) -> Void\n/\$1    let onDeliver: (SessionTab) -> Void\n    private let braceCloser = \"}\"\n    private let bracePad = \"{\"\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift && perl -0pi -e 's/        let onCreated: \(\) -> Void\n\n        fileprivate init\(/        let onCreated: () -> Void\n        let braceCloser = \"}\"\n        let bracePad = \"{\"\n\n        fileprivate init(/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: not run (a GREEN there says nothing the GREEN here does not)
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'S1 the retention arm parked in a private func between handleBrowserMenuEntry and restoreDeletedFiles' \
///   --apply "perl -0pi -e 's/                if side == \.remote, selection\.count == 1, let file = selection\.first,\n                    let lockAction = ObjectLockFileAction\(action: action\),\n                    let target = ObjectLockTarget\.resolve\(\n                        path: file\.path, in: connectionActionContext\(in: tab, session: session\)\),\n                    let settings = session\.remoteFS as\? any S3BucketSettings,\n                    let states = session\.objectLockStates\n                \{\n                    objectLockSheetItem = ObjectLockSheetItem\(\n                        recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,\n                        settings: settings, states: states\)\n                \}\n/                parkedLock(action, selection, side, tab, session)\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/    \/\/\/ The \"Restore\" entry of a deleted row/    private func parkedLock(\n        _ action: FileActionContribution, _ selection: [RemoteFileItem], _ side: BrowserPaneSide,\n        _ tab: SessionTab, _ session: BrowserSession\n    ) {\n        if side == .remote, selection.count == 1, let file = selection.first,\n            let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        {\n            objectLockSheetItem = ObjectLockSheetItem(\n                recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n                settings: settings, states: states)\n        }\n    }\n\n    \/\/\/ The \"Restore\" entry of a deleted row/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `e26a116e` (ObjectLockSheetTests still unfixed):
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// So AT `e26a116e` S1 measured nothing about the span it was written for: the
/// sibling guard read 900 characters from the FIRST `ObjectLockTarget.resolve(`
/// in the file, and parking the arm moves that occurrence into the `.metadata`
/// arm, whose next 900 characters carry no `focus: lockAction.focus`. Not re-run
/// at round 4's final tree: a plant another guard already catches cannot show
/// this one blind, in either direction. S2 is its replacement. This sentence
/// read, verbatim: "So S1 measures NOTHING about the span it was written for"
/// -- present tense and undated, where the non-measurement belongs to
/// `e26a116e` and not to S1. Round 4's re-review ran S1 at `b85de102` and the
/// span guard fixed here was RED on it too; fix round 5 bounded the sibling to
/// the same function body, and its verdict on S1 at that tree is in round 5's
/// own plant block below.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'S2 the ObjectLockFileAction conversion parked in a private func between handleBrowserMenuEntry and restoreDeletedFiles' \
///   --apply "perl -0pi -e 's/                    let lockAction = ObjectLockFileAction\(action: action\),\n/                    let lockAction = parkedLockAction(action),\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/    \/\/\/ The \"Restore\" entry of a deleted row/    private func parkedLockAction(_ action: FileActionContribution) -> ObjectLockFileAction? {\n        ObjectLockFileAction(action: action)\n    }\n\n    \/\/\/ The \"Restore\" entry of a deleted row/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `e26a116e` (ObjectLockSheetTests still unfixed):
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at the final tree:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theFileActionArmAssignsAnItemTheWindowPresents()
/// ```
///
/// ## Fix round 5: the view a check reads, and the window it reads it in
///
/// Three guards read the wrong thing: one the view where string literals
/// survive, two a window bounded by a character count rather than by the code
/// it means to cover. All three were blind in the silent direction AND brittle
/// in the loud one -- a comment with no code change reddens two of them.
///
/// **One of the three needed no decoy planted.** The 1500-character window in
/// `theRetentionFormDrawsTheLineUnderTheModeChoice` over-read `present`'s own
/// block by 144 characters and reached the `private var retentionForm: some
/// View` declaration 1388 characters after its anchor, so plant V1 -- a sheet
/// that shows `EmptyView()` where the retention form belongs -- was satisfied by
/// the DECLARATION of the form it no longer shows. The guard was already
/// satisfied by its neighbour in the tree as committed. Its other check,
/// `legalHoldForm`, has no such neighbour inside the window, which is how a
/// half-blind guard stayed green for four rounds. The figures travel with their
/// commands at the two windows in `ObjectLockSheetTests.swift`.
///
/// **Reading these verdicts.** Control 3150 throughout, 0 pre-existing
/// failures, every run `scripts/mutation-probe --filter 'macSCPAppKitTests'`.
/// "Before" is `b85de102`, round 4's final tree; "after" is `61ef3dbd`, this
/// round's. Every plant below was run at BOTH trees except the two benign
/// controls (T1c, U1b) and S1, whose before is round 4's re-review. Each
/// command is committed as it ran: these blocks were generated FROM the scripts
/// the probe was invoked with, not retyped. Every verdict line is copied from
/// the probe's output.
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'T1 the onChange body keeps onDeliver(tab) only as a string literal, so the runner never delivers' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)                onDeliver\(tab\)\n/\$1                _ = \"onDeliver(tab)\"\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// at `b85de102`, before this round's one-word fix:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.SidebarNewBucketTests/theRunnerIsMountedPerTab()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'T1c benign control for T1: the onChange body keeps the real call AND gains a string literal spelling it' \
///   --apply "perl -0pi -e 's/(struct PendingCreateBucketRunner: View \{.*?)                onDeliver\(tab\)\n/\$1                _ = \"onDeliver(tab)\"\n                onDeliver(tab)\n/s' Sources/MacSCPAppKit/ContentView+Detail.swift"
/// before: not run (a GREEN there says nothing the GREEN here does not)
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1 U1c plus a decoy function above handleBrowserMenuEntry that spells the correct call' \
///   --apply "perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/\/\/\/ that caught it is unchanged\.\nextension ContentView \{\n/\/\/\/ that caught it is unchanged.\nextension ContentView {\n    private func parkedLockItem(\n        _ action: FileActionContribution, _ file: RemoteFileItem, in tab: SessionTab,\n        session: BrowserSession\n    ) -> ObjectLockSheetItem? {\n        guard let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        else { return nil }\n        return ObjectLockSheetItem(\n            recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n            settings: settings, states: states)\n    }\n\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1c the file-action arm hands the sheet focus: .retention instead of the focus the chosen action maps to' \
///   --apply "perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1b benign control for U1: the decoy function above handleBrowserMenuEntry alone, no violation anywhere' \
///   --apply "perl -0pi -e 's/\/\/\/ that caught it is unchanged\.\nextension ContentView \{\n/\/\/\/ that caught it is unchanged.\nextension ContentView {\n    private func parkedLockItem(\n        _ action: FileActionContribution, _ file: RemoteFileItem, in tab: SessionTab,\n        session: BrowserSession\n    ) -> ObjectLockSheetItem? {\n        guard let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        else { return nil }\n        return ObjectLockSheetItem(\n            recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n            settings: settings, states: states)\n    }\n\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: not run (a GREEN there says nothing the GREEN here does not)
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'V1 the sheet no longer shows the retention form; the retentionForm declaration below present sits inside the 1500-character window' \
///   --apply "perl -0pi -e 's/            case \.retention: retentionForm\n/            case .retention: EmptyView()\n/' Sources/MacSCPAppKit/ObjectLockSheet.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theRetentionFormDrawsTheLineUnderTheModeChoice()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'V2 harmless growth: 25 comment lines (1325 characters, no code) at the top of present, pushing both forms out of the 1500-character window' \
///   --apply "perl -0pi -e 's/(private var present: some View \{\n)/\$1 . (\"        \/\/ harmless growth, no code: a comment line.\n\" x 25)/e' Sources/MacSCPAppKit/ObjectLockSheet.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theRetentionFormDrawsTheLineUnderTheModeChoice()
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'W1 the Object Lock sheet presents an EmptyView and the sheet is built in an overlay 127 characters past the presentation anchor' \
///   --apply "perl -0pi -e 's/            ObjectLockSheet\(\n                recorder: item\.recorder, focus: item\.focus, target: item\.target,\n                settings: item\.settings, cache: item\.states\)\n        \}\n/            EmptyView()\n        }\n        .overlay {\n            if let item = objectLockSheetItem {\n                ObjectLockSheet(\n                    recorder: item.recorder, focus: item.focus, target: item.target,\n                    settings: item.settings, cache: item.states)\n            }\n        }\n/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theFileActionArmAssignsAnItemTheWindowPresents()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'W2 harmless growth: 9 comment lines (513 characters, no code) above the sheet call, pushing it out of the 400-character window' \
///   --apply "perl -0pi -e 's/(            ObjectLockSheet\(\n)/(\"            \/\/ harmless growth, no code: a comment line.\n\" x 9) . \$1/e' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// at `b85de102`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theFileActionArmAssignsAnItemTheWindowPresents()
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'S1 the retention arm parked in a private func between handleBrowserMenuEntry and restoreDeletedFiles' \
///   --apply "perl -0pi -e 's/                if side == \.remote, selection\.count == 1, let file = selection\.first,\n                    let lockAction = ObjectLockFileAction\(action: action\),\n                    let target = ObjectLockTarget\.resolve\(\n                        path: file\.path, in: connectionActionContext\(in: tab, session: session\)\),\n                    let settings = session\.remoteFS as\? any S3BucketSettings,\n                    let states = session\.objectLockStates\n                \{\n                    objectLockSheetItem = ObjectLockSheetItem\(\n                        recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,\n                        settings: settings, states: states\)\n                \}\n/                parkedLock(action, selection, side, tab, session)\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/    \/\/\/ The \"Restore\" entry of a deleted row/    private func parkedLock(\n        _ action: FileActionContribution, _ selection: [RemoteFileItem], _ side: BrowserPaneSide,\n        _ tab: SessionTab, _ session: BrowserSession\n    ) {\n        if side == .remote, selection.count == 1, let file = selection.first,\n            let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        {\n            objectLockSheetItem = ObjectLockSheetItem(\n                recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n                settings: settings, states: states)\n        }\n    }\n\n    \/\/\/ The \"Restore\" entry of a deleted row/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `b85de102`, by round 4's re-review: RED, caught by BOTH guards --
/// `theFileActionArmAssignsAnItemTheWindowPresents()` through its own bounded
/// span, and the sibling only because parking the arm moved the first
/// `ObjectLockTarget.resolve(` into the `.metadata` arm, whose next 900
/// characters carry no `focus: lockAction.focus`
/// at `61ef3dbd`:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theFileActionArmAssignsAnItemTheWindowPresents()
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// -- the sibling now catches it because the ROUTER'S BODY no longer holds the
/// arm, which is the reason it should always have had
/// ```
///
/// ## Task 6 closeout: a span that ended at a name, and one that ended too wide
///
/// The five-round cap tripped with two silent holes open, each measured GREEN on a
/// real violation by round 5's re-review. Both are closed here, and both fixes are
/// one line.
///
/// X1: `theRetentionFormDrawsTheLineUnderTheModeChoice` read the `retentionForm`
/// body up to the NAME of the next declaration, so anything DECLARED between the
/// two forms was inside the span -- the per-file retention sheet drawing no form,
/// no mode choice, no date picker and no COMPLIANCE acknowledgement passed, with
/// the mode-detail line parked in an unused view in that gap. It now reads
/// `views.block(openedBy: "private var retentionForm: some View")`.
///
/// U2: fix round 5 replaced that test's sibling's 900-character window with the
/// WHOLE body of `handleBrowserMenuEntry`, which spans the Object Lock arm AND the
/// `.metadata` arm, both spelling `path: file.path`. That fixed the two directions
/// it was aimed at (U1, V2-style comment brittleness) and made the guard weaker in
/// this one: a violation in the real arm, answered for by the other arm, passed.
/// It now reads `SourceSpans.switchArm("case .retention, .legalHold:", in: body)`.
///
/// **Reading these verdicts.** Control 3150 throughout, 0 pre-existing failures,
/// every run `scripts/mutation-probe --filter 'macSCPAppKitTests'` in the
/// FOREGROUND, one at a time. "Before" is `0bbeff1b`, round 5's final tree.
/// "After" is named by its commit SUBJECT and not by a hash: this repo allows only
/// rebase merges, so a hash this branch's own work created stops resolving the
/// moment the work lands (CLAUDE.md, "prefer the run or the subject to a hash from
/// your own branch"). U1, U1c, U1b and S1 are round 5's commands, extracted from
/// the blocks above rather than retyped; X1, X1c and U2 are new. Every command here
/// was generated FROM the script the probe was invoked with, and every verdict line
/// is copied from the probe's own output.
///
/// U2's "before" is a RUN and not the re-review's arithmetic. The re-review derived
/// it from the old window's reach (`the .metadata arm starts 1971 characters after
/// the first ObjectLockTarget.resolve(`, against a 900-character window) and said so.
/// The probe below measures it instead, by restoring `ObjectLockSheetTests.swift` to
/// `b85de102` in the `--apply` before planting: the only other file that differs
/// between those two trees is this one, whose round-5 change reads
/// `ContentView+Detail.swift` and cannot see the plant. It is also the one command
/// in this block that a rebase can stop from running, because it names `b85de102`
/// as a git OBJECT and not as a citation; that commit's subject, which a rebase
/// does preserve, is "test(app): fix round 4's eight plants are committed with
/// their commands".
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'X1 the COMPLIANCE mode-detail line is removed from retentionForm and parked in an unused view declared between the two forms' \
///   --apply "perl -0pi -e 's/            if let detail = model\.modeDetailLine \{\n                Text\(detail\.text\)\n                    \.font\(\.caption\)\n                    \.foregroundStyle\(model\.mode == \.compliance \? Color\.red : Color\.secondary\)\n                    \.fixedSize\(horizontal: false, vertical: true\)\n            \}\n// or die \"X1 step 1: the mode-detail block is not in retentionForm\"' Sources/MacSCPAppKit/ObjectLockSheet.swift && perl -0pi -e 's/    \@ViewBuilder private var legalHoldForm: some View \{\n/    \@ViewBuilder private var parkedLine: some View {\n        if let detail = model.modeDetailLine {\n            Text(detail.text)\n        }\n    }\n\n    \@ViewBuilder private var legalHoldForm: some View {\n/ or die \"X1 step 2: the legalHoldForm declaration is not there\"' Sources/MacSCPAppKit/ObjectLockSheet.swift"
/// at `0bbeff1b`, before the closeout:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theRetentionFormDrawsTheLineUnderTheModeChoice()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'X1c benign control for X1: 25 comment lines (1425 characters, no code) at the top of retentionForm, the mode-detail line untouched' \
///   --apply "perl -0pi -e 's/(\@ViewBuilder private var retentionForm: some View \{\n)/\$1 . (\"            \/\/ harmless growth, no code: a comment line.\n\" x 25)/e or die \"X1c: the retentionForm declaration is not there\"' Sources/MacSCPAppKit/ObjectLockSheet.swift"
/// before: not run (a GREEN there says nothing the GREEN here does not)
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U2 the Object Lock arm hands the sheet focus: .retention while the .metadata arm spells path: file.path and focus: lockAction.focus' \
///   --apply "perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/ or die \"U2 step 1: the sheet item is not built as expected\"' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/                    objectMetadataSheetItem = ObjectMetadataSheetItem\(\n/                    let lockAction = (focus: 0, other: 0)\n                    _ = (path: file.path, focus: lockAction.focus)\n                    objectMetadataSheetItem = ObjectMetadataSheetItem(\n/ or die \"U2 step 2: the metadata sheet item is not built as expected\"' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// at `0bbeff1b`, before the closeout:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U2 at b85de102: the same plant with ObjectLockSheetTests.swift restored to round 4 final, where the guard read 900 characters from the first ObjectLockTarget.resolve(' \
///   --apply "git show b85de102:Tests/macSCPAppKitTests/ObjectLockSheetTests.swift > Tests/macSCPAppKitTests/ObjectLockSheetTests.swift && perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/ or die \"U2 step 1: the sheet item is not built as expected\"' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/                    objectMetadataSheetItem = ObjectMetadataSheetItem\(\n/                    let lockAction = (focus: 0, other: 0)\n                    _ = (path: file.path, focus: lockAction.focus)\n                    objectMetadataSheetItem = ObjectMetadataSheetItem(\n/ or die \"U2 step 2: the metadata sheet item is not built as expected\"' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// the guard at `b85de102`, this tree with that file restored:
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1 U1c plus a decoy function above handleBrowserMenuEntry that spells the correct call' \
///   --apply "perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/\/\/\/ that caught it is unchanged\.\nextension ContentView \{\n/\/\/\/ that caught it is unchanged.\nextension ContentView {\n    private func parkedLockItem(\n        _ action: FileActionContribution, _ file: RemoteFileItem, in tab: SessionTab,\n        session: BrowserSession\n    ) -> ObjectLockSheetItem? {\n        guard let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        else { return nil }\n        return ObjectLockSheetItem(\n            recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n            settings: settings, states: states)\n    }\n\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: round 5's block above (GREEN at `b85de102`, RED at its own tree)
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1c the file-action arm hands the sheet focus: .retention instead of the focus the chosen action maps to' \
///   --apply "perl -0pi -e 's/recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,/recorder: tab.auditRecorder, focus: .retention, target: target,/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: round 5's block above (RED at both of its trees)
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'U1b benign control for U1: the decoy function above handleBrowserMenuEntry alone, no violation anywhere' \
///   --apply "perl -0pi -e 's/\/\/\/ that caught it is unchanged\.\nextension ContentView \{\n/\/\/\/ that caught it is unchanged.\nextension ContentView {\n    private func parkedLockItem(\n        _ action: FileActionContribution, _ file: RemoteFileItem, in tab: SessionTab,\n        session: BrowserSession\n    ) -> ObjectLockSheetItem? {\n        guard let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        else { return nil }\n        return ObjectLockSheetItem(\n            recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n            settings: settings, states: states)\n    }\n\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: not run (a GREEN there says nothing the GREEN here does not)
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: GREEN — 3150 test(s) ran and NONE of them noticed the plant.
/// ```
///
/// ```
/// scripts/mutation-probe --filter 'macSCPAppKitTests' \
///   --label 'S1 the retention arm parked in a private func between handleBrowserMenuEntry and restoreDeletedFiles' \
///   --apply "perl -0pi -e 's/                if side == \.remote, selection\.count == 1, let file = selection\.first,\n                    let lockAction = ObjectLockFileAction\(action: action\),\n                    let target = ObjectLockTarget\.resolve\(\n                        path: file\.path, in: connectionActionContext\(in: tab, session: session\)\),\n                    let settings = session\.remoteFS as\? any S3BucketSettings,\n                    let states = session\.objectLockStates\n                \{\n                    objectLockSheetItem = ObjectLockSheetItem\(\n                        recorder: tab\.auditRecorder, focus: lockAction\.focus, target: target,\n                        settings: settings, states: states\)\n                \}\n/                parkedLock(action, selection, side, tab, session)\n/' Sources/MacSCPAppKit/ContentView+MenuActions.swift && perl -0pi -e 's/    \/\/\/ The \"Restore\" entry of a deleted row/    private func parkedLock(\n        _ action: FileActionContribution, _ selection: [RemoteFileItem], _ side: BrowserPaneSide,\n        _ tab: SessionTab, _ session: BrowserSession\n    ) {\n        if side == .remote, selection.count == 1, let file = selection.first,\n            let lockAction = ObjectLockFileAction(action: action),\n            let target = ObjectLockTarget.resolve(\n                path: file.path, in: connectionActionContext(in: tab, session: session)),\n            let settings = session.remoteFS as? any S3BucketSettings,\n            let states = session.objectLockStates\n        {\n            objectLockSheetItem = ObjectLockSheetItem(\n                recorder: tab.auditRecorder, focus: lockAction.focus, target: target,\n                settings: settings, states: states)\n        }\n    }\n\n    \/\/\/ The \"Restore\" entry of a deleted row/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// before: round 5's block above (RED at `b85de102` and at its own tree)
/// at "test(app): the retention form's span ends at its brace, the router's at its arm":
///   ── control: 3150 test(s) ran, 0 pre-existing failures
///   RESULT: RED — 3150 test(s) ran, and the plant was caught by:
///     macSCPAppKitTests.ObjectLockSheetTests/theFileActionArmAssignsAnItemTheWindowPresents()
///     macSCPAppKitTests.ObjectLockSheetTests/theSheetIsOpenedAndRunForTheFileThatWasChosen()
/// ```
///
/// S1's verdict is unchanged, by both guards, and that supersedes one clause of
/// round 5's own S1 block, which read, verbatim: "-- the sibling now catches it
/// because the ROUTER'S BODY no longer holds the arm, which is the reason it should
/// always have had". The sibling no longer reads the router's body; it reads the
/// Object Lock arm inside it, and S1 is red by it for the stronger reason that
/// parking the arm EMPTIES the arm. Nothing in round 5's block is withdrawn beyond
/// that clause's present tense.
///
@Suite("Sidebar: connect and create bucket", .timeLimit(.minutes(5)))
@MainActor
struct SidebarNewBucketTests {
    // MARK: - Whether the entry is offered

    private static func s3(startsAtBucketList: Bool) -> StoredSession {
        StoredSession(
            name: "store", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "key-id", region: "region-1", endpoint: "https://store.invalid",
                bucket: startsAtBucketList ? "" : "one-bucket", usePathStyle: true,
                startsAtBucketList: startsAtBucketList))
    }

    @Test func theEntryIsOfferedForAStoredS3ConnectionInBucketListMode() {
        #expect(ConnectionActionRoute.createBucket.isOffered(onStored: Self.s3(startsAtBucketList: true)))
    }

    /// Review Focus 5. The first half restricted create-bucket to bucket-list
    /// mode because a bucket created in a connection rooted in one bucket would
    /// be invisible, and a stored connection configured that way inherits the
    /// reason unchanged. The positive above is this test's control: the same
    /// kind, the same descriptor, the same contribution, and the one thing that
    /// differs is the mode.
    @Test func theEntryIsNotOfferedInSingleBucketMode() {
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: Self.s3(startsAtBucketList: false)))
    }

    /// An S3 record whose block is missing says nothing about its mode, and a
    /// connection that cannot say it starts at a bucket list is not offered
    /// an action that is only safe there.
    @Test func theEntryIsNotOfferedForAnS3ConnectionWithNoS3Block() {
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: StoredSession(name: "bare", kind: .s3)))
    }

    @Test func theEntryIsNotOfferedForSftpOrWebdav() {
        let ssh = StoredSession(
            name: "host", kind: .ssh, ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        let webdav = StoredSession(name: "dav", kind: .webdav)
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: ssh))
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: webdav))
    }

    /// The route is keyed by the backend's own contribution and never by
    /// `ConnectionKind`. The shape that would break that is a record of another
    /// kind that still carries a bucket-list block (an import, or a kind edited
    /// after the fact): offering the entry there would be reading the block
    /// instead of the backend.
    @Test func aBucketListBlockOnAnotherKindOfRecordDoesNotOfferIt() {
        var ssh = StoredSession(
            name: "host", kind: .ssh, ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        ssh.s3 = Self.s3(startsAtBucketList: true).s3
        var webdav = StoredSession(name: "dav", kind: .webdav)
        webdav.s3 = Self.s3(startsAtBucketList: true).s3
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: ssh))
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: webdav))
    }

    /// Exactly one action goes on this surface (spec 6.6). The three bucket-level
    /// actions need a bucket, and a stored connection stands in none.
    @Test func onlyCreateBucketIsOfferedOnAStoredConnection() {
        let stored = Self.s3(startsAtBucketList: true)
        for route in ConnectionActionRoute.allCases {
            #expect(route.isOffered(onStored: stored) == (route == .createBucket), "\(route)")
        }
    }

    // MARK: - The entry's title

    /// The entry connects before it does anything, and connecting is not
    /// silent (it can raise a host-key prompt or a credential prompt), so the
    /// title says both. It is not `connection.action.createBucket`, which names
    /// the toolbar row on a connection that is already open.
    @Test func theTitleNamesTheConnectingAsWellAsTheCreating() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        for locale in ["en", "de", "fr", "pl"] {
            let title = L10n.$localeOverride.withValue(locale) {
                L10n.string("sidebar.connectAndCreateBucket", sentinel)
            }
            let toolbar = L10n.$localeOverride.withValue(locale) {
                L10n.string("connection.action.createBucket", sentinel)
            }
            let connect = L10n.$localeOverride.withValue(locale) {
                L10n.string("sidebar.connect", sentinel)
            }
            #expect(title != sentinel, "\(locale)")
            #expect(title != toolbar, "\(locale): the title is the toolbar row's, which does not say it connects")
            #expect(title.hasPrefix(connect), "\(locale): the title does not begin with the verb the row's own Connect uses")
        }
    }

    // MARK: - What choosing it does

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func makeContentView(
        storeDirectory: URL, sidebarTabFactory: (@MainActor () -> SessionTab)? = nil
    ) -> (view: ContentView, secrets: InMemoryBucketSecretStore, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let secrets = InMemoryBucketSecretStore()
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: storeDirectory),
            secrets: secrets,
            auditStore: AuditLogStore(directory: storeDirectory.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: storeDirectory),
            keys: ManagedKeyStore(directory: storeDirectory))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: secrets,
            managedKeyStore: ManagedKeyStore(directory: storeDirectory),
            sidebarTabFactory: sidebarTabFactory)
        return (view, secrets, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
        })
    }

    /// A tab whose dial hands back `fs`, or throws when `fs` is `nil`.
    private func makeTab(dialing fs: BucketListFileSystem?, dials: DialCounter = DialCounter()) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                dials.increment()
                guard let fs else { throw RemoteFSError.protocolError(reason: "dial refused") }
                return fs
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab (which carries the real connector) with
    /// one this suite controls.
    private func installControlledTab(in view: ContentView, dialing fs: BucketListFileSystem?)
        -> (tab: SessionTab, dials: DialCounter)
    {
        let dials = DialCounter()
        let controlled = makeTab(dialing: fs, dials: dials)
        let original = view.tabsModel.activeTab
        view.tabsModel.addTab(controlled)
        view.tabsModel.closeTab(original.id)
        return (controlled, dials)
    }

    /// A stored S3 connection in bucket-list mode, with the secret the dial's
    /// own pre-flight validation asks for kept in the in-memory store.
    private func storeSession(
        in directory: URL, view: ContentView, secrets: InMemoryBucketSecretStore
    ) -> StoredSession {
        let stored = Self.s3(startsAtBucketList: true)
        try? SessionStore(directory: directory).upsert(stored)
        try? secrets.savePassword("placeholder", for: stored.id)
        view.sessionListViewModel.reload()
        return stored
    }

    /// The connection is owned by a TAB: the one the window already holds, or
    /// a fresh one when the front tab is connected, and in both cases the file
    /// system the dial produced is the one that tab's session holds. That is
    /// the whole content of "a real tab rather than an ownerless connection"
    /// (spec 6.6), stated as an identity rather than as a count.
    @Test func choosingItOpensATabRatherThanAnOwnerlessConnection() async throws {
        let workDir = makeTempDirectory("new-bucket-owner")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, dials) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)

        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(dials.count == 1, "one choice must make exactly one dial")
        #expect(view.tabsModel.tabs.contains { $0.id == tab.id })
        let held = try #require(tab.session?.remoteFS as? BucketListFileSystem)
        #expect(held === fs, "the session the tab holds is not the connection the dial made")
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.pendingCreateBucket != nil, """
            nothing was armed on the tab, so the connect would end with no sheet — and the \
            checks below would be satisfied by an entry that only connects.
            """)
    }

    /// The tab rule is the ordinary one: a connected front tab is never torn
    /// down by a sidebar start, so the entry opens a FRESH tab beside it and
    /// the request is armed there, not on the connection already on screen.
    @Test func aConnectedFrontTabIsLeftAloneAndAFreshOneIsOpened() async throws {
        let workDir = makeTempDirectory("new-bucket-fresh")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let freshFS = BucketListFileSystem()
        let freshDials = DialCounter()
        var made: [SessionTab] = []
        let (view, secrets, cleanup) = makeContentView(
            storeDirectory: workDir,
            sidebarTabFactory: {
                let tab = self.makeTab(dialing: freshFS, dials: freshDials)
                made.append(tab)
                return tab
            })
        defer { cleanup() }
        let connectedFS = BucketListFileSystem()
        let (front, _) = installControlledTab(in: view, dialing: connectedFS)
        view.startSession(in: front, with: connectedFS, storedName: "front", startPath: "/")
        let other = Self.s3(startsAtBucketList: true)
        front.activeStoredSessionID = other.id
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        #expect(front.isConnected, "the control is not connected, so the tab rule would not apply")

        view.createBucketFromSidebar(stored)

        let fresh = try #require(made.first, "no fresh tab was made for a connected front tab")
        try await pollUntil("the fresh tab to hold a session") { fresh.session != nil }
        #expect(made.count == 1)
        #expect(fresh.id != front.id)
        #expect(front.session?.remoteFS as? BucketListFileSystem === connectedFS)
        #expect(front.pendingCreateBucket == nil, "the request was armed on the connection already on screen")
        #expect(fresh.pendingCreateBucket != nil)
        #expect(connectedFS.disconnects == 0, "the connected front tab was torn down by a sidebar start")
    }

    /// The hand-off is made when the tab is connected, in front, AND its bucket
    /// list has loaded -- and not before, because the sheet takes a snapshot of
    /// the pane's listing to check names against, and a snapshot taken while
    /// the list is loading says "not loaded" for ever.
    @Test func theHandOffWaitsForTheBucketListAndIsMadeOnce() async throws {
        let workDir = makeTempDirectory("new-bucket-waits")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        let session = try #require(tab.session)

        // Connected and in front, but the pane has not listed anything yet.
        #expect(session.remote.state == .loading, "the control: the list has not loaded")
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        #expect(tab.pendingCreateBucket != nil, "a request that is waiting must stay armed")

        await session.remote.load()
        #expect(session.remote.state == .loaded)
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        #expect(tab.pendingCreateBucket == nil, "the request survived its own hand-off")

        // Exactly once: the observer fires for every later change of the facts
        // it watches, and a dismissed sheet must not come back.
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    /// Cancelling the sheet is `createBucketSheetItem = nil`, which no test here
    /// can perform. What can be measured is that nothing the entry armed
    /// outlives its hand-off, so a dismissed sheet leaves a tab that is just a
    /// connected tab: it holds its session, names its stored connection, owes
    /// nobody a sheet, and closes the way every tab closes -- through the one
    /// teardown, which disconnects the connection it owns, once.
    @Test func cancellingTheSheetLeavesAnOrdinaryConnectedTab() async throws {
        let workDir = makeTempDirectory("new-bucket-cancel")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        // ... the sheet is shown and cancelled here; the observer keeps firing.
        for _ in 0..<3 { #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed) }

        #expect(tab.isConnected)
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.pendingCreateBucket == nil)
        #expect(fs.disconnects == 0, "nothing may close the connection merely because the sheet went")

        await view.teardown(tab, reason: .userRequested)
        #expect(fs.disconnects == 1, "the one teardown must close the connection the tab owns, once")
        #expect(tab.session == nil)
    }

    /// A dial that fails leaves nothing armed: a request left behind would
    /// open the sheet on whatever this tab connects to next.
    @Test func aFailedConnectDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-failed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, dials) = installControlledTab(in: view, dialing: nil)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        #expect(tab.pendingCreateBucket != nil, "the control: the request was armed")
        try await pollUntil("the failed dial to settle") { !tab.isReconnecting }

        #expect(dials.count == 1, "the dial was supposed to be attempted")
        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.session == nil)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A bucket list that FAILED to load drops the request instead of waiting
    /// for ever: nothing will make it `.loaded` by itself, the pane says why,
    /// and the toolbar's menu is still there. The `.waiting` before the load is
    /// this test's control.
    @Test func aBucketListThatFailedToLoadDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-list-failed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem(listFails: true))
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)

        await tab.session?.remote.load()
        guard case .failed = tab.session?.remote.state else {
            Issue.record("the control: the list was supposed to fail to load")
            return
        }
        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A tab that ends up on a different stored connection than the one the
    /// request was made for drops it, rather than offering to create a bucket
    /// in an account the user did not pick.
    @Test func aTabConnectedToAnotherStoredConnectionDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-other")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        tab.activeStoredSessionID = UUID()

        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A tab behind the front one keeps its request until it is in front: the
    /// sheet is the window's, and presenting it over another tab's pane would
    /// offer to create a bucket in a connection the user is not looking at.
    @Test func aRequestOnABackgroundTabWaitsUntilItIsInFront() async throws {
        let workDir = makeTempDirectory("new-bucket-background")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        let elsewhere = makeTab(dialing: nil)
        view.tabsModel.addTab(elsewhere)
        view.tabsModel.activate(elsewhere.id)

        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        #expect(tab.pendingCreateBucket != nil)
        view.tabsModel.activate(tab.id)
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
    }

    /// The teardown drops an armed request on its way out, for the reason it
    /// drops a pending snippet: every route into it is leaving this connection
    /// on purpose, and the connection the request was armed for is the one
    /// being left.
    @Test func teardownDropsAnArmedRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-teardown")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(tab.pendingCreateBucket != nil, "the control: the request was armed")

        await view.teardown(tab, reason: .userRequested)

        #expect(tab.pendingCreateBucket == nil)
    }

    /// The request is dropped BEFORE the teardown's first suspension point, not
    /// after the connection has closed. The hand-off needs only a session, a
    /// loaded list and the front tab, and the session stays attached while the
    /// terminal shuts down and the connection closes, so a request still armed
    /// there is one the runner could act on mid-teardown. The state is read
    /// while `disconnect()` is parked, which is the only moment the order shows.
    @Test func anArmedRequestIsGoneBeforeTheConnectionStartsClosing() async throws {
        let workDir = makeTempDirectory("new-bucket-midteardown")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem(holdsDisconnect: true)
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        #expect(tab.pendingCreateBucket != nil, "the control: armed, with everything the hand-off needs")

        let teardown = Task { await view.teardown(tab, reason: .userRequested) }
        _ = await fs.disconnectEntered.wait()
        // Parked inside `disconnect()`: the session is still attached.
        let stillAttached = tab.session != nil
        let armed = tab.pendingCreateBucket != nil
        let delivery = view.deliverPendingCreateBucket(on: tab)
        fs.disconnectRelease.signal()
        await teardown.value

        #expect(stillAttached, "the control: the teardown had already detached the session")
        #expect(!armed, "the request was still armed while the connection was closing")
        #expect(delivery == .notArmed)
    }

    /// The already-open question carries the request, so "Open Anyway" starts
    /// what was asked for. The answer is a function of the request alone.
    @Test func theAlreadyOpenQuestionCarriesTheRequestAndOpenAnywayArmsIt() async throws {
        let workDir = makeTempDirectory("new-bucket-query")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, dials) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        let holder = makeTab(dialing: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(tab.id)

        let request = try #require(view.createBucketFromSidebar(stored))
        #expect(request.createsBucket, "the question dropped what was asked for")
        #expect(dials.count == 0, "asking must not dial")
        #expect(tab.pendingCreateBucket == nil, "asking must not arm anything")

        view.startWithoutAsking(
            request.stored, paneVisibility: request.paneVisibility,
            pendingSnippet: request.pendingSnippet, createsBucket: request.createsBucket)
        #expect(tab.pendingCreateBucket != nil, "Open Anyway started a plain connect")
        try await pollUntil("the dial to settle") { tab.session != nil }
    }

    // MARK: - "Go to Existing Tab" carries the request over

    /// A connected tab holding `stored`, with its bucket list loaded -- the
    /// state the already-open query is raised against. Built the way a user
    /// gets there: a first "Connect and Create Bucket…" connects the tab, and
    /// its own hand-off is consumed, so the tab is armed with nothing.
    private func connectedHolder(
        _ view: ContentView, _ tab: SessionTab, _ stored: StoredSession
    ) async throws {
        view.createBucketFromSidebar(stored)
        try await pollUntil("the holder to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        #expect(tab.pendingCreateBucket == nil, "the control: the first request was consumed")
    }

    /// The maintainer's decision of 2026-11-10: "Go to Existing Tab" on a
    /// "Connect and Create Bucket…" question arms the request on the tab it
    /// activates, and the delivery that already exists opens the sheet. Here
    /// the tab is already in front and already showing its loaded list, so
    /// nothing else will change when the answer is given: what wakes the
    /// runner is the request itself being armed.
    @Test func goingToTheExistingTabCarriesTheRequestOverToAConnectedFrontTab() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-front")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, dials) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)

        let request = try #require(view.createBucketFromSidebar(stored))
        #expect(request.existingTabID == tab.id)
        #expect(tab.pendingCreateBucket == nil, "asking must not arm anything")
        view.jumpToOpenSession(request)

        #expect(tab.pendingCreateBucket != nil, "the answer dropped the request it was asked for")
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        #expect(dials.count == 1, "answering with the existing tab must not dial again")
        #expect(view.tabsModel.tabs.count == 1, "answering with the existing tab opened another")
    }

    /// The same answer for a tab that is NOT in front: it is activated, and the
    /// request it carries is delivered once it is.
    @Test func goingToTheExistingTabActivatesItAndTheRequestIsDeliveredThere() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-back")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let elsewhere = makeTab(dialing: nil)
        view.tabsModel.addTab(elsewhere)
        view.tabsModel.activate(elsewhere.id)

        let request = try #require(view.createBucketFromSidebar(stored))
        #expect(request.existingTabID == tab.id)
        view.jumpToOpenSession(request)

        #expect(view.tabsModel.activeTabID == tab.id)
        #expect(elsewhere.pendingCreateBucket == nil, "the request was armed on the tab left behind")
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
    }

    /// Without the flag the answer is what it always was: activate, nothing
    /// armed. The flag has to be a thing the request carries, not something
    /// every jump arms.
    @Test func goingToTheExistingTabArmsNothingForAnOrdinaryConnect() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-plain")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)

        let request = try #require(view.connectFromSidebar(stored))
        #expect(!request.createsBucket, "the control: this request does not ask for a bucket")
        view.jumpToOpenSession(request)

        #expect(tab.pendingCreateBucket == nil)
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    /// A list that is still loading at the moment of the jump: the request is
    /// armed and waits, exactly as it does for a tab that has just connected.
    @Test func aRequestCarriedOverWaitsForABucketListThatHasNotLoaded() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-loading")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        view.createBucketFromSidebar(stored)
        try await pollUntil("the holder to hold a session") { tab.session != nil }
        let session = try #require(tab.session)
        tab.pendingCreateBucket = nil
        #expect(session.remote.state == .loading, "the control: the list has not loaded")

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)

        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        await session.remote.load()
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
    }

    /// A list that failed to load at the moment of the jump: the request is
    /// dropped by the delivery, the same as for a fresh tab.
    @Test func aRequestCarriedOverIsDroppedWhenTheBucketListFailedToLoad() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-failed-list")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem(listFails: true))
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        view.createBucketFromSidebar(stored)
        try await pollUntil("the holder to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        tab.pendingCreateBucket = nil
        guard case .failed = tab.session?.remote.state else {
            Issue.record("the control: the list was supposed to fail to load")
            return
        }

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)

        #expect(tab.pendingCreateBucket != nil, "the control: the answer armed the request")
        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// Steps into the first bucket of a connected holder's pane, the way a
    /// double-click on its row does, so the pane stands inside a bucket.
    private func standInsideTheFirstBucket(_ session: BrowserSession) async throws {
        let bucket = try #require(session.remote.items.first { $0.path == "/first-bucket" })
        await session.remote.open(bucket)
        #expect(session.remote.currentPath == "/first-bucket", "the control: the pane is inside a bucket")
        #expect(session.remote.state == .loaded, "the control: the bucket's own listing loaded")
    }

    /// Final whole-branch review, I1: "Go to Existing Tab" onto a tab that is
    /// browsing INSIDE a bucket. The route offers the sheet only at the list,
    /// so a hand-off made there was a request dropped without a word. The
    /// delivery navigates the pane to the bucket list once, waits for that
    /// listing, and only then hands over.
    @Test func aTabStandingInsideABucketIsNavigatedToTheListAndThenHandedOver() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-inside")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let session = try #require(tab.session)
        try await standInsideTheFirstBucket(session)

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)

        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting, """
            the delivery handed over a request on a pane standing inside a bucket, where the \
            route declines without a word
            """)
        #expect(tab.pendingCreateBucket != nil, "a request that is waiting must stay armed")
        try await pollUntil("the navigation to the bucket list to return") {
            tab.pendingCreateBucket?.bucketListNavigation == .made
        }
        #expect(fs.rootStatCount == 1, "the pane was not navigated to the bucket list exactly once")
        #expect(session.remote.currentPath == "/", "the pane is not at the bucket list")
        #expect(session.remote.state == .loaded)
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        #expect(tab.pendingCreateBucket == nil)
        #expect(tab.remoteNavigationFailure == nil, "a navigation that worked left a failure behind")
    }

    /// The navigation is in flight and the pane is still inside the bucket:
    /// every call of the delivery in that window waits -- it neither hands
    /// over (the route would decline) nor drops (the navigation has not
    /// answered) -- and none of them starts a second navigation.
    @Test func theDeliveryDoesNotHandOverWhileThePaneIsStillInsideTheBucket() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-in-flight")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem(holdsRootStat: true)
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let session = try #require(tab.session)
        try await standInsideTheFirstBucket(session)

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        _ = await fs.rootStatEntered.wait()

        // Held at the navigation's first step: the pane has not moved.
        #expect(session.remote.currentPath == "/first-bucket", "the control: the pane is still inside the bucket")
        #expect(session.remote.state == .loaded, "the control: the pane is not loading")
        #expect(tab.pendingCreateBucket?.bucketListNavigation == .inFlight)
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting, """
            the delivery did not wait for its own navigation while the pane was still inside the bucket
            """)
        #expect(tab.pendingCreateBucket != nil, "the request was dropped while its navigation was in flight")
        #expect(fs.rootStatCount == 1, "a second call started a second navigation")

        fs.rootStatRelease.signal()
        try await pollUntil("the navigation to the bucket list to return") {
            tab.pendingCreateBucket?.bucketListNavigation == .made
        }
        #expect(session.remote.currentPath == "/")
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
    }

    /// The navigation was made and the pane is not at the list (the user went
    /// back into a bucket before the runner looked): the request is dropped,
    /// and the pane is not navigated a second time.
    @Test func aSecondCallAfterTheNavigationDoesNotNavigateAgain() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-once")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let session = try #require(tab.session)
        try await standInsideTheFirstBucket(session)

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        try await pollUntil("the navigation to the bucket list to return") {
            tab.pendingCreateBucket?.bucketListNavigation == .made
        }
        #expect(fs.rootStatCount == 1, "the control: the first navigation was made")
        try await standInsideTheFirstBucket(session)

        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
        #expect(fs.rootStatCount == 1, "the delivery navigated the pane a second time")
        #expect(session.remote.currentPath == "/first-bucket", "the pane was moved again")
    }

    /// The navigation to the bucket list fails: the request is dropped, and the
    /// failure is left for the remote pane's path bar, which shows it the way
    /// it shows a failed typed path -- the attempted path and the message.
    /// `navigate(to:)` rolls the pane back, so it is still inside the bucket.
    @Test func aFailedNavigationToTheBucketListDropsTheRequestAndLeavesItsFailureForThePathBar()
        async throws
    {
        let workDir = makeTempDirectory("new-bucket-jump-nav-fails")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let session = try #require(tab.session)
        try await standInsideTheFirstBucket(session)
        fs.refuseTheRootListFromNowOn()

        let request = try #require(view.createBucketFromSidebar(stored))
        view.jumpToOpenSession(request)
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        try await pollUntil("the navigation's failure to drop the request") {
            tab.pendingCreateBucket == nil
        }

        #expect(fs.rootStatCount == 1, "the control: the navigation was made")
        let failure = try #require(tab.remoteNavigationFailure, "the failed navigation was not surfaced")
        #expect(failure.path == "/")
        #expect(!failure.message.isEmpty)
        #expect(session.remote.currentPath == "/first-bucket", "the failed navigation did not roll back")
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    /// The tab is dialling again by the time the answer is given (a reconnect
    /// began while the question was up): the answer arms nothing, by the same
    /// rule a start applies to a target that is already dialling -- the attempt
    /// belongs to somebody else, and a request left behind would wait for it.
    @Test func aTabThatIsDiallingWhenTheAnswerIsGivenIsNotArmed() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-dialling")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let request = try #require(view.createBucketFromSidebar(stored))
        tab.isReconnecting = true

        view.jumpToOpenSession(request)

        #expect(view.tabsModel.activeTabID == tab.id, "the control: the answer still activates the tab")
        #expect(tab.pendingCreateBucket == nil)
    }

    /// The tab was closed while the question was up: activating an id that
    /// names no tab leaves the active tab alone, and there is nothing to arm
    /// -- least of all on the tab that stayed.
    @Test func aTabClosedWhileTheQuestionWasUpIsNotArmedAnywhere() async throws {
        let workDir = makeTempDirectory("new-bucket-jump-closed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem())
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        try await connectedHolder(view, tab, stored)
        let elsewhere = makeTab(dialing: nil)
        view.tabsModel.addTab(elsewhere)
        view.tabsModel.activate(elsewhere.id)
        let request = try #require(view.createBucketFromSidebar(stored))
        view.tabsModel.closeTab(tab.id)

        view.jumpToOpenSession(request)

        #expect(view.tabsModel.activeTabID == elsewhere.id)
        #expect(elsewhere.pendingCreateBucket == nil)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// An ordinary connect carries no such request: the flag has to be a thing
    /// this entry sets, not a default every start inherits.
    @Test func anOrdinaryConnectArmsNothing() async throws {
        let workDir = makeTempDirectory("new-bucket-ordinary")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.connectFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }

        #expect(tab.pendingCreateBucket == nil)
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    // MARK: - The wiring

    /// The hand-off goes THROUGH the route (`openCreateContainerSheet`, which
    /// asks the backend's descriptor and `handleConnectionAction`) and builds
    /// no sheet of its own. A source scan of comment-free text, with a positive
    /// control beside every negative: a scan for an absent thing that cannot
    /// find the present one is a comment that runs.
    @Test func theHandOffGoesThroughTheRouteAndBuildsNoSheetOfItsOwn() throws {
        let body = try Self.functionBody(
            named: "func deliverPendingCreateBucket(", in: Self.contentViewFile)
        #expect(body.contains("openCreateContainerSheet(in: tab, session: session)"), """
            the hand-off no longer calls `openCreateContainerSheet(in:session:)` -- a sheet \
            presented any other way is a second copy of the rule that decides whether it is \
            possible.
            """)
        #expect(!body.contains("CreateBucketSheetItem("), "the hand-off builds the sheet item itself")
        #expect(!body.contains("createBucketSheetItem"), "the hand-off writes the sheet's state itself")
        // The control: the scan can see the one place the item IS built.
        let actions = try SourceCorpus.text(of: Self.menuActionsFile)
        #expect(actions.contains("createBucketSheetItem = CreateBucketSheetItem("))
    }

    /// The sheet is built in exactly one place in the App target, and the
    /// state that presents it is named in exactly three: where it is declared,
    /// where it is presented, and where the one construction is stored.
    ///
    /// **Three counts, and the name of this test is true of them together and
    /// not of any one.** The literal `CreateBucketSheetItem(`; every mention of
    /// the state's name; and every mention of the TYPE's name. The last is the
    /// one that does not buy a spelling at a time: a literal, a metatype, an
    /// annotation, a typealias and an initialiser declared in an extension (the
    /// spelling the `fileprivate` initialiser does not reach) each name the
    /// type, so each is one of its mentions. It does not catch every
    /// construction on its own, and the sentence here used to claim it did --
    /// "every way of building a value names its type": a contextually typed
    /// `createBucketSheetItem = .init(...)` names the STATE and not the type,
    /// and that is the count which catches that one (plants Q14 and Q19 of the
    /// re-reviews, both red through the state's name with no new mention of the
    /// type). An extra internal initialiser nobody calls constructs nothing, so
    /// its existence is not the violation -- its USE is, and a use is one more
    /// mention of the type's name or of the state's; that disposes of the plant
    /// that added one (Q7 of the re-review).
    ///
    /// **The figures, with the commands that produced them** (from the
    /// repository root, 2026-11-04, `/usr/bin/grep`, on the final fix wave's
    /// tree — a hash is not cited because it would be one from this branch,
    /// which a rebase merge rewrites: see `CLAUDE.md`, "prefer the run or the
    /// subject to a hash from your own branch"):
    ///
    ///     /usr/bin/grep -r -o -F createBucketSheetItem Sources/MacSCPAppKit
    ///
    /// prints 5 occurrences, of which TWO are in `///` lines — both in
    /// `CreateBucketSheetItem`'s own doc comment in
    /// ContentView+MenuActions.swift — so the count in code is 3. A reader who
    /// sees 5 has not excluded comments, and should not "correct" the 3: this
    /// test reads `SourceCorpus.commentFree`, which blanks them structurally;
    ///
    /// **Corrected 2026-11-04.** The sentence above read, verbatim: "prints 4
    /// occurrences, of which one is in a `///` line, so the count in code is 3
    /// (it printed 5, two of them in `///` lines, before this round shortened
    /// the item's own doc comment; the code count did not move). A reader who
    /// sees 5 or 4 has not excluded comments, and should not "correct" the 3".
    /// Withdrawn: the round did not shorten that comment past the two
    /// mentions, so 4-and-one was never true of the tree it was committed
    /// with, and the parenthesis presented the right answer (5, two of them in
    /// `///` lines) as the superseded one. The assertions were and are
    /// correct — 3 in code, one per file — and nothing about them changed
    /// here; what changed is the record beside them, which told the next
    /// reader to distrust the one number that was right. The remaining "5" in
    /// the corrected sentence is now a figure the command prints rather than a
    /// state the tree has left behind.
    ///
    ///     /usr/bin/grep -r -n -F CreateBucketSheetItem Sources/MacSCPAppKit
    ///
    /// prints 4 lines, one of them a comment, so the type's name appears 3 times
    /// in code: its declaration, the state's annotation, the one construction.
    /// The type name is read off the type (`String(describing:)`) and not
    /// written here, so a rename moves the scan with it.
    ///
    /// **A count that must match, over every file of the target, and not a
    /// `!contains` over the places someone thought of.** The first form of this
    /// guard scanned the hand-off's own body; a second construction planted in
    /// the sibling "Go to Existing Tab" answer, which is where the next one is
    /// likely to be written, passed. A count fails loudly the moment a site is
    /// added OR removed -- removing the one is red too, so the scan cannot go
    /// quiet by no longer finding it. Occurrences are counted, not lines.
    @Test func theCreateBucketSheetIsConstructedInExactlyOnePlace() throws {
        let directory = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let itemName = String(describing: ContentView.CreateBucketSheetItem.self)
        var constructions: [String] = []
        var mentions: [String] = []
        var typeMentions: [String] = []
        for url in try SourceCorpus.files(under: directory) where url.pathExtension == "swift" {
            let code = try SourceCorpus.commentFree(of: url)
            let built = code.components(separatedBy: "CreateBucketSheetItem(").count - 1
            // EVERY mention of the state's name, not only `createBucketSheetItem = `:
            // the state is reachable only through its name, so a write through
            // `$createBucketSheetItem.wrappedValue`, in the file whose
            // `fileprivate` initialiser the access level cannot confine, is still
            // one more mention. (A `.init(` behind a factory in that file is
            // invisible to a count of the literal and was GREEN until this.)
            let named = code.components(separatedBy: "createBucketSheetItem").count - 1
            let typed = code.components(separatedBy: itemName).count - 1
            constructions += Array(repeating: url.lastPathComponent, count: built)
            mentions += Array(repeating: url.lastPathComponent, count: named)
            typeMentions += Array(repeating: url.lastPathComponent, count: typed)
        }
        #expect(constructions == ["ContentView+MenuActions.swift"], """
            `CreateBucketSheetItem(` is constructed at \(constructions) -- expected exactly one \
            site, in ContentView+MenuActions.swift (`handleConnectionAction`'s create-bucket \
            arm). A second copy is how the rule that says the action is possible and the sheet \
            it opens come to disagree about a bucket nobody is looking at.
            """)
        #expect(
            mentions.sorted()
                == ["ContentView+MenuActions.swift", "ContentView+Sheets.swift", "ContentView.swift"],
            """
            `createBucketSheetItem` is named at \(mentions.sorted()) -- expected exactly three: \
            the declaration (ContentView.swift), the presentation (ContentView+Sheets.swift) and \
            the one store (ContentView+MenuActions.swift, the create-bucket arm).
            """)
        #expect(
            typeMentions.sorted()
                == ["ContentView+MenuActions.swift", "ContentView+MenuActions.swift", "ContentView.swift"],
            """
            the type `\(itemName)` is named at \(typeMentions.sorted()) -- expected exactly three: \
            its declaration and the one construction (ContentView+MenuActions.swift) and the \
            state's annotation (ContentView.swift). A fourth is a use the other two counts \
            have no spelling for, such as an initialiser declared in an extension elsewhere.
            """)
    }

    /// What the access level contributes, and nothing more: `CreateBucketSheetItem`
    /// is declared in `ContentView+MenuActions.swift`, once, with a `fileprivate`
    /// initialiser. That makes the literal call and the call through the metatype
    /// fail to compile in any other file. It does NOT confine construction to
    /// this file -- a struct extension elsewhere can declare an initialiser that
    /// assigns the stored properties directly, and that compiles (measured as
    /// plant Q8 of the re-review) -- which is what the type-name count in
    /// `theCreateBucketSheetIsConstructedInExactlyOnePlace` stands beside it for.
    ///
    /// The access level is pinned on the INITIALISER: on the type it would stop
    /// the other files holding the item, which they must
    /// (`ContentView.createBucketSheetItem`). This test is presence, and only
    /// that: an additional internal initialiser in the type passes it, by
    /// design, because an initialiser nobody calls constructs nothing.
    @Test func theSheetItemIsDeclaredOnceBesideItsBuilderWithAFileprivateInitialiser() throws {
        let item = try Self.functionBody(
            named: "struct CreateBucketSheetItem: Identifiable {", in: Self.menuActionsFile)
        #expect(item.contains("fileprivate init("), "the item's initialiser is no longer `fileprivate`")
        let contentView = try SourceCorpus.commentFree(of: Self.contentViewFile)
        #expect(!contentView.contains("struct CreateBucketSheetItem"), """
            ContentView.swift declares the item again -- a second declaration is a second \
            initialiser the access level on the first says nothing about.
            """)
        // The controls, not the strings checked above: the state that holds the
        // item is still declared, in ContentView.swift, with the type's name.
        #expect(contentView.contains("var createBucketSheetItem: CreateBucketSheetItem?"))
    }

    /// The sidebar holds no connection of its own: it names no file system,
    /// no connector and no session, only the effect value and the input.
    @Test func theSidebarOwnsNoConnection() throws {
        // Comment-free: a doc comment explaining why the sidebar holds no
        // connection has to be free to name the types it does not hold, and
        // this file carries hundreds of `///` lines. Not `code(of:)`, which
        // also blanks string literals this scan has no reason to ignore.
        let sidebar = try SourceCorpus.commentFree(of: Self.sidebarFile)
        for forbidden in ["BrowserSession", "RemoteFileSystem", "ConnectionViewModel", "S3FileSystem"] {
            #expect(!sidebar.contains(forbidden), "SessionSidebar.swift names \(forbidden)")
        }
        // The control: the file does name the effect type it was handed.
        #expect(sidebar.contains("SessionRowCreateBucketEffect"))
    }

    /// The runner is mounted once per tab, beside the snippet one, so a request
    /// armed on a tab that is not in front is still delivered when it comes
    /// forward.
    @Test func theRunnerIsMountedPerTab() throws {
        // **What this pins, and what it cannot.** "One runner per tab" is a
        // view-structure property: whether the mount is reachable, and whether
        // it sits in a `ForEach` over every tab, is something nothing in this
        // project can execute. So the scan reads the STRUCTURE and not the
        // vocabulary. The first form counted one spelling in one file and
        // pinned the line above and the line below the mount; a second mount
        // under another spelling, a mount in another file, and the whole
        // `ForEach` wrapped in an `if` that is never true all passed it.
        //
        // Four checks, with different jobs:
        // 1. Over the whole App target, the runner's NAME appears exactly twice,
        //    both in `ContentView+Detail.swift`: its declaration and the one
        //    mount. Those two mentions ARE the argument that the count is
        //    enough here: they are the declaration and the mount, so there is no
        //    third one for a state, a property, a parameter or a return type of
        //    this type to be -- and a contextual `.init(...)` needs a context
        //    that is one. So this does not buy a spelling at a time the way a
        //    count of `Runner(` and `Runner.init(` did (a call through the
        //    metatype, and an initialiser declared in an extension in another
        //    file, both passed that). This passage used to open "Every way of
        //    building a value names its type", which is false in general: a
        //    contextually typed `createBucketSheetItem = .init(...)` names the
        //    STATE and not the type. What catches that shape is a count of the
        //    STATE's name, which is why
        //    `theCreateBucketSheetIsConstructedInExactlyOnePlace` keeps one
        //    beside its type count (plants Q14 and Q19 of the re-reviews are red
        //    through the state's name alone). The day a state of the runner's
        //    type exists, this check needs that second count too; today there is
        //    none, which is why the general rule being false costs nothing here.
        //    The figure: `/usr/bin/grep -r -n -F PendingCreateBucketRunner
        //    Sources/MacSCPAppKit` prints 3 lines, one a comment, so 2 in code;
        //    this test reads `SourceCorpus.commentFree`, which blanks comments
        //    structurally. The name is read off the type, not written here.
        // 2. The region of that one mount -- from its `.background {` to the
        //    closing brace, and the modifier that follows it -- is EQUAL to the
        //    expected lines. An equality over a small region cannot go quiet:
        //    it fails the moment anything inside it moves, including an
        //    enclosing `if`. Its price is brittleness to a reformat, and the
        //    region is seven lines, so that is the right trade; the line that
        //    follows is in it so a modifier added after the block (a
        //    `.hidden()`, say) is seen too.
        // 3. The runner's initialiser is `fileprivate`, which makes the literal
        //    call and the call through the metatype fail to compile in another
        //    file. That is all it does: an initialiser declared in an extension
        //    elsewhere compiles (plant Q9 of the re-review), which is what 1 is
        //    for; and it does not confine this file, which 2 does.
        // 4. The runner does its one job: its body calls `onDeliver(tab)` from an
        //    `.onChange(of: signal, initial: true)`. A mount that is present
        //    and inert (the body never calls it, the `onChange` watches a
        //    constant, the body is an `EmptyView`) satisfies 1 to 3. The call
        //    is read from that `.onChange`'s OWN block: until fix round 4 this
        //    asked only that the struct's text held both strings somewhere,
        //    which the call parked in a method of the runner nobody calls
        //    satisfied (plant R3 of the third re-review).
        //
        // **Not closed, on purpose.** A region that compiles out -- `#if false`
        // around the whole layer, with every byte of the region unchanged (plant
        // Q1b) -- passes all four, and no source scan closes that family: what
        // separates a live mount from a compiled-out one is execution, and
        // nothing in this project executes a view. The check that stands against
        // it is a person opening the app and watching the sheet appear
        // (sight-check item 8). Another anchor here would be one more spelling.
        let appKit = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let runnerName = String(describing: PendingCreateBucketRunner.self)
        var named: [String] = []
        for url in try SourceCorpus.files(under: appKit) where url.pathExtension == "swift" {
            let code = try SourceCorpus.commentFree(of: url)
            let count = code.components(separatedBy: runnerName).count - 1
            named += Array(repeating: url.lastPathComponent, count: count)
        }
        #expect(named == ["ContentView+Detail.swift", "ContentView+Detail.swift"], """
            the create-bucket runner `\(runnerName)` is named at \(named), expected exactly \
            twice, both in ContentView+Detail.swift (its declaration and the one mount) -- a \
            second use is a second mount, or a construction the spellings of a call do not \
            show, and a request armed by the sidebar entry may then never open the sheet.
            """)

        let detail = try SourceCorpus.commentFree(of: Self.detailFile)
        let lines = detail.components(separatedBy: "\n")
        let region = try Self.mountRegion(of: "PendingCreateBucketRunner(", in: lines)
        #expect(region == [
            ".background {",
            "ForEach(tabsModel.tabs) { tab in",
            "PendingCreateBucketRunner(",
            "tab: tab, activeTabID: tabsModel.activeTab.id,",
            "onDeliver: { deliverPendingCreateBucket(on: $0) })",
            "}",
            "}",
            ".backgroundPreferenceValue(SidebarMeasuredWidthKey.self) { measuredSidebarWidth in",
        ], """
            the region around the create-bucket runner's mount is not the expected one: \(region). \
            It must be a `.background` holding a `ForEach` over every tab that hands each tab to \
            its own runner, with nothing around the `ForEach` and nothing added after the block.
            """)
        // The controls, none of them the region checked above: the same
        // extraction on the snippet runner's mount, which is built the same
        // way, yields the same shape (so the extraction finds a mount and its
        // block, and does not return something that happens to be empty) and
        // is followed by the next modifier, which here is the create-bucket one.
        let snippetRegion = try Self.mountRegion(of: "PendingSnippetRunner(", in: lines)
        #expect(snippetRegion.count == 8)
        #expect(snippetRegion.first == ".background {")
        #expect(snippetRegion[1] == "ForEach(tabsModel.tabs) { tab in")
        #expect(snippetRegion.last == ".background {")
        #expect(detail.contains("deliverPendingCreateBucket(on: $0)"))
        // What wakes the runner is what the delivery reads. The one fact the
        // snippet runner does not carry is the pane's load state, and without
        // it a request waiting for the list would never be woken by the list.
        let runner = try Self.functionBody(
            named: "struct PendingCreateBucketRunner: View {", in: Self.detailFile)
        for fact in [
            "tab.pendingCreateBucket", "tab.session?.remote.state", "tab.session?.id",
            "tab.isReconnecting", "tab.activeStoredSessionID", "activeTabID: activeTabID",
            "tab.pendingCreateBucket?.bucketListNavigation", "tab.session?.remote.currentPath",
        ] {
            #expect(runner.contains(fact), "the runner's signal no longer carries `\(fact)`")
        }
        #expect(runner.contains("fileprivate init("), "the runner's initialiser is no longer `fileprivate`")
        // Check 4: the runner does its job, and does it FROM the `onChange`.
        // Present-but-inert is the shape these pin, and `initial: true` is what
        // delivers a request armed before this view was mounted (no later
        // change would, when the list is loaded). The call is read from the
        // `.onChange`'s own block: asking that the struct's text contains it
        // somewhere passed with the call sitting in a method of the runner
        // nobody calls and the `onChange` body `_ = tab` (plant R3 of the
        // third re-review). The `contains` below is the positive control that
        // the anchor the block is found by is present as spelled, and the one
        // that fails with a message rather than a thrown `ScanFailure`; it
        // stays on the literal-keeping view, which is where an anchor somebody
        // spells inside a literal would have to be found.
        //
        // The CALL is read from `delivery.code`, the view where string literals
        // are blanked, and not from the literal-keeping one `contains(_:)`
        // reads: an `onChange` body whose whole content is
        // `_ = "onDeliver(tab)"` delivers nothing and satisfied the
        // literal-keeping read (plant T1 of fix round 5, GREEN before this and
        // RED after; T1c, the same literal beside the real call, is GREEN). The
        // whole-struct `contains` this replaced had the same hole, so round 4
        // did not open it -- round 4 is where the bounded block first made the
        // right view available to close it.
        #expect(
            runner.contains(".onChange(of: signal, initial: true)"),
            "the runner no longer watches its signal with `initial: true`")
        let delivery = try Self.functionBody(named: ".onChange(of: signal, initial: true)", in: runner)
        #expect(
            delivery.code.contains("onDeliver(tab)"),
            "the runner's `.onChange(of: signal, initial: true)` no longer calls `onDeliver(tab)`")
    }

    /// The request being armed wakes the runner. "Go to Existing Tab" onto a
    /// tab that is already connected, already in front and already showing its
    /// loaded list gives the runner no connect, no tab switch and no load to
    /// react to: the `armed` fact of its signal is the only thing that changes,
    /// so a signal without it delivers nothing for exactly that case and every
    /// behaviour test above stays green (they call the delivery directly).
    ///
    /// Read from source, because `.onChange` is not reachable from a test in
    /// this project, and from the comment-free view: the field's own doc
    /// comment names the fact and must not be able to satisfy the scan. The
    /// positive controls are the neighbouring fields in the same struct and the
    /// neighbouring arguments in the same construction -- a scan that cannot
    /// find them has found the wrong block, and its silence about `armed` would
    /// mean nothing. The existing facts check above names the request's
    /// property too, but only as a substring of the whole struct, so it would
    /// also pass on a signal that mentions the property and does not declare a
    /// field for it.
    @Test func theRunnersSignalCarriesTheRequestBeingArmed() throws {
        let runner = try Self.functionBody(
            named: "struct PendingCreateBucketRunner: View {", in: Self.detailFile)
        let declaration = try Self.functionBody(named: "private struct Signal: Equatable {", in: runner)
        let construction = try Self.functionBody(named: "private var signal: Signal {", in: runner)
        // The controls.
        #expect(declaration.code.contains("let remoteState:"), "the extraction did not find the signal's declaration")
        #expect(declaration.code.contains("let activeTabID: UUID"))
        #expect(construction.code.contains("remoteState: tab.session?.remote.state"), """
            the extraction did not find the signal's construction
            """)
        // The fact itself: declared, and read from the tab's request.
        #expect(declaration.code.contains("let armed: Bool"), "the runner's signal no longer declares `armed`")
        #expect(
            construction.code.contains("armed: tab.pendingCreateBucket != nil"),
            "the runner's signal no longer reads `armed` from the tab's pending request")
    }

    /// "Open Anyway" starts what was asked for. The answer lives in a view
    /// modifier no test can press, so the pass-through is read from source:
    /// the dialog hands `request.createsBucket` on, and builds no sheet.
    @Test func openAnywayPassesTheRequestOnAndBuildsNoSheet() throws {
        // The literal-keeping view, which is the one the anchor is spelled in:
        // `code(of:)` blanks `"tabs.alreadyOpen.openAnyway"` and would not
        // hold this anchor at all (`SourceSpans.Views`).
        let answer = try Self.functionBody(
            named: "Button(L10n.string(\"tabs.alreadyOpen.openAnyway\"", in: Self.sheetsFile)
        #expect(answer.contains("createsBucket: request.createsBucket"), """
            the "Open Anyway" answer no longer hands the create-bucket request on -- it \
            would start a plain connect and the sheet would never open.
            """)
        #expect(!answer.contains("CreateBucketSheetItem("))
        // The control: the scan found the answer it was meant to read.
        #expect(answer.contains("startWithoutAsking("))
    }

    /// The row offers the entry only where the route says so. The `if` and the
    /// question it asks are both read: a row that showed the entry on every
    /// connection would dial an account that has nothing to create a bucket in.
    @Test func theRowOffersTheEntryOnlyWhereTheRouteSaysSo() throws {
        let sidebar = try SourceCorpus.text(of: Self.sidebarFile)
        let lines = sidebar.components(separatedBy: "\n")
        let carrier = try #require(lines.firstIndex { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains(".newBucketMenuEntry")
        }, "no line forwards `.newBucketMenuEntry`")
        #expect(
            lines[carrier - 1].trimmingCharacters(in: .whitespaces) == "if newBucketOffered {",
            "the entry is not directly inside `if newBucketOffered {`")
        let question = try Self.functionBody(
            named: "private var newBucketOffered: Bool {", in: Self.sidebarFile)
        #expect(question.contains("ConnectionActionRoute.createBucket.isOffered(onStored: session)"))
    }

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let menuActionsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
    private static let sheetsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Sheets.swift")
    private static let sidebarFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private struct MountNotFound: Error { let runner: String }

    /// The trimmed lines of the block that mounts `runner`: from the nearest
    /// `.background {` above its mount to that block's closing brace, and then
    /// the next line that holds code. Throws, rather than returning an empty
    /// region, when there is no such mount or no such block.
    private static func mountRegion(of runner: String, in lines: [String]) throws -> [String] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mount = trimmed.firstIndex(where: { $0.contains(runner) }),
            let start = trimmed[..<mount].lastIndex(of: ".background {")
        else { throw MountNotFound(runner: runner) }
        var depth = 0
        var end = start
        for index in start..<trimmed.count {
            for character in trimmed[index] {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
            }
            if depth <= 0 { end = index; break }
        }
        guard end > mount else { throw MountNotFound(runner: runner) }
        var region = Array(trimmed[start...end])
        if let next = trimmed[(end + 1)...].first(where: { !$0.isEmpty }) { region.append(next) }
        return region
    }

    private struct ScanFailure: Error { let anchor: String }
    private struct ViewsNotInLockstep: Error { let file: String }

    /// The file's two blanked views as one `SourceSpans.Views`: comments
    /// blanked and literals kept for what is matched on, literals blanked too
    /// for the braces that bound a span.
    private static func views(of file: URL) throws -> SourceSpans.Views {
        guard
            let views = SourceSpans.Views(
                content: try SourceCorpus.commentFree(of: file),
                code: try SourceCorpus.code(of: file))
        else { throw ViewsNotInLockstep(file: file.lastPathComponent) }
        return views
    }

    /// The `{ ... }` block the first occurrence of `marker` opens: the marker
    /// and the text handed back come from the literal-keeping view, every
    /// brace that bounds the block is counted in the blanked one
    /// (`SourceSpans.Views.block(openedBy:)`). Throws, never an unbounded
    /// span, when the marker is not there or the braces do not balance.
    ///
    /// **It counted braces over the literal-keeping view until fix round 4**,
    /// so a `{` inside a string literal raised the depth and the block ran
    /// past its own closing brace to the end of the file. Both guards below
    /// were GREEN on a violation parked there: plant R1 (check 4 of
    /// `theRunnerIsMountedPerTab`, a `private let bracePad = "{"` in the runner
    /// and the `onDeliver(tab)` call parked after the struct) and plant R2b
    /// (`theSheetItemIsDeclaredOnceBesideItsBuilderWithAFileprivateInitialiser`,
    /// the same brace in the item and a `fileprivate init` decoy in the same
    /// extension). It is the defect `SourceSpans` fixed in two neighbouring
    /// suites one round earlier, through a different door.
    private static func functionBody(named marker: String, in file: URL) throws -> SourceSpans.Views {
        try functionBody(named: marker, in: try views(of: file))
    }

    /// The same read, inside a block already found — the `.onChange`'s own
    /// body inside the runner's. Both views are sliced together, so a nested
    /// read is bounded exactly as the outer one is.
    private static func functionBody(
        named marker: String, in views: SourceSpans.Views
    ) throws -> SourceSpans.Views {
        guard let block = views.block(openedBy: marker) else { throw ScanFailure(anchor: marker) }
        return block
    }
}

// MARK: - Doubles

/// Counts dials from a connector closure, which is `@Sendable`.
private final class DialCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var count: Int { state.withLock { $0 } }
}

/// A connected bucket-list file system: the root lists buckets, the bucket
/// settings capability is present (the route's availability reads both), and
/// `disconnect()` is counted so a test can tell the connection was closed, and
/// by whom, without a clock.
private final class BucketListFileSystem: RemoteFileSystem, S3BucketSettings, Sendable {
    private let settings = FakeBucketSettings()
    private let closed = Mutex(0)
    private let holdsDisconnect: Bool
    private let listFails: Bool
    private let holdsRootStat: Bool
    private let rootStats = Mutex(0)
    private let rootListRefused = Mutex(false)
    /// Raised when `disconnect()` is entered; only meaningful when it holds.
    let disconnectEntered = AsyncSignal()
    /// Releases a held `disconnect()`.
    let disconnectRelease = AsyncSignal()
    /// Raised when `stat("/")` is entered; only meaningful when it holds.
    let rootStatEntered = AsyncSignal()
    /// Releases a held `stat("/")`.
    let rootStatRelease = AsyncSignal()

    /// `holdsDisconnect` parks `disconnect()` until the test releases it, so a
    /// test can stand between the start of a teardown and its end without a
    /// clock.
    ///
    /// `listFails` makes the bucket list itself fail to load.
    ///
    /// `holdsRootStat` parks `stat("/")` -- the first thing
    /// `RemoteBrowserViewModel.navigate(to:)` does, before it moves the pane
    /// -- so a test can stand inside a bucket while a navigation to the list
    /// is in flight.
    init(holdsDisconnect: Bool = false, listFails: Bool = false, holdsRootStat: Bool = false) {
        self.holdsDisconnect = holdsDisconnect
        self.listFails = listFails
        self.holdsRootStat = holdsRootStat
    }

    var disconnects: Int { closed.withLock { $0 } }

    /// How many times `stat("/")` was asked: one per navigation to the
    /// bucket list, since `navigate(to:)` stats its target once and nothing
    /// else in these tests stats the root.
    var rootStatCount: Int { rootStats.withLock { $0 } }

    /// From now on the bucket list (`/`) fails to load, while a bucket's own
    /// listing still loads: the list loaded once, and a later navigation back
    /// to it fails.
    func refuseTheRootListFromNowOn() { rootListRefused.withLock { $0 = true } }

    nonisolated var rootIsContainerList: Bool { true }

    func list(path: String) async throws -> [RemoteFileItem] {
        if listFails { throw RemoteFSError.protocolError(reason: "list refused") }
        guard RemotePath.normalizedAbsolute(path) == "/" else { return [] }
        if rootListRefused.withLock({ $0 }) {
            throw RemoteFSError.protocolError(reason: "bucket list refused")
        }
        return [
            RemoteFileItem(name: "first-bucket", path: "/first-bucket", kind: .directory, isBucket: true),
            RemoteFileItem(name: "second-bucket", path: "/second-bucket", kind: .directory, isBucket: true),
        ]
    }

    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {
        closed.withLock { $0 += 1 }
        guard holdsDisconnect else { return }
        disconnectEntered.signal()
        _ = await disconnectRelease.wait()
    }

    /// Only the root is ever stated here, by the delivery's navigation to the
    /// bucket list; it answers the way `S3FileSystem` does, with a directory
    /// and no request.
    func stat(path: String) async throws -> RemoteFileItem {
        guard RemotePath.normalizedAbsolute(path) == "/" else { fatalError("not exercised by this test") }
        rootStats.withLock { $0 += 1 }
        if holdsRootStat {
            rootStatEntered.signal()
            _ = await rootStatRelease.wait()
        }
        return RemoteFileItem(name: "/", path: "/", kind: .directory)
    }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        fatalError("not exercised by this test")
    }
    func delete(path: String) async throws { fatalError("not exercised by this test") }
    func createDirectory(at path: String) async throws { fatalError("not exercised by this test") }
    func rename(from: String, to: String) async throws { fatalError("not exercised by this test") }
    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }
    func deleteTree(at path: String) async throws { fatalError("not exercised by this test") }

    // The bucket settings capability: present, and answered by the shared fake.
    func createBucket(_ bucket: String, protection: BucketProtection) async throws {
        try await settings.createBucket(bucket, protection: protection)
    }
    func versioning(ofBucket bucket: String) async throws -> BucketVersioning {
        try await settings.versioning(ofBucket: bucket)
    }
    func setVersioning(_ state: BucketVersioning, ofBucket bucket: String) async throws {
        try await settings.setVersioning(state, ofBucket: bucket)
    }
    func cors(ofBucket bucket: String) async throws -> BucketCORS? {
        try await settings.cors(ofBucket: bucket)
    }
    func setCORS(_ rules: [CORSRule], ofBucket bucket: String) async throws {
        try await settings.setCORS(rules, ofBucket: bucket)
    }
    func hasObjectLock(ofBucket bucket: String) async throws -> Bool {
        try await settings.hasObjectLock(ofBucket: bucket)
    }
    func objectLockDefault(ofBucket bucket: String) async throws -> (days: Int, mode: RetentionMode)? {
        try await settings.objectLockDefault(ofBucket: bucket)
    }
    func setObjectLockDefault(days: Int, mode: RetentionMode, ofBucket bucket: String) async throws {
        try await settings.setObjectLockDefault(days: days, mode: mode, ofBucket: bucket)
    }
    func retention(ofKey key: String, inBucket bucket: String, versionId: String?) async throws
        -> ObjectRetention?
    {
        try await settings.retention(ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func setRetention(
        _ retention: ObjectRetention, ofKey key: String, inBucket bucket: String, versionId: String?
    ) async throws {
        try await settings.setRetention(retention, ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func legalHold(ofKey key: String, inBucket bucket: String, versionId: String?) async throws -> Bool {
        try await settings.legalHold(ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func setLegalHold(_ on: Bool, ofKey key: String, inBucket bucket: String, versionId: String?) async throws {
        try await settings.setLegalHold(on, ofKey: key, inBucket: bucket, versionId: versionId)
    }
}

/// In-memory `SecretStore`: the point of passing one at all is that no test in
/// this file can reach the real Keychain.
private final class InMemoryBucketSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
