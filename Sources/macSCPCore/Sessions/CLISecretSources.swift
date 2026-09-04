import Foundation

/// Reads a secret from the stdout of an external command (`--password-command`,
/// M20). Runs through `/bin/sh -c` so the caller can use the same quoting,
/// pipes, and substitutions they would at a shell prompt (e.g. a password
/// manager's CLI). Always ordered FIRST in the CLI's chain — explicit beats
/// implicit.
public struct PasswordCommandSecretSource: SecretSource {
    public let label = "--password-command"
    private let command: String
    private let timeout: TimeInterval

    /// `timeout` bounds the ENTIRE invocation (launch through exit). 10
    /// seconds by default: stdin is the null device (see `secret(for:)`
    /// below), so a correctly-behaving helper can never be waiting on an
    /// interactive prompt — it is reading from an already-unlocked vault, a
    /// cache, or making a bounded network call. A helper that hasn't
    /// answered within a handful of seconds is broken (hung on the network,
    /// waiting on a prompt with nowhere to answer, or simply wedged), and in
    /// cron/CI that must fail fast, not hang the invocation forever.
    /// Injectable so tests never have to wait out the real duration.
    public init(command: String, timeout: TimeInterval = 10.0) {
        self.command = command
        self.timeout = timeout
    }

    /// A failure here names the COMMAND's failure only: an exit code, or
    /// "output unreadable" — never a byte of what the command printed or was
    /// given. That is a hard requirement (M20 design): a leaked error message
    /// must never be the way a secret gets disclosed. `sessionID` is unused —
    /// the command has no notion of which session it is being asked for; the
    /// CLI runs one resolve per connect and expects the command to print the
    /// one secret that connect needs.
    public func secret(for sessionID: UUID) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            throw PasswordCommandError.launchFailed
        }

        // Drain the pipe on a background queue so a slow/stalled child can
        // never block this thread past `timeout`. This keeps the safe
        // ordering (drain BEFORE waiting) that avoids the classic deadlock —
        // calling `waitUntilExit()` first and draining after can wedge
        // forever if the child fills the pipe's kernel buffer before it
        // exits, since the child then blocks on its own `write()` while we
        // block on `waitUntilExit()`, and neither side ever proceeds. Here
        // the pipe is always drained concurrently with waiting, on both the
        // normal and the timeout path.
        let collected = CollectedOutput()
        let readQueue = DispatchQueue(label: "macscp.password-command.read")
        let readDone = DispatchSemaphore(value: 0)
        readQueue.async {
            collected.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        guard readDone.wait(timeout: .now() + timeout) == .success else {
            // Escalate: ask nicely first, then insist. A broken helper that
            // ignores SIGTERM (the scenario this whole fix exists for) must
            // not be left running.
            process.terminate()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw PasswordCommandError.timedOut(after: timeout)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PasswordCommandError.commandFailed(status: process.terminationStatus)
        }
        guard let output = String(data: collected.data, encoding: .utf8) else {
            throw PasswordCommandError.unreadableOutput
        }
        // Trailing newline stripped the same way shell command substitution
        // does — most password helpers (`pass`, `op read`, …) end their
        // output with one.
        return output.trimmingCharacters(in: .newlines)
    }
}

/// Plain reference-type box for the background read queue's result. Only
/// ever written once, from the read queue, before `readDone` is signaled;
/// only ever read afterward, from the calling thread — the semaphore
/// establishes the happens-before edge, so a single unsynchronized property
/// is safe despite crossing queues.
private final class CollectedOutput: @unchecked Sendable {
    var data = Data()
}

/// Thrown by `PasswordCommandSecretSource`. Deliberately carries no trace of
/// the command's input or output — only what kind of failure happened (and,
/// for a timeout, the bound that was configured — a fixed setting, never
/// anything the command produced) — so a logged or printed error can never
/// disclose a secret typed into, or printed by, the helper command.
public enum PasswordCommandError: Error, Equatable, Sendable {
    case launchFailed
    case commandFailed(status: Int32)
    case unreadableOutput
    case timedOut(after: TimeInterval)
}

