import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// Carries the config the connector was handed out of the `@Sendable`
/// closure that receives it.
private final class DialedConfigBox: @unchecked Sendable {
    var config: ConnectionConfig?
}

/// Holds the connector inside the dial until the test lets it go, so a
/// `connect()` can be observed while it is genuinely in flight.
private final class ConnectorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async throws {
        try await awaitResumption { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.released {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let pending = continuation
        continuation = nil
        released = true
        lock.unlock()
        pending?.resume()
    }
}

/// The equivalence guard between dialing and not dialing one shared
/// resolution (P3c/T1): `connect()` dials the config it resolves, while the
/// external-terminal route resolves the same config and hands it to a
/// launcher. (`validateForNewSave()` is a third caller of that resolution
/// and is guarded by `SaveWithoutDialingTests` instead — it discards the
/// config, so there is nothing here to compare it against.) Every test here fills
/// TWO identically configured view models and compares what one dialed with
/// what the other resolved, so the guard goes red as soon as either path
/// grows a step the other does not have — which is the whole reason this
/// function exists instead of a second hand-written copy of the three steps.
///
/// No `#expect` receiver here ever expands a `ConnectionConfig`: the config
/// carries the plaintext password, and a failing expectation prints its
/// receiver. Every comparison that touches one is hoisted into a `Bool`
/// first; the failure comparisons go through `failure(of:)`, which yields a
/// `State` (message + field, never a value).
@Suite("Connection config resolution")
@MainActor
struct ConnectionConfigResolutionTests {
    private struct Pair {
        let dialing: ConnectionViewModel
        let resolving: ConnectionViewModel
        let dialed: DialedConfigBox
    }

