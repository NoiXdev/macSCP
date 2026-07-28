import Citadel
import Dispatch
import Foundation
import NIOCore
import NIOSSH

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
    /// OpenSSH's key-type table treats `rsa-sha2-256`/`rsa-sha2-512` as
    /// valid (if normally sig-only) names for `KEY_RSA`, and RSA blob bodies
    /// (`mpint e`, `mpint n`) are identical regardless of which name tags
    /// them, so a compliant server is expected to still parse the blob as
    /// the same RSA key and match it against `authorized_keys` by key
    /// material, not by wire tag. This is exactly the risk the gated
    /// `agentAuthConnectsRSA` integration test proves against a real
    /// OpenSSH `sshd` (see the Task 2 report for the observed result).
    struct RSASha512: AgentSigningAlgorithm {
        static let name = "rsa-sha2-512"
        static let signFlags: UInt32 = SSHAgentCodec.rsaSHA2_512
    }
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

    init(identity: AgentIdentity, client: SSHAgentClient) {
        self.identity = identity
        self.client = client
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
        let semaphore = DispatchSemaphore(value: 0)
        let box = SignatureResultBox()
        Task { [client, identity] in
            do {
                let raw = try await client.sign(
                    publicKeyBlob: identity.publicKeyBlob, data: payload, flags: Algorithm.signFlags)
                box.result = .success(raw)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else {
            throw AgentError.protocolError(reason: "agent signature task did not complete")
        }
        let raw = try result.get()
        return AgentSignature<Algorithm>(rawAgentResponse: raw)
    }

    private final class SignatureResultBox: @unchecked Sendable {
        var result: Result<Data, Error>?
    }
}

/// Maps an `AgentIdentity`'s reported key type to the matching
/// `AgentSigningAlgorithm` marker and constructs the offered
/// `NIOSSHPrivateKey`. Returns `nil` for an algorithm macSCP does not (yet)
/// offer through the agent — the caller skips that identity rather than
/// crashing on an unhandled static requirement (see `AgentAlgorithm`).
enum AgentPrivateKeyFactory {
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
            let offer = NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey)))
            nextChallengePromise.succeed(offer)
            return
        }
        nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
    }
}
