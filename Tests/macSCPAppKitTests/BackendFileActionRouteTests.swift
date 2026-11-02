import AppKit
import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Which backend file actions the window carries out, row by row, and the
/// wiring from the descriptor's list to the sheet.
///
/// The failure these exist for: `s3.versions` was declared, drawn, enabled and
/// matched by nothing, because the handler was an `if`-chain with no `else`.
/// The route enum is now the table (`ConnectionActionRoute`'s shape), and a
/// declared action it has no case for is drawn disabled.
@Suite("Backend file action routing")
struct BackendFileActionRouteTests {
    /// Every file action any backend contributes.
    private static var everyAction: [FileActionContribution] {
        ConnectionKind.allCases.flatMap { BackendDescriptor.descriptor(for: $0).fileActions }
    }

    private static func unrouted() -> FileActionContribution {
        FileActionContribution(
            id: "s3.noSuchAction", titleKey: "browser.action.noSuchAction", titleDefault: "Nothing")
    }

    // MARK: - The table and the descriptors agree, both ways

    /// A declared contribution that has no case would be offered by the menu
    /// and matched by nothing. Both directions, and the sizes beside them, so
    /// two empty lists cannot agree.
    @Test func theRoutesAreExactlyTheIdsTheDescriptorsDeclare() {
        let declared = Set(Self.everyAction.map(\.id))
        let routed = Set(BackendFileActionRoute.allCases.map(\.rawValue))
        #expect(declared.count >= 4, "the descriptors declare \(declared.count) file actions")
        #expect(routed.count == BackendFileActionRoute.allCases.count)
        #expect(declared.subtracting(routed).isEmpty, "declared and not routed: \(declared.subtracting(routed).sorted())")
        #expect(routed.subtracting(declared).isEmpty, "routed and not declared: \(routed.subtracting(declared).sorted())")
        #expect(declared.contains(VersionsRowAvailability.actionID))
    }

    @Test func theObjectLockActionsShareTheirIdsWithTheRoutes() {
        #expect(!ObjectLockFileAction.allCases.isEmpty)
        for action in ObjectLockFileAction.allCases {
            #expect(BackendFileActionRoute(rawValue: action.rawValue) != nil, "\(action.rawValue)")
        }
    }

    // MARK: - An unrouted id is not offered

    @Test func aDeclaredActionTheWindowDoesNotRouteIsNotOfferedAsAvailable() {
        let states: [BucketVersioning?] = [nil] + BucketVersioning.allCases.map { Optional($0) }
        #expect(states.count == 4)
        for state in states {
            let verdict = BackendFileActionRoute.verdict(for: Self.unrouted(), bucketVersioning: state)
            #expect(verdict.isAvailable == false, "\(String(describing: state))")
            #expect(verdict == .unrouted)
        }
        // The positive beside it: a routed id is offered in the same states.
        let versions = BackendDescriptor.descriptor(for: .s3).fileActions.first {
            $0.id == VersionsRowAvailability.actionID
        }
        if let versions {
            #expect(BackendFileActionRoute.verdict(for: versions, bucketVersioning: .enabled).isAvailable)
        } else {
            Issue.record("the S3 descriptor does not declare \(VersionsRowAvailability.actionID)")
        }
    }