/// Reads a secret from a named environment variable — the CI path (M20).
/// Returns `nil` (never throws) when the variable is unset or empty;
/// `SecretResolver` already treats an empty value as "this source did not
/// deliver" and moves on to the next one.
public struct EnvironmentSecretSource: SecretSource {
    public let label: String
    private let variableName: String
    private let environment: [String: String]

    /// `environment` is injectable so tests never have to mutate the real
    /// process environment to exercise this.
    public init(
        variableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.variableName = variableName
        self.environment = environment
        self.label = "environment variable \(variableName)"
    }

    public func secret(for sessionID: UUID) throws -> String? {
        environment[variableName]
    }
}

/// Adapts a `SecretStore` (the Keychain in production) to `SecretSource`, so
/// the CLI's staged chain can fall through to it exactly like the App does —
/// the workstation default, last in line (M20).
public struct KeychainSecretSource: SecretSource {
    public let label = "keychain"
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func secret(for sessionID: UUID) throws -> String? {
        try store.password(for: sessionID)
    }
}

/// Builds the staged secret sources for a stored session, in the ORDER the
/// M20 design fixes as a security decision: an explicit `--password-command`
/// wins over everything; the environment variable is the CI path (the
/// S3-conventional `AWS_SECRET_ACCESS_KEY` for an S3 session, so existing
/// pipelines don't have to relearn a name; `MACSCP_PASSWORD` for SSH, the
/// name the M1 driver already used); the Keychain is the workstation
/// default, last in line. `SecretResolver` is what actually enforces "empty
/// means did not deliver" and "a throwing source aborts the whole attempt"
/// — this function only has to get the ORDER right; WHICH variable and
/// WHETHER a secret is needed at all are the backend's own answers since
/// M22/T10 (`secretEnvironmentVariable`, `requiresSecret`), so a fourth
/// protocol needs no edit here.
///
/// This used to live in the CLI target as `secretSources(options:kind:)`
/// (`Sources/MacSCPCLI/SessionConnecting.swift`) — a target with NO test
/// target. A future edit swapping two appends, or dropping the agent-auth
/// guard below, would have compiled and passed the entire suite without
/// this file's tests noticing. Moved here, alongside the source types, so
/// the order and the guard are both pinned.
///
/// An SSH agent-auth session needs no secret at all (M20 design): the agent
/// is an authentication METHOD, not a secret source. Consulting
/// `--password-command`/the environment/Keychain anyway would mean an
/// unrelated broken credential helper could fail an agent-auth connect that
/// never needed a secret in the first place — so this returns an EMPTY
/// chain for that case. `SecretResolver` walking an empty chain harmlessly
/// resolves to `nil`, so callers don't need a separate "does this session
/// need a secret" branch of their own.
public func secretSources(
    for session: StoredSession,
    passwordCommand: String?,
    keychainStore: any SecretStore = KeychainSecretStore()
) -> [any SecretSource] {
    let descriptor = BackendDescriptor.descriptor(for: session.kind)
    // Read through the BACKEND'S OWN adapter, never a shared one: SSH's
    // answer depends on `authKind`, a column S3 and WebDAV sessions do not
    // fill meaningfully, so asking the wrong adapter is how the agent-auth
    // guard would silently invert for them.
    guard descriptor.requiresSecret(descriptor.sessionValues(session)) else { return [] }

    var sources: [any SecretSource] = []
    if let command = passwordCommand {
        sources.append(PasswordCommandSecretSource(command: command))
    }
    if let variableName = descriptor.secretEnvironmentVariable {
        sources.append(EnvironmentSecretSource(variableName: variableName))
    }
    // Last resort, and the comfortable one at a workstation: the very same
    // keychain items the app writes. macOS asks the user for consent the
    // first time THIS binary reads an item the app created; answering
    // "Always Allow" puts the CLI on that item's ACL permanently, which is
    // what lets a later unattended run (cron, CI) read it without a prompt.
    // That standing grant is tied to the CLI's code signature, so the
    // shipped, Developer-ID-signed binary keeps it across invocations while
    // a locally rebuilt, ad-hoc-signed one has to be confirmed again.
    sources.append(KeychainSecretSource(store: keychainStore))
    return sources
}

