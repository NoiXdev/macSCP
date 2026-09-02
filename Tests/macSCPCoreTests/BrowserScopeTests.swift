import Foundation
import Testing
@testable import macSCPCore

/// The ONE predicate both browser menus and the drop target consult for
/// "is this row a container rather than something inside one" (2026-09-02,
/// Task 4). Ungated: it is a pure function of a path, a mode flag and the
/// pane's current directory — no connection, no rig.
@Suite("BrowserScope")
struct BrowserScopeTests {
    /// The four rows the design distinguishes, in one table.
    ///
    /// The BUCKET row is the only `true`: an object and a prefix both sit
    /// below a bucket, and with the toggle OFF the very same one-component
    /// path is an object key in the configured bucket — which is why the
    /// flag is part of the question and not just the depth.
    @Test func onlyABucketRowIsAContainerRow() {
        let listMode = BrowserScope(rootIsContainerList: true, currentPath: "/")

        // A bucket row: one component, and the root lists containers.
        #expect(listMode.isContainerRow(path: "/macscp-seed"))
        // An object row and a prefix row, one level in.
        #expect(!listMode.isContainerRow(path: "/macscp-seed/a.txt"))
        #expect(!listMode.isContainerRow(path: "/macscp-seed/dir"))
        // The list itself is not a row in it.
        #expect(!listMode.isContainerRow(path: "/"))

        // Toggle off: the same one-component path is an ordinary object,
        // and an SSH/WebDAV pane answers this way for every path there is.
        let ordinary = BrowserScope.ordinary
        #expect(!ordinary.isContainerRow(path: "/macscp-seed"))
        #expect(!ordinary.isContainerRow(path: "/macscp-seed/a.txt"))
        #expect(!ordinary.isContainerRow(path: "/"))
    }

    /// Hand-typed shapes reach this through the path bar, so the predicate
    /// normalizes rather than trusting the string it is handed.
    @Test func aRepeatedOrTrailingSlashDoesNotHideABucketRow() {
        let listMode = BrowserScope(rootIsContainerList: true, currentPath: "/")

        #expect(listMode.isContainerRow(path: "/macscp-seed/"))
        #expect(listMode.isContainerRow(path: "//macscp-seed//"))
        #expect(!listMode.isContainerRow(path: "//macscp-seed//a.txt"))
        #expect(!listMode.isContainerRow(path: "//"))
    }

    /// The pane-level half of the same question: the listing whose ROWS are
    /// containers. It is what the drop target and the background menu ask,
    /// where there is no row to point at.
    @Test func onlyTheRootOfAContainerListSessionIsTheContainerList() {
        #expect(BrowserScope(rootIsContainerList: true, currentPath: "/").isContainerListRoot)
        #expect(BrowserScope(rootIsContainerList: true, currentPath: "//").isContainerListRoot)
        #expect(!BrowserScope(rootIsContainerList: true, currentPath: "/macscp-seed")
            .isContainerListRoot)
        #expect(!BrowserScope(rootIsContainerList: false, currentPath: "/").isContainerListRoot)
        #expect(!BrowserScope.ordinary.isContainerListRoot)
    }

    /// The DESTINATION-side value — asked by every way a transfer can be
    /// aimed at a pane, not only by the drop (review C-1). A transfer into
    /// the bucket list would ask for a bucket to be created; the queue
    /// refuses it, but nothing is offered before that — and, one level in,
    /// everything works exactly as it always did.
    @Test func nothingCanBeSentIntoTheBucketListAndOneLevelInEverythingCan() {
        #expect(!BrowserScope(rootIsContainerList: true, currentPath: "/").acceptsIncomingFiles)
        #expect(!BrowserScope(rootIsContainerList: true, currentPath: "//").acceptsIncomingFiles)
        #expect(BrowserScope(rootIsContainerList: true, currentPath: "/macscp-seed")
            .acceptsIncomingFiles)
        #expect(BrowserScope(rootIsContainerList: true, currentPath: "/macscp-seed/dir")
            .acceptsIncomingFiles)
        // Toggle off — and every SSH/WebDAV pane, and every LOCAL pane: `/`
        // is an ordinary directory and has always received transfers.
        #expect(BrowserScope(rootIsContainerList: false, currentPath: "/").acceptsIncomingFiles)
        #expect(BrowserScope.ordinary.acceptsIncomingFiles)
    }

    /// The default a caller that says nothing gets. Every pane that
    /// predates this — and every SSH/WebDAV pane after it — answers no to
    /// both questions, which is what keeps the menus byte-identical there.
    @Test func theOrdinaryScopeAnswersNoToEverything() {
        #expect(BrowserScope.ordinary.rootIsContainerList == false)
        #expect(BrowserScope.ordinary.isContainerListRoot == false)
        #expect(BrowserScope.ordinary.isContainerRow(path: "/anything") == false)
        #expect(BrowserScope.ordinary.acceptsIncomingFiles)
    }
}
