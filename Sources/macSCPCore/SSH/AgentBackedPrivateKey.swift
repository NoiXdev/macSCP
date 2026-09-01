import Citadel
import Dispatch
import Foundation
import NIOCore
// `@preconcurrency` for one type: `NIOSSHUserAuthenticationOffer`, which the
// auth delegate at the bottom of this file hands to an `EventLoopPromise`.
// Apple has declared that type `Sendable` since 2023 — but the SSH transport
// reaches this app through a third-party fork of swift-nio-ssh that branched
// in 2022 and never took the adoption (measured in
// docs/superpowers/specs/2026-08-20-backlog-dependencies.md). So this is
// not a gap in our code or in Apple's; it is a merge the fork never
// received, and there is nothing to conform on our side.
//
// What the suppression costs: the compiler stops diagnosing
// `Sendable`-related crossings involving NIOSSH types in this file. Besides
// the offer, that is the `NIOSSHPrivateKey` the offer wraps and the
// `EventLoopPromise` it travels on — all three built here and handed
// straight to NIOSSH, never retained on this side.
@preconcurrency import NIOSSH

/// Identifies the SSH wire algorithm name an agent-backed key signs as.
///
/// `NIOSSHPublicKeyProtocol.publicKeyPrefix`/`NIOSSHSignatureProtocol.signaturePrefix`
/// are `static var` requirements (swift-nio-ssh `CustomKeys.swift:46-64` /
/// `:23-38`) — i.e. fixed PER SWIFT TYPE, not per instance. An ssh-agent can
/// report several different key algorithms, so a single generic
/// `AgentBackedPrivateKey`/`AgentBackedPublicKey`/`AgentSignature` trio is
/// parameterized over this marker; one marker type exists per algorithm
/// family macSCP offers through the agent. `signFlags` is the
/// `SSH_AGENT_RSA_SHA2_*` value sent with the agent's SIGN_REQUEST (0 for
/// non-RSA algorithms).
protocol AgentSigningAlgorithm {
    static var name: String { get }
    static var signFlags: UInt32 { get }
}

/// The closed set of algorithms macSCP offers through the agent — the
/// standard identities `ssh-keygen`/OpenSSH ssh-agent produce. An identity
/// reporting anything else (e.g. a certificate or a security-key resident
/// credential) is simply skipped when offered (see `AgentPrivateKeyFactory`)
/// rather than crashing on an unhandled static requirement.
enum AgentAlgorithm {
    struct Ed25519: AgentSigningAlgorithm {
        static let name = "ssh-ed25519"
        static let signFlags: UInt32 = 0
    }

    struct ECDSAP256: AgentSigningAlgorithm {
        static let name = "ecdsa-sha2-nistp256"
        static let signFlags: UInt32 = 0
    }

    struct ECDSAP384: AgentSigningAlgorithm {
        static let name = "ecdsa-sha2-nistp384"
        static let signFlags: UInt32 = 0
    }

    struct ECDSAP521: AgentSigningAlgorithm {
        static let name = "ecdsa-sha2-nistp521"
        static let signFlags: UInt32 = 0
    }

