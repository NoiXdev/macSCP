import Foundation
import Observation

/// State and logic of the connection form.
/// The connector is injectable: production uses CitadelFileSystem.connect,
/// tests use a mock — the view model stays testable without a network.
@Observable
@MainActor
public final class ConnectionViewModel {
    /// The form field whose validation failed — the UI highlights it in red.
    public enum Field: Equatable, Sendable {
        case host
        case port
        case username
        case password
        case saveName
        case keyPath
    }

    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String, field: Field?)
    }

    /// Auth choice in the form. In key mode, `password` serves as the passphrase.
    public enum AuthChoice: String, CaseIterable, Sendable {
        case password
        case privateKey
    }

    /// Whether the form creates a brand-new connection or edits a stored
    /// session in place (M5f/T4). `edit` carries the session's id so
    /// `validateForEditSave()` can rebuild the same `StoredSession`.
    public enum FormMode: Equatable, Sendable {
        case new
        case edit(sessionID: UUID)
    }

    public typealias Connector = @Sendable (
        SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) async throws -> any RemoteFileSystem

    /// State while waiting for the user's decision on an unknown host key
    /// (see `resolveHostKeyPrompt`).
    public struct HostKeyPrompt: Equatable {
        public let candidate: HostKeyCandidate
    }

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    public var authChoice: AuthChoice = .password
    public var keyPath: String = ""
    /// Save the session after a successful connect (store + keychain)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
    /// Group assignment shown by the picker — applies while saving a new
    /// session (`shouldSaveSession == true`) AND while editing a stored one.
    public var selectedGroupID: UUID?
    public private(set) var state: State = .idle
    /// `.new` while the form creates a connection; `.edit` while it edits a
    /// stored session (see `beginEditing`/`endEditing`).
    public private(set) var mode: FormMode = .new
    /// While non-nil: the form UI shows the fingerprint card and waits for
    /// `resolveHostKeyPrompt`.
    public private(set) var hostKeyPrompt: HostKeyPrompt?

    private let connector: Connector
    /// Holds the continuation that the host-key decider places on `connect()`,
    /// until `resolveHostKeyPrompt` fulfills it. Stays private — the UI only
    /// knows `hostKeyPrompt` and `resolveHostKeyPrompt(trust:)`.
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Returns the connected file system or nil; errors land in `state`.
    /// Re-entrancy safe: calls made while `.connecting` are dropped, so a
    /// double-click doesn't open a second (orphaned) connection.
    public func connect() async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        defer { hostKeyPrompt = nil }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port)
            return nil
        }
        if authChoice == .password {
            guard !password.isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.passwordEmpty"), field: .password)
                return nil
            }
        } else {
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: .keyPath)
                return nil
            }
        }
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        do {
            let auth: SSHConnectionConfig.AuthMethod
            switch authChoice {
            case .password:
                auth = .password(password)
            case .privateKey:
                auth = .privateKey(
                    keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    passphrase: password.isEmpty ? nil : password)
            }
            let config = try SSHConnectionConfig(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: auth
            )
            state = .connecting
            let fs = try await connector(config) { [weak self] candidate in
                await self?.presentHostKeyPrompt(for: candidate) ?? false
            }
            state = .idle
            return fs
        } catch {
            state = Self.failedState(for: error)
            return nil
        }
    }

    /// Decider side: publishes the prompt and suspends on a continuation
    /// until `resolveHostKeyPrompt` fulfills it.
    /// Cancellation-safe: if the connect() task is cancelled while the prompt
    /// is open, the continuation resolves with `false` (no leak, no hang);
    /// the connector sees a rejection.
    private func presentHostKeyPrompt(for candidate: HostKeyCandidate) async -> Bool {
        hostKeyPrompt = HostKeyPrompt(candidate: candidate)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                hostKeyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveHostKeyPrompt(trust: false)
            }
        }
    }

    /// Called by the UI once the user answers the fingerprint card.
    /// Duplicate calls (e.g. a fast double-click) are ignored — the
    /// continuation may only be fulfilled once.
    public func resolveHostKeyPrompt(trust: Bool) {
        guard let continuation = hostKeyContinuation else { return }
        hostKeyContinuation = nil
        continuation.resume(returning: trust)
    }

    /// Removes the plaintext password from the state (e.g. after disconnecting).
    public func clearPassword() {
        password = ""
    }

    /// User-initiated mode switch (picker): clears the secret so the
    /// password/passphrase doesn't carry over into the other mode.
    /// Programmatic restore (connectStored) sets authChoice directly —
    /// without clearing (review finding M3c Task 0).
    public func selectAuthChoice(_ choice: AuthChoice) {
        guard choice != authChoice else { return }
        authChoice = choice
        clearPassword()
    }

    /// Fills the form from a stored session for in-place editing. The secret
    /// is deliberately NEVER loaded from the keychain — `password` stays
    /// empty; an empty password at save time means "leave unchanged" (see
    /// `validateForEditSave`/`ContentView.onSaveEdited`).
    public func beginEditing(_ stored: StoredSession) {
        host = stored.host
        port = String(stored.port)
        username = stored.username
        authChoice = stored.authKind == .privateKey ? .privateKey : .password
        keyPath = stored.keyPath ?? ""
        saveName = stored.name
        selectedGroupID = stored.groupID
        password = ""
        mode = .edit(sessionID: stored.id)
        state = .idle
    }

    /// Leaves edit mode and resets the form to the same blank state the
    /// app's per-tab teardown leaves it in for a new connection. Built on
    /// `exitEditMode()` (mode + group reset) plus the full field reset —
    /// the two used to duplicate the mode handling (M6a).
    public func endEditing() {
        exitEditMode()
        host = ""
        port = "22"
        username = ""
        password = ""
        authChoice = .password
        keyPath = ""
        shouldSaveSession = false
        saveName = ""
        state = .idle
    }

    /// Leaves edit mode WITHOUT touching the form fields. The app's tab
    /// teardown and every sidebar-navigation path (connect stored, import
    /// fill, disconnect) call this: a stale `.edit` target surviving those
    /// paths would make a later Save overwrite the wrong stored session,
    /// while the field values are owned by the caller (teardown/connect set
    /// them explicitly right after).
    public func exitEditMode() {
        mode = .new
        selectedGroupID = nil
    }

    /// Validates the form for saving an edited session (password may be
    /// empty — unlike `connect()`) and, on success, returns the rebuilt
    /// `StoredSession` carrying the id from `mode`. On failure sets `state`
    /// to `.failed` with the same `core.connect.*` messages/fields as
    /// `connect()` and returns nil.
    public func validateForEditSave() -> StoredSession? {
        guard case .edit(let sessionID) = mode else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.emptyHost"), field: .host)
            return nil
        }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port)
            return nil
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.emptyUsername"), field: .username)
            return nil
        }
        let trimmedName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        let trimmedKeyPath = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if authChoice == .privateKey {
            guard !trimmedKeyPath.isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: .keyPath)
                return nil
            }
        }
        state = .idle
        return StoredSession(
            id: sessionID,
            name: trimmedName,
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authKind: authChoice == .privateKey ? .privateKey : .password,
            keyPath: authChoice == .privateKey ? trimmedKeyPath : nil,
            groupID: selectedGroupID)
    }

    static func failedState(for error: Error) -> State {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return .failed(message: CoreL10n.string("core.connect.emptyHost"), field: .host)
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return .failed(message: CoreL10n.string("core.connect.emptyUsername"), field: .username)
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.invalidPort %@"), String(port)),
                field: .port)
        case RemoteFSError.authenticationFailed:
            return .failed(
                message: CoreL10n.string("core.connect.authFailed"),
                field: nil)
        case RemoteFSError.connectionFailed(let reason):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.connectionFailed %@"), reason),
                field: nil)
        case SSHKeyError.fileNotFound(let path):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.keyNotFound %@"), path),
                field: .keyPath)
        case SSHKeyError.passphraseRequired:
            return .failed(
                message: CoreL10n.string("core.connect.keyPassphraseRequired"),
                field: .password)
        case SSHKeyError.wrongPassphrase:
            return .failed(message: CoreL10n.string("core.connect.keyWrongPassphrase"), field: .password)
        case SSHKeyError.unsupportedFormat:
            return .failed(
                message: CoreL10n.string("core.connect.keyUnsupportedFormat"),
                field: .keyPath)
        case HostKeyError.mismatch(let host, let expected, let presented):
            return .failed(
                message: String(
                    format: CoreL10n.string("core.hostkey.mismatch %@ %@ %@"),
                    host, expected, presented),
                field: nil)
        case HostKeyError.rejectedByUser:
            return .failed(message: CoreL10n.string("core.hostkey.rejected"), field: nil)
        default:
            return .failed(
                message: String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error)),
                field: nil)
        }
    }
}