/// The CLI's secret chain as the one source `ConnectionDiagnostics` takes:
/// the first source that answers non-empty wins, the same rule
/// `SecretResolver` applies.
///
/// `SecretResolver` itself hands back a `ResolvedSecret` and is done —
/// `ConnectionDiagnostics` wants a single, reusable `SecretSource` it can
/// hold for the run instead, so this re-applies "first non-empty wins" as a
/// `SecretSource` of its own, and remembers which of its sources actually
/// answered so `--verbose` can name it, the same thing
/// `ResolvedSecret.sourceLabel` is for on the connect path.
///
/// `secret(for:)` is called once per authenticating step against the SAME
/// session id — the dial, then S3 and WebDAV's own contribution probe
/// (`ConnectionDiagnostics`, `--scope complete`) — so without memoizing,
/// `--password-command` on those two backends spawns its helper command
/// TWICE for one diagnosis (final-branch review, 2026-09-04). The first
/// non-nil answer is cached in `answered`, keyed by session id, and every
/// later call for that id returns it without walking `sources` again.
/// Nothing is cached for a MISS (every source answered nil or empty): that
/// outcome is not "the answer is nothing", it is "nothing has answered
/// yet", and a later call is free to try the chain again.
public struct ChainedSecretSource: SecretSource {
    private let sources: [any SecretSource]
    private let answered: AnsweredLabel

    public init(_ sources: [any SecretSource]) {
        self.sources = sources
        self.answered = AnsweredLabel()
    }

    /// The answering source's label after a hit, `"none"` before one —
    /// `"none"` reads as a state no source has reached yet, not as the name
    /// of a source nobody wrote.
    public var label: String { answered.value }

    public func secret(for sessionID: UUID) throws -> String? {
        if let memoized = answered.memoizedSecret(for: sessionID) { return memoized }
        for source in sources {
            guard let value = try source.secret(for: sessionID), !value.isEmpty else { continue }
            answered.value = source.label
            answered.memoize(value, for: sessionID)
            return value
        }
        return nil
    }
}

/// The reference-type box behind `ChainedSecretSource.label` and its
/// per-session memoization.
///
/// Needed because `SecretSource.secret(for:)` is non-mutating — a struct's
/// own stored property cannot record which source answered from inside it,
/// so the record lives in this class instead, the same shape
/// `PasswordCommandSecretSource`'s `CollectedOutput` uses for the same
/// reason. Lock-protected rather than left `@unchecked Sendable` on trust
/// alone: unlike `CollectedOutput`'s single write-then-read handoff on a
/// semaphore, `ChainedSecretSource` is a public `Sendable` value a caller
/// could read `label` from on one thread while `secret(for:)` runs on
/// another.
private final class AnsweredLabel: @unchecked Sendable {
    private let lock = NSLock()
    private var current = "none"
    /// The first non-nil, non-empty secret this chain resolved, per session
    /// id. Keyed rather than a single slot so a chain that were ever (mis)
    /// used for more than one session id could not hand one id's answer
    /// back for another's.
    private var answers: [UUID: String] = [:]

    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func memoizedSecret(for sessionID: UUID) -> String? {
        lock.withLock { answers[sessionID] }
    }

    func memoize(_ secret: String, for sessionID: UUID) {
        lock.withLock { answers[sessionID] = secret }
    }
}