    /// THE RSA RISK (M10d Task 2, brief point 2): an `ssh-rsa`-blob identity
    /// must authenticate using the `rsa-sha2-512` signature algorithm
    /// (RFC 8332), not legacy SHA-1. Per RFC 8332 the "public key algorithm
    /// name" field in the userauth request and the signature's own format
    /// tag become `rsa-sha2-512`, while the PUBLIC KEY BLOB's embedded type
    /// tag is supposed to stay `ssh-rsa` — those are three independently
    /// choosable strings in the protocol.
    ///
    /// swift-nio-ssh's `.custom` write path does NOT allow that
    /// independence for a single key value: `UserAuthSignablePayload.init`
    /// (`User Authentication/UserAuthSignablePayload.swift:48-51`) writes
    /// the outer algorithm-name field as `publicKey.keyPrefix`, THEN writes
    /// the blob via `buffer.writeSSHHostKey(publicKey)`
    /// (`Keys And Signatures/NIOSSHPublicKey.swift:400-402`), whose `.custom`
    /// case ALSO writes `key.publicKeyPrefix` as the blob's own leading type
    /// string before calling `key.write(to:)`. The client-side wire writer
    /// `writeUserAuthRequestMessage` (`SSHMessages.swift:1307-1310`)
    /// duplicates the same coupling: `self.writeSSHString(key.keyPrefix)`
    /// for the outer field, then `writeSSHHostKey(key)` for the blob — both
    /// driven by the exact same `NIOSSHPublicKeyProtocol.publicKeyPrefix`.
    /// There is no unforked hook to make the blob's embedded tag diverge
    /// from the outer algorithm name for a custom key.
    ///
    /// Given that constraint, this marker's `name` is `rsa-sha2-512` and is
    /// used for BOTH fields (outer algorithm name AND the blob's own type
    /// tag) plus the signature tag — internally self-consistent (all three
    /// agree, which is what real servers actually check pairwise), but the
    /// blob's wire tag is `rsa-sha2-512` rather than the RFC's `ssh-rsa`.
    ///
    /// KNOWN, VERIFIED INCOMPATIBILITY (T2 review, not hypothetical):
    /// OpenSSH's key-type table treats `rsa-sha2-256`/`rsa-sha2-512` as
    /// valid (if normally sig-only) names for `KEY_RSA` and matches
    /// `authorized_keys` by parsed key material rather than by wire tag —
    /// so a real OpenSSH `sshd` accepts this blob (proven live by the gated
    /// `agentAuthConnectsRSA` integration test against the Docker rig).
    /// Go's `golang.org/x/crypto/ssh`, however, parses the public-key blob's
    /// leading string strictly as a KEY FORMAT, not merely a signature
    /// algorithm, and does not recognize `rsa-sha2-512` there. Verified
    /// directly against `x/crypto/ssh` (`ParsePublicKey` on a blob tagged
    /// `rsa-sha2-512`), it rejects with:
    ///
    /// ```
    /// ssh: signature algorithm "rsa-sha2-512" isn't a key format; key is
    /// malformed and should be re-encoded with type "ssh-rsa"
    /// ```
    ///
    /// Any server built on that library — Gitea, Forgejo, Gogs,
    /// `gitlab-sshd`, SFTPGo, and others — therefore refuses an RSA-backed
    /// agent identity through macSCP, even though the identical key works
    /// fine over OpenSSH `sshd`. ed25519 and ECDSA identities are NOT
    /// affected: for those algorithms the blob's embedded type tag and the
    /// signature/algorithm name are the SAME string already (e.g.
    /// `ssh-ed25519`), so there is no three-way divergence for swift-nio-ssh
    /// to collapse in the first place — this incompatibility is specific to
    /// RSA's `rsa-sha2-*` vs. `ssh-rsa` split. The actual fix requires
    /// upstream swift-nio-ssh to let a `.custom` key's blob-embedded type
    /// tag diverge from its signature/algorithm name (i.e. stop deriving
    /// both from the single `publicKeyPrefix`/`keyPrefix` static) — out of
    /// scope for macSCP itself; tracked as a known limitation, not patched
    /// here.
    struct RSASha512: AgentSigningAlgorithm {
        static let name = "rsa-sha2-512"
        static let signFlags: UInt32 = SSHAgentCodec.rsaSHA2_512
    }

    /// The algorithm names macSCP is willing to repeat back in an error
    /// message: the ones the markers above offer, plus the two an RSA agent
    /// realistically substitutes for `rsa-sha2-512` when it ignores the
    /// SHA2 flags. Returns `nil` for anything else.
    ///
    /// The point is not to validate the name — the caller has already
    /// decided it is wrong — but to keep the *product's* error text made of
    /// the product's own strings. What the agent reports is decoded from
    /// arbitrary bytes of its answer, so echoing it verbatim would let the
    /// agent write into a dialog.
    static func recognizedName(_ name: String) -> String? {
        knownNames.contains(name) ? name : nil
    }

    private static let knownNames: Set<String> = [
        Ed25519.name, ECDSAP256.name, ECDSAP384.name, ECDSAP521.name,
        RSASha512.name, "ssh-rsa", "rsa-sha2-256",
    ]
}

