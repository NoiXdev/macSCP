import Foundation

/// A public-key identity offered by a running ssh-agent, as reported by an
/// IDENTITIES_ANSWER response.
public struct AgentIdentity: Equatable, Sendable {
    /// The raw OpenSSH wire blob of the public key.
    public let publicKeyBlob: Data
    /// The comment associated with the key (often a path or "user@host").
    public let comment: String
    /// The key algorithm name, parsed from the first inner string of
    /// `publicKeyBlob` (e.g. "ssh-ed25519", "ssh-rsa").
    public let keyType: String
    /// The M3c-compatible fingerprint: SHA256 over the blob, Base64 without
    /// padding, prefixed "SHA256:".
    public let fingerprintSHA256: String

    public init(publicKeyBlob: Data, comment: String, keyType: String, fingerprintSHA256: String) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// Errors from the ssh-agent protocol layer.
public enum AgentError: Error, Equatable, Sendable {
    /// `SSH_AUTH_SOCK` is missing/dead, or the socket could not be connected.
    case socketUnavailable
    /// The agent is reachable but reports no identities. Defined here for
    /// T1's interface completeness; T2 is responsible for throwing it.
    case noIdentities
    /// The agent reported identities, but every one of them is a key type
    /// `AgentPrivateKeyFactory` doesn't offer through the client (M11e/T1
    /// point 3) — distinct from `.noIdentities` (an agent with nothing
    /// loaded at all) so the two conditions can be localized separately.
    case noUsableIdentities
    /// The agent answered with FAILURE (SSH_AGENT_FAILURE).
    case refused
    /// The response could not be parsed, or the transport misbehaved.
    case protocolError(reason: String)
}

/// Pure codec for the ssh-agent wire protocol (draft-miller). No I/O, no NIO
/// dependency — everything here is plain `Data` arithmetic so it stays
/// trivially unit-testable.
///
/// Wire format: a frame is `uint32 length` + body; the body is `byte type` +
/// a type-specific payload. Requests: REQUEST_IDENTITIES (11), SIGN_REQUEST
/// (13, payload = `string keyBlob`, `string data`, `uint32 flags`).
/// Responses: IDENTITIES_ANSWER (12, payload = `uint32 count` then that many
/// `string blob` + `string comment` pairs), SIGN_RESPONSE (14, payload =
/// `string signature`), FAILURE (5, no payload) which always maps to
/// `.refused`. Anything else — truncated data, an outer length that doesn't
/// match the actual byte count, an inner string overrunning the frame, or an
/// unexpected message type — maps to `.protocolError`.
public enum SSHAgentCodec {
    // MARK: Message type bytes

    private static let requestIdentitiesType: UInt8 = 11
    private static let identitiesAnswerType: UInt8 = 12
    private static let signRequestType: UInt8 = 13
    private static let signResponseType: UInt8 = 14
    private static let failureType: UInt8 = 5

    // MARK: Signature flag constants (SSH_AGENT_RSA_SHA2_*)

    public static let rsaSHA2_256: UInt32 = 2
    public static let rsaSHA2_512: UInt32 = 4

    // MARK: - Request builders

    public static func requestIdentitiesFrame() -> Data {
        frame(body: Data([requestIdentitiesType]))
    }

    public static func signRequestFrame(publicKeyBlob: Data, data: Data, flags: UInt32) -> Data {
        var body = Data([signRequestType])
        body.append(sshString(publicKeyBlob))
        body.append(sshString(data))
        body.append(uint32BE(flags))
        return frame(body: body)
    }

    // MARK: - Response parsers

