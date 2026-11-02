import AppKit
import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The availability closures reach the table's coordinator -- on the first
/// build and on every update -- because the closures capture the session and
/// the tab, and a coordinator that kept the first pair would answer for the
/// menu's first build for as long as the pane lived.
///
/// Task 6's review found the two assignments (`makeCoordinator` and
/// `updateNSView`) exercised by no test: dropping the `updateNSView` line left
/// the suite green while the table kept stale closures after a state change.
/// That was untested because nothing passed the closures. These cases host the
/// real table view in a window and change what it is handed, so the
/// representable's own `makeCoordinator` and `updateNSView` run.
@Suite("File action threading", .serialized)
@MainActor
struct FileActionThreadingTests {
    private static let action = FileActionContribution(
        id: "s3.versions", titleKey: "browser.action.versions", titleDefault: "Show Versions…")

    /// A table whose closures answer `available`, and whose reason is
    /// `reason`. Everything else is inert.
    private static func table(available: Bool, reason: String?) -> RemoteFileTableView {
        RemoteFileTableView(
            items: [RemoteFileItem(name: "a.txt", path: "/b/a.txt", kind: .file)],
            selectedPaths: [], onOpen: { _ in }, onSelect: { _ in }, side: .remote,
            isFileActionAvailable: { _ in available },
            fileActionUnavailableReason: { _ in reason })
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = findTable(in: child) { return found }
        }
        return nil
    }

    /// The coordinator `makeCoordinator` builds answers with the closures the
    /// view was built with, both of them.
    @Test func theFirstCoordinatorAnswersWithTheClosuresItWasBuiltWith() {
        let live = Self.table(available: true, reason: nil).makeCoordinator()
        #expect(live.isFileActionAvailable(Self.action) == true)
        #expect(live.fileActionUnavailableReason(Self.action) == nil)
        let declined = Self.table(available: false, reason: "why").makeCoordinator()
        #expect(declined.isFileActionAvailable(Self.action) == false)
        #expect(declined.fileActionUnavailableReason(Self.action) == "why")
    }

    /// The function `updateNSView` calls replaces both closures. A coordinator
    /// that kept its first pair is red.
    @Test func refreshingHandsOverBothClosures() {
        let coordinator = Self.table(available: true, reason: nil).makeCoordinator()
        Self.table(available: false, reason: "changed").refreshAvailability(of: coordinator)
        #expect(coordinator.isFileActionAvailable(Self.action) == false)
        #expect(coordinator.fileActionUnavailableReason(Self.action) == "changed")
    }

    /// The end of it: the table hosted in a window, then handed a different
    /// view. SwiftUI calls `updateNSView` on the same coordinator, and the
    /// coordinator answers for the new state.
    @Test func aHostedTableKeepsNoStaleClosureAfterAStateChange() throws {
        let host = NSHostingView(rootView: Self.table(available: true, reason: nil))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let tableView = try #require(Self.findTable(in: host), "the hosted view holds no table")
        let coordinator = try #require(
            tableView.delegate as? RemoteFileTableView.Coordinator,
            "the table's delegate is not the representable's coordinator")
        // The first build, as built (the positive for what follows).
        #expect(coordinator.isFileActionAvailable(Self.action) == true)

        host.rootView = Self.table(available: false, reason: "now declined")
        host.layoutSubtreeIfNeeded()
        // The same coordinator, not a new one: this was an update.
        #expect(tableView.delegate === coordinator)
        #expect(coordinator.isFileActionAvailable(Self.action) == false)
        #expect(coordinator.fileActionUnavailableReason(Self.action) == "now declined")
    }

    /// `updateNSView` calls the refresh, and `makeCoordinator` hands the
    /// closures to the coordinator's initializer, which has no default for
    /// them. The source half of the hosted case above, kept because that case
    /// depends on SwiftUI updating inside `layoutSubtreeIfNeeded`.
    @Test func theRepresentableThreadsThemOnBuildAndOnEveryUpdate() throws {
        let source = try SourceCorpus.code(
            of: SourceCorpus.url(of: .sources)
                .appendingPathComponent("MacSCPAppKit/RemoteFileTableView.swift"))
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let update = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func updateNSView(", in: source)
        #expect(update.contains("refreshAvailability(of: context.coordinator)"))
        let make = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func makeCoordinator(", in: source)
        let makeCollapsed = make.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(makeCollapsed.contains("isFileActionAvailable: isFileActionAvailable,"))
        #expect(makeCollapsed.contains("fileActionUnavailableReason: fileActionUnavailableReason)"))
        // The refresh itself assigns both.
        #expect(collapsed.contains("coordinator.isFileActionAvailable = isFileActionAvailable"))
        #expect(
            collapsed.contains(
                "coordinator.fileActionUnavailableReason = fileActionUnavailableReason"))
    }
}
