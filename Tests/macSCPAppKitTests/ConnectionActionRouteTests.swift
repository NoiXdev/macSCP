import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Which of a backend's connection actions the window can carry out, row by
/// row, and the wiring that makes the toolbar menu ask.
///
/// The menu used to be enabled or disabled as a whole (Task 7: one optional
/// handler, `nil`, every row disabled). It is per row now, because the rows
/// are wired one task at a time and because a row's availability can depend on
/// the connection (Task 11's bucket-list gate), so the question is asked of a
/// row, with the connection's context, by `ConnectionActionRoute`.
@Suite("Connection action routing")
struct ConnectionActionRouteTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A connection that has the capability and sits in one bucket.
    private static func inOneBucket(
        _ bucket: String = "macscp-seed", settings: (any S3BucketSettings)? = FakeBucketSettings()
    ) -> ConnectionActionContext {
        ConnectionActionContext(
            settings: settings, rootIsContainerList: false, remotePath: "/some/key",
            configuredBucket: bucket)
    }

    /// Every connection action any backend contributes.
    private static var everyAction: [ConnectionActionContribution] {
        ConnectionKind.allCases.flatMap {
            BackendDescriptor.descriptor(for: $0).connectionActions
        }
    }

    // MARK: - A wired row is available, an unwired one is not

    /// The positive beside the negative: "disabled" is the state a broken
    /// dispatcher also produces, so a row that SHOULD be live is asserted live
    /// before any row is asserted dead.
    @Test func aWiredIdIsAvailableAndAnUnwiredOneIsNot() {
        let context = Self.inOneBucket()
        let wired = Self.everyAction.filter { ConnectionActionRoute(action: $0) != nil }
        let unwired = Self.everyAction.filter { ConnectionActionRoute(action: $0) == nil }
        #expect(!wired.isEmpty)
        for action in wired {
            #expect(ConnectionActionRoute.isAvailable(action, in: context), "\(action.id)")
        }
        for action in unwired {
            #expect(!ConnectionActionRoute.isAvailable(action, in: context), "\(action.id)")
        }
        #expect(wired.count + unwired.count == Self.everyAction.count)
    }

    /// The negative half, with an id that cannot be wired by anyone: it is not
    /// in any descriptor, so no later task makes this vacuous.
    @Test func anIdWithNoArmIsDisabledWhateverTheConnectionIs() {
        let stray = ConnectionActionContribution(
            id: "test.noSuchAction", titleKey: "k", titleDefault: "d", systemImage: "circle")
        #expect(ConnectionActionRoute(action: stray) == nil)
        #expect(!ConnectionActionRoute.isAvailable(stray, in: Self.inOneBucket()))
    }

    /// Every route belongs to a real contribution: renaming an id in a
    /// descriptor reds this instead of leaving a route that no row can reach.
    @Test func everyRouteIsAnIdSomeBackendContributes() {
        let ids = Set(Self.everyAction.map(\.id))
        #expect(!ConnectionActionRoute.allCases.isEmpty)
        for route in ConnectionActionRoute.allCases {
            #expect(ids.contains(route.rawValue), "\(route.rawValue)")
        }
    }

    // MARK: - What a row needs from the connection

    @Test func versioningNeedsTheCapability() {
        let withIt = Self.inOneBucket()
        let without = Self.inOneBucket(settings: nil)
        #expect(ConnectionActionRoute.versioning.isAvailable(in: withIt))
        #expect(!ConnectionActionRoute.versioning.isAvailable(in: without))
    }

    /// Both rows that open a sheet need the capability AND a bucket, and each
    /// is asked of its own case: a route whose condition were copied from its
    /// neighbour would pass the first half and fail the second.
    @Test func corsNeedsTheCapabilityAndABucket() {
        let withIt = Self.inOneBucket()
        let without = Self.inOneBucket(settings: nil)
        let blank = Self.inOneBucket("   ")
        #expect(ConnectionActionRoute.cors.isAvailable(in: withIt))
        #expect(!ConnectionActionRoute.cors.isAvailable(in: without))
        #expect(!ConnectionActionRoute.cors.isAvailable(in: blank))
        let atTheList = ConnectionActionContext(
            settings: FakeBucketSettings(), rootIsContainerList: true, remotePath: "/",
            configuredBucket: "ignored")
        #expect(!ConnectionActionRoute.cors.isAvailable(in: atTheList))
        let inABucket = ConnectionActionContext(
            settings: FakeBucketSettings(), rootIsContainerList: true,
            remotePath: "/macscp-seed/x", configuredBucket: "ignored")
        #expect(ConnectionActionRoute.cors.isAvailable(in: inABucket))
    }

    /// The third sheet row, asked of its own case like the two above it.
    @Test func objectLockNeedsTheCapabilityAndABucket() {
        let withIt = Self.inOneBucket()
        let without = Self.inOneBucket(settings: nil)
        let blank = Self.inOneBucket("   ")
        #expect(ConnectionActionRoute.objectLock.isAvailable(in: withIt))
        #expect(!ConnectionActionRoute.objectLock.isAvailable(in: without))
        #expect(!ConnectionActionRoute.objectLock.isAvailable(in: blank))
        let atTheList = ConnectionActionContext(
            settings: FakeBucketSettings(), rootIsContainerList: true, remotePath: "/",
            configuredBucket: "ignored")
        #expect(!ConnectionActionRoute.objectLock.isAvailable(in: atTheList))
        let inABucket = ConnectionActionContext(
            settings: FakeBucketSettings(), rootIsContainerList: true,
            remotePath: "/macscp-seed/x", configuredBucket: "ignored")
        #expect(ConnectionActionRoute.objectLock.isAvailable(in: inABucket))
    }

    @Test func inOneBucketTheBucketIsTheConfiguredOneNotAPathComponent() {
        let context = Self.inOneBucket("  macscp-seed \n")
        #expect(context.bucket == "macscp-seed")
        let blank = Self.inOneBucket("   ")
        #expect(blank.bucket == nil)
        #expect(!ConnectionActionRoute.versioning.isAvailable(in: blank))
    }

    @Test func atTheBucketListTheBucketIsTheFirstComponentOfThePath() {
        func context(_ path: String) -> ConnectionActionContext {
            ConnectionActionContext(
                settings: FakeBucketSettings(), rootIsContainerList: true, remotePath: path,
                configuredBucket: "ignored")
        }
        #expect(context("/macscp-seed/photos/2026/").bucket == "macscp-seed")
        #expect(context("/macscp-seed").bucket == "macscp-seed")
        #expect(context("//macscp-second//x").bucket == "macscp-second")
        // At the list itself there is no bucket to ask about, so the row is
        // not available, whatever bucket the form happens to hold.
        #expect(context("/").bucket == nil)
        #expect(!ConnectionActionRoute.versioning.isAvailable(in: context("/")))
        #expect(ConnectionActionRoute.versioning.isAvailable(in: context("/macscp-seed/x")))
    }

    // MARK: - Wiring (source scans)

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
    }

    /// The call that constructs the menu, up to the first icon of the group.
    private static func placement() throws -> String {
        let source = try code("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        let start = try #require(source.range(of: "ConnectionActionsMenu("))
        let end = try #require(source.range(of: "uploadButton(", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// The body of a `func` in the dispatcher file: from its declaration to the
    /// next function declaration at the same indent, or the end of the file.
    private static func body(ofFunction name: String, in source: String) throws -> String {
        let declaration = try #require(source.range(of: "func \(name)("), "func \(name) not found")
        let rest = source[declaration.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The name of the function a labelled closure argument calls first.
    private static func calledBy(argument label: String, in placement: String) throws -> String {
        let pattern = try Regex("\(label):\\s*\\{[^}]*?(\\w+)\\(")
        let match = try #require(placement.firstMatch(of: pattern), "no `\(label):` closure that calls something")
        return try #require(match.output[1].substring.map(String.init))
    }

    /// The window hands the menu a predicate and an action, and each is a call
    /// into the dispatcher file rather than a closure that decides for itself:
    /// an `isAvailable: { _ in true }` would leave every row live and every
    /// guard above green. The names are READ from the call site and looked up,
    /// not spelled here.
    @Test func theWindowAsksTheRouteForAvailabilityAndForTheAction() throws {
        let placement = try Self.placement()
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")

        let availability = try Self.calledBy(argument: "isAvailable", in: placement)
        let availabilityBody = try Self.body(ofFunction: availability, in: dispatcher)
        #expect(availabilityBody.contains("ConnectionActionRoute"))

        let selection = try Self.calledBy(argument: "onSelect", in: placement)
        let selectionBody = try Self.body(ofFunction: selection, in: dispatcher)
        #expect(selectionBody.contains("ConnectionActionRoute"))
        #expect(availability != selection)
    }

    /// The dispatch is a `switch` over the route with no `default`, so a route
    /// case added without an arm does not compile, and every case that exists
    /// has an arm of its own. The case names are read off the enum.
    @Test func everyRouteHasItsOwnArmAndTheSwitchHasNoDefault() throws {
        let placement = try Self.placement()
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
        let selection = try Self.calledBy(argument: "onSelect", in: placement)
        let body = try Self.body(ofFunction: selection, in: dispatcher)
        #expect(body.contains("switch "))
        #expect(!body.contains("default:"))
        #expect(!ConnectionActionRoute.allCases.isEmpty)
        for route in ConnectionActionRoute.allCases {
            let arm = "case .\(String(describing: route))"
            #expect(body.contains(arm), "\(arm)")
        }
    }

    /// An arm that sets window state nobody presents is an enabled row that
    /// does nothing, the failure the whole menu is built to rule out, and no
    /// other check here would see it. So the state each arm assigns (read off
    /// the arms, after the `switch`) must be the item of a `.sheet(item:)` in
    /// the window's sheet file, and the sheet that presentation builds is the
    /// one the arm's item is for.
    ///
    /// **Changed 2026-10-20 (S3 bucket settings, Task 9).** This test used to
    /// end with a single expected sheet, `BucketVersioningSheet`, spelled
    /// through its type: verbatim `let built = String(describing: BucketVersioningSheet.self) + "("`
    /// and `#expect(rest.contains(built), "\(state) is presented, but not as \(built)")`.
    /// With a second arm that held only for the first, and a check made to hold
    /// for both by loosening it would have proved neither. The sheet is now
    /// DERIVED per arm: the item type the arm constructs is `<Sheet>Item`
    /// (`BucketVersioningSheetItem` for `BucketVersioningSheet`), and the
    /// presentation is looked for only up to the next `.sheet(`, so one sheet's
    /// body cannot satisfy another's check. The positive half is the count: one
    /// distinct state per route, so an arm that assigns nothing is red.
    @Test func theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor() throws {
        let placement = try Self.placement()
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
        let sheets = try Self.code("Sources/MacSCPAppKit/ContentView+Sheets.swift")
        let selection = try Self.calledBy(argument: "onSelect", in: placement)
        let body = try Self.body(ofFunction: selection, in: dispatcher)
        let arms = try #require(body.range(of: "switch "))
        let assigned = body[arms.upperBound...].matches(of: #/(\w+)\s*=\s*(\w+)\(/#)
            .map { (state: String($0.output.1), item: String($0.output.2)) }
        #expect(assigned.count == ConnectionActionRoute.allCases.count)
        #expect(Set(assigned.map(\.state)).count == assigned.count)
        for (state, item) in assigned {
            #expect(item.hasSuffix("Item"), "\(item)")
            let sheetName = String(item.dropLast("Item".count))
            let presentation = try #require(
                sheets.range(of: ".sheet(item: $\(state))"), "no .sheet(item: $\(state))")
            let rest = sheets[presentation.upperBound...]
            let closure = rest[..<(rest.range(of: ".sheet(")?.lowerBound ?? rest.endIndex)]
            #expect(closure.contains(sheetName + "("), "\(state) is presented, but not as \(sheetName)")
        }
        // The two sheets of this branch, named through their types, are the
        // ones the arms construct items for.
        let named = Set(assigned.map(\.item))
        #expect(named.contains(String(describing: BucketVersioningSheet.self) + "Item"))
        #expect(named.contains(String(describing: BucketCORSSheet.self) + "Item"))
        #expect(named.contains(String(describing: BucketObjectLockSheet.self) + "Item"))
    }

    /// The availability the menu draws and the action the dispatcher takes are
    /// decided by the SAME question: the dispatcher asks the route again before
    /// it opens anything, so a row that was live when drawn and is not live now
    /// (a navigation between the draw and the click) does nothing.
    @Test func theDispatcherRechecksAvailabilityBeforeActing() throws {
        let placement = try Self.placement()
        let dispatcher = try Self.code("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
        let selection = try Self.calledBy(argument: "onSelect", in: placement)
        let body = try Self.body(ofFunction: selection, in: dispatcher)
        let check = try #require(body.range(of: "isAvailable"))
        let dispatch = try #require(body.range(of: "switch "))
        #expect(check.lowerBound < dispatch.lowerBound)
    }
}