    /// Parses an IDENTITIES_ANSWER frame into identities. Throws `.refused`
    /// on FAILURE, `.protocolError` on anything malformed.
    public static func parseIdentitiesAnswer(_ frame: Data) throws -> [AgentIdentity] {
        let body = try readFrame(frame)
        let bytes = Array(body)
        guard let type = bytes.first else {
            throw AgentError.protocolError(reason: "empty response body")
        }
        if type == failureType {
            throw AgentError.refused
        }
        guard type == identitiesAnswerType else {
            throw AgentError.protocolError(reason: "unexpected message type \(type)")
        }

        var offset = 1
        let count = try readUInt32(bytes, at: &offset)
        // M-1: no `reserveCapacity(Int(count))` -- `count` is untrusted
        // (attacker- or bug-controlled) wire data; a declared count near
        // UInt32.max would request a multi-hundred-GB allocation and trap.
        // Each loop iteration already bounds-checks against the actual
        // frame length via `readSSHString`, so a bogus count simply throws
        // `.protocolError` on the first read past the real payload.
        var identities: [AgentIdentity] = []
        for _ in 0..<count {
            let blobBytes = try readSSHString(bytes, at: &offset)
            let commentBytes = try readSSHString(bytes, at: &offset)
            let comment = String(decoding: commentBytes, as: UTF8.self)
            let keyType = try parseKeyType(fromBlob: blobBytes)
            let blob = Data(blobBytes)
            identities.append(AgentIdentity(
                publicKeyBlob: blob,
                comment: comment,
                keyType: keyType,
                fingerprintSHA256: fingerprint(ofBlob: blob)))
        }
        return identities
    }

    /// Parses a SIGN_RESPONSE frame, returning the raw `string signature`
    /// payload (algorithm name + signature blob, still SSH-encoded).
    /// Throws `.refused` on FAILURE, `.protocolError` on anything malformed.
    public static func parseSignResponse(_ frame: Data) throws -> Data {
        let body = try readFrame(frame)
        let bytes = Array(body)
        guard let type = bytes.first else {
            throw AgentError.protocolError(reason: "empty response body")
        }
        if type == failureType {
            throw AgentError.refused
        }
        guard type == signResponseType else {
            throw AgentError.protocolError(reason: "unexpected message type \(type)")
        }

        var offset = 1
        let signature = try readSSHString(bytes, at: &offset)
        return Data(signature)
    }

    // MARK: - Framing helper

    /// Strips and validates the outer `uint32 length` prefix, returning the
    /// body. Throws `.protocolError` if the frame is too short to contain a
    /// length prefix, or if the declared length doesn't match the number of
    /// bytes actually present.
    public static func readFrame(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 4 else {
            throw AgentError.protocolError(reason: "frame too short for a length prefix")
        }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let body = bytes[4...]
        guard body.count == Int(length) else {
            throw AgentError.protocolError(reason: "declared frame length does not match body")
        }
        return Data(body)
    }

    // MARK: - Private byte-level helpers

    private static func frame(body: Data) -> Data {
        var result = uint32BE(UInt32(body.count))
        result.append(body)
        return result
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }

    private static func sshString(_ data: Data) -> Data {
        var result = uint32BE(UInt32(data.count))
        result.append(data)
        return result
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: inout Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw AgentError.protocolError(reason: "truncated uint32")
        }
        let value = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    private static func readSSHString(_ bytes: [UInt8], at offset: inout Int) throws -> [UInt8] {
        let length = try readUInt32(bytes, at: &offset)
        guard offset + Int(length) <= bytes.count else {
            throw AgentError.protocolError(reason: "truncated string")
        }
        let result = Array(bytes[offset..<(offset + Int(length))])
        offset += Int(length)
        return result
    }

    /// Extracts the algorithm name, which is the first inner `string` field
    /// of any OpenSSH public-key blob (e.g. "ssh-ed25519", "ssh-rsa").
    private static func parseKeyType(fromBlob blob: [UInt8]) throws -> String {
        var offset = 0
        let typeBytes = try readSSHString(blob, at: &offset)
        return String(decoding: typeBytes, as: UTF8.self)
    }

    /// Reuses M3c's fingerprint derivation (`HostKeyFingerprint`): SHA256
    /// over the blob, Base64 without padding, "SHA256:" prefix. Same target,
    /// so the helper is directly accessible — no need to mirror it locally.
    private static func fingerprint(ofBlob blob: Data) -> String {
        HostKeyFingerprint.sha256(ofKeyBlobBase64: blob.base64EncodedString()) ?? "SHA256:?"
    }
}
