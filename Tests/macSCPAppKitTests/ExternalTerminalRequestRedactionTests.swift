import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The password hint is one of two places in the app where a resolved config
/// outlives the call that produced it -- the other being
/// `ConnectionViewModel.lastConnectedConfig`, redacted the same way at
/// assignment. It must not carry a secret while it waits: view state is
/// reached by neither `disconnect` nor `clearRetainedSecrets`.
///
/// `@MainActor` mirrors `ExternalTerminalLauncherTests`: `ContentView` is a
/// SwiftUI `View`, and its main-actor isolation is the kind of thing that
/// makes synchronous call sites in a non-isolated suite fail to compile.
/// Marking the suite costs nothing if the isolation turns out not to reach
/// the nested type.
@Suite("ExternalTerminalRequest redaction")
@MainActor
struct ExternalTerminalRequestRedactionTests {
    @Test func theRetainedConfigCarriesNoPassword() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .terminalApp, customPath: nil)

        // Hoisted into a Bool: `#expect` expands its receiver, and no
        // expansion may be able to print a password.
        let isEmptiedPassword: Bool
        if case .password(let value) = request.config.auth {
            isEmptiedPassword = value.isEmpty
        } else {
            isEmptiedPassword = false
        }
        #expect(isEmptiedPassword)
    }

    @Test func theRetainedConfigCarriesNoKeyPassphrase() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .terminalApp, customPath: nil)

        let hasNoPassphrase: Bool
        if case .privateKey(_, let passphrase) = request.config.auth {
            hasNoPassphrase = passphrase == nil
        } else {
            hasNoPassphrase = false
        }
        #expect(hasNoPassphrase)
    }

    @Test func everythingTheLauncherNeedsSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim", auth: .password("hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .custom, customPath: "/Applications/Ghostty.app")

        #expect(request.config.host == "example.com")
        #expect(request.config.port == 2200)
        #expect(request.config.username == "tim")
        #expect(request.target == .custom)
        #expect(request.customPath == "/Applications/Ghostty.app")
    }
}