/// Byte-level helpers shared by `AgentBackedPublicKey`/`AgentSignature`.
enum AgentWireFormat {
    /// Strips the leading `string` field (an algorithm/type name) from an
    /// OpenSSH wire value, returning everything after it VERBATIM.
    ///
    /// Both the identity blob ssh-agent reports (`string type` + key
    /// material) and the SIGN_RESPONSE payload `SSHAgentClient.sign`
    /// returns (`string algorithm` + `string signature-blob`) share this
    /// `string name` + `<rest>` shape. NIOSSH's own `writeSSHHostKey`/
    /// `writeSSHSignature` already write that leading name themselves (from
    /// `publicKeyPrefix`/`signaturePrefix`) before calling into
    /// `write(to:)` — re-emitting it there would duplicate the tag on the
    /// wire, so only the suffix is kept.
    static func stripLeadingSSHString(from data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return Data() }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let start = 4 + Int(length)
        guard start <= bytes.count else { return Data() }
        return Data(bytes[start...])
    }

    /// Reads (without consuming) the leading `string` field itself, decoded
    /// as UTF-8 — the algorithm/type name `stripLeadingSSHString` discards.
    /// `nil` for malformed input (too short, or a declared length that
    /// overruns the buffer). Used by M-4's SIGN_RESPONSE algorithm check.
    static func leadingSSHString(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let start = 4
        let end = start + Int(length)
        guard end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}

/// A public key wrapping one ssh-agent identity, re-emitting the agent's own
/// blob VERBATIM (minus the leading type-string NIOSSH re-adds itself from
/// `publicKeyPrefix`). Never parsed from the wire — this type only ever
/// appears in OUTGOING client user-auth offers.
struct AgentBackedPublicKey<Algorithm: AgentSigningAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }

    private let identity: AgentIdentity

    init(identity: AgentIdentity) {
        self.identity = identity
    }

    var rawRepresentation: Data { identity.publicKeyBlob }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(AgentWireFormat.stripLeadingSSHString(from: identity.publicKeyBlob))
    }

    /// Never invoked: macSCP only ever OFFERS this key for outgoing
    /// client user-auth, it never verifies an incoming signature against it.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentBackedPublicKey<Algorithm> {
        throw AgentError.protocolError(reason: "agent-backed keys are never parsed from the wire")
    }
}

/// A signature produced by the agent, re-emitting the agent's own signature
/// bytes VERBATIM (minus the leading algorithm-name string NIOSSH re-adds
/// itself from `signaturePrefix`). Never parsed from the wire.
struct AgentSignature<Algorithm: AgentSigningAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }

    let rawRepresentation: Data

    /// - Parameter rawAgentResponse: the raw payload `SSHAgentClient.sign`
    ///   returns (`string algorithm` + `string signature-blob`, still
    ///   SSH-encoded). Only the algorithm-name string is stripped; what
    ///   remains is itself a complete, already length-prefixed SSH string
    ///   and is kept exactly as received.
    init(rawAgentResponse: Data) {
        self.rawRepresentation = AgentWireFormat.stripLeadingSSHString(from: rawAgentResponse)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentSignature<Algorithm> {
        throw AgentError.protocolError(reason: "agent-backed signatures are never parsed from the wire")
    }
}

/// A private key that never holds key material itself — every signature is
/// forwarded to the ssh-agent over `client`. One instance per offered
/// identity (brief point 2: the delegate offers each identity once).
final class AgentBackedPrivateKey<Algorithm: AgentSigningAlgorithm>: NIOSSHPrivateKeyProtocol {
    /// Unused for client user-auth offers: `NIOSSHPrivateKeyProtocol.keyPrefix`
    /// is only consulted for `NIOSSHPrivateKey.hostKeyAlgorithms` (host-key
    /// advertisement during key exchange — `NIOSSHPrivateKey.swift:61-78`),
    /// never for the outgoing offers this type is used for.
    static var keyPrefix: String { Algorithm.name }

    private let identity: AgentIdentity
    private let client: SSHAgentClient
    /// Wall-clock ceiling on the semaphore wait in `signature(for:)` below —
    /// the second line of defense behind `NIOUnixSocketAgentTransport`'s own
    /// 10s response deadline. That transport-level deadline only fires while
    /// its round-trip `Task` is actually running; it does nothing for the
    /// (rarer, but real) case where the `Task` spawned below never gets to
    /// complete at all — e.g. its event loop was torn down mid-flight — in
    /// which case `box.result` would stay `nil` forever and the semaphore
    /// would never signal. Defaults to 15s; tests inject a short value so a
    /// timeout test runs in milliseconds, not 15 seconds.
    private let signTimeout: TimeInterval

