import Foundation
import Testing
@testable import macSCPCore

/// Covers the whole decision surface of `CLIToolInstaller` against a real
/// temporary directory (same style as `ManagedKeyStoreTests`): every state the
/// UI can render, plus the install paths that must NOT silently destroy
/// something — a regular file the user put at the link path, a repeated
/// install over a link that is already correct, and a link made from a
/// translocated app copy that would be dead before the user ever typed the
/// command.
///
/// Most tests build a throwaway sandbox and hit the real filesystem;
/// `systemWideCommandQuotesThePathAndTargetsUsrLocalBin` and
/// `defaultBinDirectoryIsDotLocalBinInTheHomeDirectory` are the two that only
/// inspect constructed paths. Neither of those touches the real
/// `~/.local/bin` — they read paths and never write.
@Suite("CLIToolInstaller")
struct CLIToolInstallerTests {
    /// A throwaway sandbox holding both a fake "bin" directory and a fake
    /// app-bundle CLI binary, so no test ever touches the real
    /// `~/.local/bin`.
    private struct Sandbox {
        let root: URL
        var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
        var toolURL: URL { root.appendingPathComponent("macSCP.app/Contents/MacOS/macscp-cli") }
        var installer: CLIToolInstaller {
            CLIToolInstaller(binDirectory: binDirectory, toolURL: toolURL)
        }
    }

