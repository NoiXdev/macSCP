import Foundation
import Testing

// A test-owned ssh-agent, and the three things a gated test does with one.
//
// These lived as private members of `CitadelFileSystemIntegrationTests` until
// 2026-09-02, when `GoServerRSAIntegrationTests` needed the same spawned agent
// to offer an RSA identity to the rig's Go-based server. The bodies are
// unchanged by the move; only `private` and one level of indentation are gone.

struct SpawnedAgent {
    let socketPath: String
    let pid: Int32
}

struct AgentSpawnError: Error {
    let detail: String
}

struct AskPassHelperError: Error {
    let detail: String
}

/// Starts a BRAND-NEW `ssh-agent -s` process this test owns exclusively
/// (parsed from its own stdout) — never the maintainer's real agent.
/// Killed in the caller's `defer`.
func spawnAgent() throws -> SpawnedAgent {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
    process.arguments = ["-s"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AgentSpawnError(detail: "ssh-agent -s exited \(process.terminationStatus)")
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    func value(named name: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("\(name)=") {
            return String(line.dropFirst(name.count + 1).prefix { $0 != ";" })
        }
        return nil
    }
    guard let socketPath = value(named: "SSH_AUTH_SOCK"),
          let pidString = value(named: "SSH_AGENT_PID"), let pid = Int32(pidString)
    else {
        throw AgentSpawnError(detail: "could not parse ssh-agent -s output: \(output)")
    }
    return SpawnedAgent(socketPath: socketPath, pid: pid)
}

/// Terminates the spawned agent process (teardown — never touches the
/// user's own agent, only the PID this test itself started).
func killAgent(_ agent: SpawnedAgent) {
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/bin/kill")
    kill.arguments = ["-TERM", String(agent.pid)]
    try? kill.run()
    kill.waitUntilExit()
    // ssh-agent removes its own socket on a TERM it receives while still
    // alive, so this is a no-op on the common path. It matters when TERM
    // never reached a live agent (the test process died first, or the
    // agent was killed hard) and the socket file is left behind in the
    // shared ~/.ssh/agent/ — remove the FILE only, never the directory,
    // which belongs to every agent on the machine.
    try? FileManager.default.removeItem(atPath: agent.socketPath)
}

/// Adds a key to the spawned agent. For an encrypted key, `passphrase` is
/// handed to ssh-add through an SSH_ASKPASS helper the test writes into
/// `dir` and removes — never through argv, never through stdin of the test
/// process. The passphrase is never interpolated into shell syntax: it is
/// written raw to a 0600 secret file, and the 0700 helper script just
/// `cat`s that file, so a passphrase containing a quote or any other
/// shell metacharacter cannot break or inject into the script. Each file
/// is created with its final permissions in one `createFile` call — never
/// written world/group-readable and then chmod'd — so there is no window
/// where the plaintext passphrase sits at default permissions. `defer`
/// removal is armed (`secretFile`/`helperScript` assigned) BEFORE each
/// `createFile` call, so even a `createFile` that reports failure still
/// gets any partially-written file cleaned up; `removeItem` on a path
/// that was never created is a harmless `try?`.
func addKey(atPath keyPath: String, to agent: SpawnedAgent,
                    passphrase: String? = nil, helperDirectory: URL? = nil) throws {
    let add = Process()
    add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
    add.arguments = [keyPath]
    var environment = [
        "SSH_AUTH_SOCK": agent.socketPath,
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]
    var helperScript: URL?
    var secretFile: URL?
    defer {
        if let helperScript { try? FileManager.default.removeItem(at: helperScript) }
        if let secretFile { try? FileManager.default.removeItem(at: secretFile) }
    }
    if let passphrase, let helperDirectory {
        let secret = helperDirectory.appendingPathComponent("askpass-secret")
        secretFile = secret
        let secretCreated = FileManager.default.createFile(
            atPath: secret.path(percentEncoded: false), contents: Data(passphrase.utf8),
            attributes: [.posixPermissions: 0o600])
        #expect(secretCreated)
        guard secretCreated else {
            throw AskPassHelperError(detail: "could not create askpass secret file at \(secret.path(percentEncoded: false))")
        }

        let script = helperDirectory.appendingPathComponent("askpass.sh")
        helperScript = script
        let scriptContents = "#!/bin/sh\ncat \"\(secret.path(percentEncoded: false))\"\n"
        let scriptCreated = FileManager.default.createFile(
            atPath: script.path(percentEncoded: false), contents: Data(scriptContents.utf8),
            attributes: [.posixPermissions: 0o700])
        #expect(scriptCreated)
        guard scriptCreated else {
            throw AskPassHelperError(detail: "could not create askpass script at \(script.path(percentEncoded: false))")
        }

        environment["SSH_ASKPASS"] = script.path(percentEncoded: false)
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = ":0"
    }
    add.environment = environment
    try add.run()
    add.waitUntilExit()
    #expect(add.terminationStatus == 0)
}

/// Points THIS test process's `SSH_AUTH_SOCK` at `agent` for the
/// duration of `body`, restoring whatever was there before. `.agent`
/// auth reads `SSH_AUTH_SOCK` from the process environment exactly
/// once per `connect()` (see `CitadelFileSystem.AgentAuthContext`), so
/// this is how the gated tests make macSCP talk to their own spawned
/// agent instead of the maintainer's.
///
/// `AgentEnvLock` (M11e/T2, see its doc comment) serializes this against
/// every OTHER suite that mutates the same process-global `SSH_AUTH_SOCK`
/// — a suite's own `.serialized` only protects against interleaving within
/// itself. Two suites reach this function (`CitadelFileSystemIntegrationTests`
/// and `GoServerRSAIntegrationTests`); two more mutate the variable under
/// the same lock without it (`AgentAuthTests`, `ConnectFailureSecrecyTests`)
/// — four suites on one lock, counted 2026-09-02 after a review found the
/// first count one short.
@discardableResult
func withAgentEnv<T>(
    _ agent: SpawnedAgent, _ body: () async throws -> T
) async rethrows -> T {
    try await AgentEnvLock.shared.run {
        let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", agent.socketPath, 1)
        defer {
            if let original {
                setenv("SSH_AUTH_SOCK", original, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        return try await body()
    }
}