    @Test func everyRoutedActionIsOfferedExceptTheHistoryOfABucketNeverVersioned() {
        let declared = BackendDescriptor.descriptor(for: .s3).fileActions
        #expect(declared.count == BackendFileActionRoute.allCases.count)
        for action in declared {
            for state in [nil] + BucketVersioning.allCases.map({ Optional($0) }) {
                let verdict = BackendFileActionRoute.verdict(for: action, bucketVersioning: state)
                let shouldBeDeclined =
                    action.id == VersionsRowAvailability.actionID && state == .never
                #expect(
                    verdict.isAvailable == !shouldBeDeclined,
                    "\(action.id) with \(String(describing: state))")
                #expect((verdict.reason != nil) == shouldBeDeclined, "\(action.id)")
            }
        }
    }

    @Test func theHistoryRowCarriesTheNeverVersionedSentenceAsItsReason() {
        let verdict = BackendFileActionRoute.versions.verdict(bucketVersioning: .never)
        #expect(verdict.reason == VersionsRowAvailability.neverVersionedReason)
        #expect(verdict.reason?.key == VersionsRowAvailability.neverVersionedReasonKey)
    }

    // MARK: - A bucket not read yet offers the row

    @MainActor @Test func theVerdictReadsOnlyWhatTheSessionAlreadyKnows() async throws {
        let probe = FakeBucketSettings(versioning: .never)
        let cache = BucketVersioningCache(settings: probe)
        let versions = BackendFileActionRoute.versions
        let action = FileActionContribution(
            id: versions.rawValue, titleKey: "browser.action.versions", titleDefault: "")
        // Not asked: offered, and nothing was read to decide it.
        #expect(
            BackendFileActionRoute.verdict(for: action, bucket: "b", cache: cache).isAvailable)
        #expect(probe.reads.isEmpty)
        // Read as never versioned: declined for THAT bucket only.
        _ = try await cache.versioning("b")
        #expect(
            !BackendFileActionRoute.verdict(for: action, bucket: "b", cache: cache).isAvailable)
        #expect(
            BackendFileActionRoute.verdict(for: action, bucket: "other", cache: cache).isAvailable)
        // No bucket (the bucket list) and no cache (no bucket settings) offer it.
        #expect(BackendFileActionRoute.verdict(for: action, bucket: nil, cache: cache).isAvailable)
        #expect(BackendFileActionRoute.verdict(for: action, bucket: "b", cache: nil).isAvailable)
        #expect(probe.reads == ["b"])
    }

    // MARK: - Wiring (source scans)

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent(relativePath))
    }

    private static func collapsed(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The handler switches over the route with no `default`, and every route
    /// has an arm. Without the second half an arm could be dropped while the
    /// first still compiled, if another arm used a multi-case pattern.
    @Test func theHandlerHasAnArmForEveryRouteAndNoDefault() throws {
        let source = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let body = Self.collapsed(
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: "func handleBrowserMenuEntry(", in: source))
        // Positives: the scan found the arm and the route switch at all.
        #expect(body.contains("case .backendFileAction(let action):"))
        let marker = try #require(body.range(of: "switch route {"), "no switch over the route")
        let routeSwitch = String(body[marker.upperBound...])
        #expect(!body.contains("default:"), "the handler has a default arm")
        for route in BackendFileActionRoute.allCases {
            let name = String(describing: route)
            let hasArm = ["case .\(name):", "case .\(name),", ", .\(name):", ", .\(name),"]
                .contains { routeSwitch.contains($0) }
            #expect(hasArm, "no arm for \(name)")
        }
    }

    /// Choosing the row opens the sheet: the arm assigns an item and the
    /// window presents it with the sheet, or the row would be live and inert.
    @Test func theHistoryArmAssignsAnItemTheWindowPresents() throws {
        let dispatcher = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let sheets = try Self.code("MacSCPAppKit/ContentView+Sheets.swift")
        let body = Self.collapsed(
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: "func handleBrowserMenuEntry(", in: dispatcher))
        let arm = try #require(body.range(of: "case .versions:"), "no arm for the history route")
        let assigned = try #require(
            body[arm.upperBound...].firstMatch(of: #/(\w+)\s*=\s*ObjectVersionsSheetItem\(/#),
            "the arm assigns no ObjectVersionsSheetItem")
        let state = String(assigned.output.1)
        let collapsedSheets = Self.collapsed(sheets)
        let presentation = try #require(
            collapsedSheets.range(of: ".sheet(item: $\(state))"), "\(state) is never presented")
        let closure = collapsedSheets[presentation.upperBound...].prefix(300)
        #expect(closure.contains("ObjectVersionsSheet("))
        // The arm is gated like its siblings: a single selected file on the
        // remote pane.
        let gated = body[arm.upperBound...].prefix(400)
        #expect(gated.contains("side == .remote"))
        #expect(gated.contains("selection.count == 1"))
    }

    /// Both panes answer for the availability closures, and only the remote
    /// one asks the session.
    @Test func bothPanesAnswerAndOnlyTheRemoteOneAsksTheSession() throws {
        let detail = try Self.code("MacSCPAppKit/ContentView+Detail.swift")
        let regions = Array(detail.components(separatedBy: "BrowserPane(").dropFirst())
        #expect(regions.count == 2, "ContentView+Detail builds \(regions.count) BrowserPane(s)")
        for region in regions {
            #expect(region.contains("isFileActionAvailable:"))
            #expect(region.contains("fileActionUnavailableReason:"))
        }
        let asking = regions.filter { $0.contains("fileActionVerdict(") }
        #expect(asking.count == 1)
        // Both closures ask, each for its own half of the verdict.
        let collapsedAsking = Self.collapsed(asking.first ?? "")
        #expect(collapsedAsking.contains("fileActionVerdict(action, in: tab, session: session).isAvailable"))
        #expect(collapsedAsking.contains("fileActionVerdict(action, in: tab, session: session).reason?.text"))
        #expect(asking.first?.contains("fileActions: {") == true, "the remote pane is the one that asks")
        let silent = regions.filter { !$0.contains("fileActionVerdict(") }
        #expect(silent.first?.contains("isFileActionAvailable: { _ in false }") == true)
    }

    /// The pane forwards what it was handed, and neither the pane nor the table
    /// view, nor its coordinator, gives either closure a default. The
    /// negative has its positive beside it: the declaration is found, with
    /// nothing after its type.
    @Test func noLayerGivesTheAvailabilityClosuresADefault() throws {
        let pane = try Self.code("MacSCPAppKit/BrowserPane.swift")
        #expect(pane.contains("isFileActionAvailable: isFileActionAvailable,"))
        #expect(pane.contains("fileActionUnavailableReason: fileActionUnavailableReason,"))
        let declaration =
            #/(?:var|let) (isFileActionAvailable|fileActionUnavailableReason): \(FileActionContribution\) -> (?:Bool|String\?)(\s*=)?/#
        var found = 0
        for file in ["BrowserPane.swift", "RemoteFileTableView.swift"] {
            let source = try Self.code("MacSCPAppKit/\(file)")
            for match in source.matches(of: declaration) {
                found += 1
                #expect(match.output.2 == nil, "\(file): \(match.output.1) has a default")
            }
        }
        // Two declarations in the pane and the table, and two more in the
        // table's coordinator.
        #expect(found == 6, "found \(found) declarations")
    }
}