    /// Creates the sandbox root and the fake CLI binary; `createBinDirectory:
    /// false` leaves `bin/` absent so `install()` has to create it.
    private func makeSandbox(createBinDirectory: Bool = true) throws -> Sandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cli-install-\(UUID().uuidString)")
        let sandbox = Sandbox(root: root)
        try FileManager.default.createDirectory(
            at: sandbox.toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: sandbox.toolURL)
        if createBinDirectory {
            try FileManager.default.createDirectory(
                at: sandbox.binDirectory, withIntermediateDirectories: true)
        }
        return sandbox
    }

    private func remove(_ sandbox: Sandbox) {
        try? FileManager.default.removeItem(at: sandbox.root)
    }

    // MARK: - States

    @Test func missingLinkIsNotInstalled() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        #expect(sandbox.installer.state() == .notInstalled)
    }

    @Test func linkToOwnToolIsInstalled() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try FileManager.default.createSymbolicLink(
            at: sandbox.installer.linkURL, withDestinationURL: sandbox.toolURL)
        #expect(sandbox.installer.state() == .installed)
    }

    /// A relative symlink (what `ln -s` writes when handed a relative path)
    /// must be resolved against the LINK's directory, not the process's
    /// working directory — otherwise a perfectly good link reads as stale.
    @Test func relativeLinkToOwnToolIsInstalled() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try FileManager.default.createSymbolicLink(
            atPath: sandbox.installer.linkURL.path(percentEncoded: false),
            withDestinationPath: "../macSCP.app/Contents/MacOS/macscp-cli")
        #expect(sandbox.installer.state() == .installed)
    }

    /// A second app copy (say, one left in ~/Downloads after an update was
    /// dragged to /Applications) — the link still resolves, just not to us.
    @Test func linkToAnotherCopyIsStaleAndNamesTheTarget() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        let other = sandbox.root.appendingPathComponent("Downloads/macSCP.app/Contents/MacOS/macscp-cli")
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(
            at: sandbox.installer.linkURL, withDestinationURL: other)

        #expect(sandbox.installer.state() == .stale(target: other.standardizedFileURL.path(percentEncoded: false)))
    }

    /// The same verdict must hold when the other copy is GONE (a dangling
    /// link): the state machine may not depend on the target existing.
    @Test func linkToDeletedCopyIsStaleAndNamesTheTarget() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        let gone = sandbox.root.appendingPathComponent("Trash/macSCP.app/Contents/MacOS/macscp-cli")
        try FileManager.default.createSymbolicLink(
            at: sandbox.installer.linkURL, withDestinationURL: gone)

        #expect(sandbox.installer.state() == .stale(target: gone.standardizedFileURL.path(percentEncoded: false)))
    }

    @Test func regularFileAtLinkPathIsOccupied() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try Data("mine".utf8).write(to: sandbox.installer.linkURL)
        #expect(sandbox.installer.state() == .occupied)
    }

    // MARK: - Install

    @Test func installCreatesTheLinkAndReportsInstalled() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try sandbox.installer.install()
        #expect(sandbox.installer.state() == .installed)
    }

    @Test func installCreatesAMissingBinDirectory() throws {
        let sandbox = try makeSandbox(createBinDirectory: false)
        defer { remove(sandbox) }
        #expect(!FileManager.default.fileExists(atPath: sandbox.binDirectory.path(percentEncoded: false)))

        try sandbox.installer.install()

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.binDirectory.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(sandbox.installer.state() == .installed)
    }

    @Test func installOverAStaleLinkRepairsIt() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try FileManager.default.createSymbolicLink(
            at: sandbox.installer.linkURL,
            withDestinationURL: sandbox.root.appendingPathComponent("elsewhere/macscp-cli"))

        try sandbox.installer.install()
        #expect(sandbox.installer.state() == .installed)
    }

    @Test func installingTwiceIsNotAnError() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try sandbox.installer.install()
        try sandbox.installer.install()
        #expect(sandbox.installer.state() == .installed)
    }

    /// The one case that must refuse: something that is not a symlink already
    /// occupies the path. Overwriting it would destroy a file the user put
    /// there — so `install()` throws and the file survives byte-for-byte.
    @Test func installRefusesToOverwriteARegularFile() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        let linkPath = sandbox.installer.linkURL.path(percentEncoded: false)
        try Data("mine".utf8).write(to: sandbox.installer.linkURL)

        #expect(throws: CLIInstallError.pathOccupied(linkPath)) {
            try sandbox.installer.install()
        }
        #expect(try String(contentsOf: sandbox.installer.linkURL, encoding: .utf8) == "mine")
        #expect(sandbox.installer.state() == .occupied)
    }

    // MARK: - Displayed system-wide command

    /// The app never runs this — it is text the user copies into a terminal.
    /// It must name the running copy's real path, single-quoted so a space in
    /// it cannot split the command into two words.
    @Test func systemWideCommandQuotesThePathAndTargetsUsrLocalBin() throws {
        let root = URL(fileURLWithPath: "/Applications/My Apps/macSCP.app/Contents/MacOS/macscp-cli")
        let installer = CLIToolInstaller(
            binDirectory: URL(fileURLWithPath: "/tmp/bin"), toolURL: root)

        #expect(
            installer.systemWideInstallCommand
                == "sudo mkdir -p /usr/local/bin && sudo ln -sf '/Applications/My Apps/macSCP.app/Contents/MacOS/macscp-cli' /usr/local/bin/macscp-cli"
        )
    }

    /// Pins the literal value rather than recomputing the implementation's own
    /// expression — a test built the second way stays green if both sides
    /// drift to `.local/sbin` together, which is precisely the change it
    /// exists to catch.
    /// Reads nothing and writes nothing — the default installer is only ever
    /// asked for its paths here, so the real `~/.local/bin` stays untouched.
    @Test func defaultBinDirectoryIsDotLocalBinInTheHomeDirectory() {
        // Trailing slash: `defaultBinDirectory` is built as a directory URL,
        // and unlike the old `URL.path`, `path(percentEncoded:)` preserves it.
        #expect(
            CLIToolInstaller.defaultBinDirectory.path(percentEncoded: false)
                == NSHomeDirectory() + "/.local/bin/")
        // The string the section actually displays, directory and tool name
        // pinned together in one literal.
        let installer = CLIToolInstaller(toolURL: URL(fileURLWithPath: "/nonexistent/macscp-cli"))
        #expect(
            installer.linkURL.path(percentEncoded: false)
                == NSHomeDirectory() + "/.local/bin/macscp-cli")
    }

    // MARK: - App Translocation

    /// Gatekeeper's read-only copy of a quarantined app, in the shape the real
    /// one has: `…/AppTranslocation/<UUID>/d/macSCP.app/Contents/MacOS/`.
    private func translocatedTool(in sandbox: Sandbox) -> URL {
        sandbox.root
            .appendingPathComponent("AppTranslocation/\(UUID().uuidString)/d")
            .appendingPathComponent("macSCP.app/Contents/MacOS/macscp-cli")
    }

    /// The green-lie case: linking from a translocated bundle succeeds, then
    /// dies the moment the app quits and the mount goes. Refused outright.
    @Test func translocatedAppIsReportedAndInstallsNothing() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        let installer = CLIToolInstaller(
            binDirectory: sandbox.binDirectory, toolURL: translocatedTool(in: sandbox))

        #expect(installer.state() == .translocated)
        #expect(throws: CLIInstallError.appIsTranslocated) { try installer.install() }
        #expect(
            !FileManager.default.fileExists(
                atPath: installer.linkURL.path(percentEncoded: false)))
    }

    /// Translocation must OUTRANK the link comparison. A user with a perfectly
    /// good shortcut who reopens the app from the disk image would otherwise
    /// be shown "points at a different copy" and offered a Repair that
    /// replaces a working link with a doomed one.
    @Test func translocationOutranksAWorkingShortcut() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        try FileManager.default.createSymbolicLink(
            at: sandbox.installer.linkURL, withDestinationURL: sandbox.toolURL)
        #expect(sandbox.installer.state() == .installed)

        let translocated = CLIToolInstaller(
            binDirectory: sandbox.binDirectory, toolURL: translocatedTool(in: sandbox))
        #expect(translocated.state() == .translocated)
    }

    /// The other half: a marker loose enough to fire on ordinary paths would
    /// block every installation instead of the doomed ones.
    @Test func anOrdinaryBundlePathIsNotTranslocated() throws {
        let sandbox = try makeSandbox()
        defer { remove(sandbox) }
        #expect(!CLIToolInstaller.isTranslocated(sandbox.toolURL))
        #expect(
            !CLIToolInstaller.isTranslocated(
                URL(fileURLWithPath: "/Applications/macSCP.app/Contents/MacOS/macscp-cli")))
        #expect(sandbox.installer.state() == .notInstalled)
    }
}
