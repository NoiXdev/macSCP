// Tests/macSCPCoreTests/HostKeyPolicyTests.swift
import Foundation
import Testing
@testable import macSCPCore

/// The policy answers ONE question: what to do about an UNKNOWN host key.
/// A mismatch never reaches it — `HostKeyValidation` stops that before any
/// decider runs (M3c). `mismatchNeverReachesThePolicy` pins that boundary.
@Suite("HostKeyPolicy")
struct HostKeyPolicyTests {
    @Test func askPromptsWhenATerminalIsAvailable() {
        #expect(HostKeyPolicy.decision(for: .ask, hasTTY: true) == .prompt)
    }

    @Test func askRejectsWithoutATerminal() {
        // The non-interactive case: no way to ask, so refuse rather than
        // silently trust. This is the promise every cron job relies on.
        #expect(HostKeyPolicy.decision(for: .ask, hasTTY: false) == .reject)
    }

    @Test func rejectRefusesRegardlessOfTerminal() {
        #expect(HostKeyPolicy.decision(for: .reject, hasTTY: true) == .reject)
        #expect(HostKeyPolicy.decision(for: .reject, hasTTY: false) == .reject)
    }

    @Test func acceptNewAcceptsRegardlessOfTerminal() {
        #expect(HostKeyPolicy.decision(for: .acceptNew, hasTTY: true) == .accept)
        #expect(HostKeyPolicy.decision(for: .acceptNew, hasTTY: false) == .accept)
    }
}