    init(identity: AgentIdentity, client: SSHAgentClient, signTimeout: TimeInterval = 15) {
        self.identity = identity
        self.client = client
        self.signTimeout = signTimeout
    }

    var publicKey: NIOSSHPublicKeyProtocol {
        AgentBackedPublicKey<Algorithm>(identity: identity)
    }

    /// Bridges NIOSSH's SYNCHRONOUS signing hook (called from
    /// `SSHMessage.UserAuthRequestMessage.init`, on whichever thread is
    /// driving the SSH client's own event loop) to the ASYNC agent round
    /// trip. Blocking that thread on a semaphore while a separate `Task`
    /// awaits the agent (which itself runs its own, independent NIO event
    /// loop — see `SSHAgentClient`/`NIOUnixSocketAgentTransport`) does not
    /// deadlock: the two event loops are unrelated.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let payload = Data(data)
        // Read here rather than inside the task: naming `Algorithm.signFlags`
        // in there would capture the METATYPE `Algorithm.Type`, and a
        // metatype of an unconstrained generic parameter is not `Sendable`.
        // The value is a `UInt32` constant per marker type, so reading it on
        // this side is the same number and captures nothing.
        let signFlags = Algorithm.signFlags
        let semaphore = DispatchSemaphore(value: 0)
        let box = SignatureResultBox()
        Task { [client, identity] in
            do {
                let raw = try await client.sign(
                    publicKeyBlob: identity.publicKeyBlob, data: payload, flags: signFlags)
                box.result = .success(raw)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + signTimeout) == .success else {
            throw AgentError.protocolError(reason: "agent sign timed out")
        }
        guard let result = box.result else {
            throw AgentError.protocolError(reason: "agent signature task did not complete")
        }
        let raw = try result.get()
        // M-4: the agent's SIGN_RESPONSE self-reports the algorithm it
        // actually signed with — trust nothing about it until that name is
        // verified against what we asked for. An agent that ignores the
        // SHA2 flags (or otherwise misbehaves) could re-emit a legacy SHA-1
        // signature while still tagging it `rsa-sha2-512`; the server would
        // then be asked to verify a signature under an algorithm name that
        // does not match how it was actually produced.
        guard let reportedAlgorithm = AgentWireFormat.leadingSSHString(from: raw) else {
            throw AgentError.protocolError(reason: "agent SIGN_RESPONSE is missing its algorithm name")
        }
        guard reportedAlgorithm == Algorithm.name else {
            // The reported name is echoed back only when it is one macSCP
            // already names itself. `leadingSSHString` decodes whatever
            // bytes the agent put in that field — any length the frame
            // allows, any content — and this `reason` ends up in the
            // failed-connect text. The agent holds the user's private keys
            // and is therefore trusted far more than a remote server, but
            // "trusted enough to hold keys" is not "trusted to write the
            // product's error messages", and a buggy or hostile agent is
            // exactly the case this check exists to catch in the first
            // place.
            //
            // Recognized names are the interesting ones anyway: the
            // realistic failure is an agent that ignores the SHA2 flags and
            // signs with a legacy algorithm, and naming which one is the
            // whole diagnosis.
            let reported = AgentAlgorithm.recognizedName(reportedAlgorithm)
                ?? "an unrecognized algorithm name"
            throw AgentError.protocolError(
                reason: "agent signature algorithm mismatch: expected \(Algorithm.name), got \(reported)")
        }
        return AgentSignature<Algorithm>(rawAgentResponse: raw)
    }
}