    /// Two separate instances on purpose: the guard must not depend on the
    /// two paths running in a particular order on one form, and the
    /// resolving one's connector records an issue if it is ever reached.
    private func makePair(_ fill: (ConnectionViewModel) -> Void) -> Pair {
        let box = DialedConfigBox()
        let dialing = ConnectionViewModel(connector: { config, _ in
            box.config = config
            return MockRemoteFileSystem(tree: ["/": []])
        })
        let resolving = ConnectionViewModel(connector: { _, _ in
            Issue.record("Resolving a config must not dial anything")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        for vm in [dialing, resolving] {
            vm.host = "example.com"
            vm.port = "22"
            vm.username = "tim"
            vm.password = "target-secret"
            fill(vm)
        }
        return Pair(dialing: dialing, resolving: resolving, dialed: box)
    }

    private func failure(of resolution: ConnectionViewModel.ConfigResolution)
        -> ConnectionViewModel.State? {
        guard case .failed(let state) = resolution else { return nil }
        return state
    }

    @Test func plainSSHResolvesTheConfigConnectDials() async {
        let pair = makePair { _ in }

        _ = await pair.dialing.connect()
        let resolution = pair.resolving.resolveConfigWithoutDialing()

        guard let dialed = pair.dialed.config else {
            Issue.record("connect() never reached the connector")
            return
        }
        let identical = resolution == .resolved(dialed)
        #expect(identical)
    }

    @Test func aJumpHostResolvesTheConfigConnectDials() async {
        let pair = makePair { vm in
            vm.jumpEnabled = true
            vm.jumpHost = "bastion.example.com"
            vm.jumpPort = "2200"
            vm.jumpUsername = "bastion-user"
            vm.jumpPassword = "bastion-secret"
        }

        _ = await pair.dialing.connect()
        let resolution = pair.resolving.resolveConfigWithoutDialing()

        guard let dialed = pair.dialed.config else {
            Issue.record("connect() never reached the connector")
            return
        }
        let identical = resolution == .resolved(dialed)
        #expect(identical)
        // Proves this case is not the plain one in disguise: a resolution
        // that dropped the hop would still be `.ssh`, and comparing it
        // against a `connect()` that dropped the hop too would agree.
        guard case .resolved(.ssh(let ssh)) = resolution else {
            Issue.record("expected a resolved .ssh config")
            return
        }
        #expect(ssh.jump?.host == "bastion.example.com")
        #expect(ssh.jump?.port == 2200)
    }

    @Test func aSchemaViolationYieldsTheStateConnectPublishes() async {
        let pair = makePair { $0.host = "" }

        _ = await pair.dialing.connect()
        let resolution = pair.resolving.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) == pair.dialing.state)
        #expect(pair.dialing.state == .failed(
            message: CoreL10n.string("core.connect.emptyHost"),
            field: .schema("SSHField.host")))
    }

    @Test func anInvalidJumpPortYieldsTheStateConnectPublishes() async {
        let pair = makePair { vm in
            vm.jumpEnabled = true
            vm.jumpHost = "bastion.example.com"
            // Parses as an `Int`, so `validateJump` waves it through, and is
            // rejected by `SSHConnectionConfig.init` — the failure site that
            // sits AFTER `makeConfig`, which a resolution stopping at the
            // form validation would never reach.
            vm.jumpPort = "70000"
            vm.jumpUsername = "bastion-user"
            vm.jumpPassword = "bastion-secret"
        }

        _ = await pair.dialing.connect()
        let resolution = pair.resolving.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) == pair.dialing.state)
        #expect(pair.dialing.state == .failed(
            message: String(format: CoreL10n.string("core.connect.invalidJumpPort %@"), "70000"),
            field: .jumpPort))
    }

    /// The save name is a rule of the FORM's save, not of the connection.
    /// `connect()` refuses a blank one; a resolution — whose caller may not
    /// be saving anything, and whose form may legitimately still carry
    /// `shouldSaveSession == true` from an ad-hoc "save & connect" — is not
    /// refused for it. Both halves are asserted here, so moving the check
    /// into the shared function again turns this red.
    @Test func aBlankSaveNameStopsConnectButNotResolution() async {
        let pair = makePair { vm in
            vm.shouldSaveSession = true
            vm.saveName = "   "
        }

        let fs = await pair.dialing.connect()

        #expect(fs == nil)
        #expect(pair.dialing.state == .failed(
            message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName))
        let neverDialed = pair.dialed.config == nil
        #expect(neverDialed)

        let resolution = pair.resolving.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) == nil)
    }

    /// The decision this task had to make deliberately: resolving PUBLISHES
    /// nothing. The caller gets the state `connect()` would have published
    /// and decides where it belongs — a context menu has no form on screen,
    /// and a resolution that assigned `state` itself would also overwrite an
    /// in-flight connect's `.connecting`.
    @Test func resolvingPublishesNoStateOnFailure() {
        let pair = makePair { $0.host = "" }
        #expect(pair.resolving.state == .idle)

        let resolution = pair.resolving.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) != nil)
        #expect(pair.resolving.state == .idle)
    }

    /// `lastConnectedConfig` stores its config redacted, so no plaintext
    /// password outlives the dial. Resolving must not open a second place a
    /// resolved config lives on: it retains nothing, and the returned value
    /// is the caller's to hold for the length of its call.
    @Test func resolvingRetainsNothing() {
        let pair = makePair { _ in }

        let resolution = pair.resolving.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) == nil)
        let retainedNothing = pair.resolving.lastConnectedConfig == nil
        #expect(retainedNothing)
        #expect(pair.resolving.state == .idle)
    }

    /// The other half of "publishes nothing": resolving while a `connect()`
    /// is in flight must leave that connect's `.connecting` intact. A
    /// resolution that assigned `state` itself would overwrite it — and the
    /// external-terminal entry is reachable from a window whose form is
    /// mid-connect.
    @Test func resolvingLeavesAnInFlightConnectUndisturbed() async {
        let gate = ConnectorGate()
        let vm = ConnectionViewModel(connector: { _, _ in
            try await gate.wait()
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "target-secret"

        let connecting = Task { await vm.connect() }
        var spins = 0
        while vm.state != .connecting && spins < 1_000 {
            spins += 1
            await Task.yield()
        }
        guard vm.state == .connecting else {
            gate.release()
            _ = await connecting.value
            Issue.record("connect() never reached the .connecting state")
            return
        }

        let resolution = vm.resolveConfigWithoutDialing()

        #expect(failure(of: resolution) == nil)
        #expect(vm.state == .connecting)
        gate.release()
        let fs = await connecting.value
        #expect(fs != nil)
        #expect(vm.state == .idle)
    }
}