/// Carries the agent's answer out of the round-trip task and back to the
/// thread waiting on the semaphore in `signature(for:)`.
///
/// Deliberately NOT nested inside `AgentBackedPrivateKey`: a nested type is
/// generic over `Algorithm` too, so merely naming it inside the task would
/// capture the metatype `Algorithm.Type` — which is not `Sendable` for an
/// unconstrained generic parameter. At file scope the type is plain, and the
/// task captures nothing generic.
///
/// `@unchecked Sendable` because the box is written by the task and read by
/// the waiting thread. Why there is no race: the semaphore orders the two.
/// One box is made per `signature(for:)` call and never leaves it; the task
/// writes `result` and only then signals, and the waiter reads it only after
/// a successful wait — so the write happens-before the read, and no other
/// code holds a reference.
///
/// What would break it: reading `result` on the timeout path, where the
/// signal never came. `signature(for:)` throws there instead of reading.
private final class SignatureResultBox: @unchecked Sendable {
    var result: Result<Data, Error>?
}

/// Maps an `AgentIdentity`'s reported key type to the matching
/// `AgentSigningAlgorithm` marker and constructs the offered
/// `NIOSSHPrivateKey`. Returns `nil` for an algorithm macSCP does not (yet)
/// offer through the agent — the caller skips that identity rather than
/// crashing on an unhandled static requirement (see `AgentAlgorithm`).
enum AgentPrivateKeyFactory {
    /// The exact same closed set `privateKey(for:client:)` switches over —
    /// kept as one literal list so the two never drift apart. M-1: lets
    /// `CitadelFileSystem.connectHop` pre-filter identities of an
    /// unsupported type BEFORE spending a whole reconnect attempt on one,
    /// instead of relying on `AgentAuthDelegate` to discover the same thing
    /// mid-loop by returning `nil` here.
    private static let supportedKeyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    static func supports(keyType: String) -> Bool {
        supportedKeyTypes.contains(keyType)
    }

    static func privateKey(for identity: AgentIdentity, client: SSHAgentClient) -> NIOSSHPrivateKey? {
        switch identity.keyType {
        case "ssh-ed25519":
            return NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(identity: identity, client: client))
        case "ecdsa-sha2-nistp256":
            return NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP256>(identity: identity, client: client))
        case "ecdsa-sha2-nistp384":
            return NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP384>(identity: identity, client: client))
        case "ecdsa-sha2-nistp521":
            return NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP521>(identity: identity, client: client))
        case "ssh-rsa":
            return NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.RSASha512>(identity: identity, client: client))
        default:
            return nil
        }
    }
}

/// Offers ssh-agent identities to the server one at a time, in order.
///
/// Citadel's `SSHAuthenticationMethod.custom(_:)` (`SSHAuthenticationMethod.swift:78-119`)
/// forwards to the wrapped delegate exactly ONCE per connection attempt: its
/// `implementations` array holds a single `.custom(delegate)` entry that
/// `removeFirst()` permanently consumes on the first call — a SECOND
/// server-driven `nextAuthenticationType` call on that SAME wrapper (after
/// the first offer is rejected) fails immediately with
/// `allAuthenticationOptionsFailed` WITHOUT ever reaching this delegate
/// again. Offering multiple identities therefore requires multiple FULL
/// reconnects, each wrapping a FRESH `SSHAuthenticationMethod.custom(...)`
/// around this SAME `AgentAuthDelegate` instance so its internal cursor
/// (`remaining`) advances across them — see
/// `CitadelFileSystem.connectHop(...)`, which drives that outer loop.
/// Within ONE call to `nextAuthenticationType` this still behaves like a
/// normal `NIOSSHClientUserAuthenticationDelegate`, so the identity-order/
/// exhaustion behavior itself is directly unit-testable.
final class AgentAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remaining: [AgentIdentity]
    private let client: SSHAgentClient

    init(username: String, identities: [AgentIdentity], client: SSHAgentClient) {
        self.username = username
        self.remaining = identities
        self.client = client
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !remaining.isEmpty {
            let identity = remaining.removeFirst()
            guard let privateKey = AgentPrivateKeyFactory.privateKey(for: identity, client: client) else {
                continue
            }
            // The crossing this file's `@preconcurrency import NIOSSH`
            // covers: the offer is a non-`Sendable` fork type going onto a
            // promise. Why there is no race: the offer is built inside this
            // call, is not stored anywhere and is not referenced after the
            // `succeed`, so from the handover on NIOSSH is its only holder —
            // and NIOSSH resolves the promise on the event loop that asked
            // for it, which is also the loop this method runs on.
            let offer = NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey)))
            nextChallengePromise.succeed(offer)
            return
        }
        nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
    }
}
