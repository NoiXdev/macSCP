import Foundation
import SwiftASN1

/// The DER helpers the three key structures below share.
///
/// Every one of them turns a `SwiftASN1` failure into
/// `DecodeError.notReadable(.malformed)`: swift-asn1's own errors name
/// offsets and tag numbers, which is a description of the file, and the
/// caller's contract is that a payload is one of the decoder's own constants.
enum PEMDER {
    typealias Failure = PEMPrivateKeyDecoder.DecodeError

    static func parse(_ der: Data) throws(Failure) -> ASN1Node {
        do {
            return try DER.parse(Array(der))
        } catch {
            throw Failure.notReadable(.malformed)
        }
    }

    static func children(_ node: ASN1Node) throws(Failure) -> [ASN1Node] {
        guard case .constructed(let nodes) = node.content else {
            throw Failure.notReadable(.malformed)
        }
        return Array(nodes)
    }

    static func content(_ node: ASN1Node) throws(Failure) -> ArraySlice<UInt8> {
        guard case .primitive(let bytes) = node.content else {
            throw Failure.notReadable(.malformed)
        }
        return bytes
    }

    static func oid(_ node: ASN1Node) throws(Failure) -> ASN1ObjectIdentifier {
        do {
            return try ASN1ObjectIdentifier(derEncoded: node)
        } catch {
            throw Failure.notReadable(.malformed)
        }
    }

    static func octets(_ node: ASN1Node) throws(Failure) -> Data {
        do {
            return Data(try ASN1OctetString(derEncoded: node).bytes)
        } catch {
            throw Failure.notReadable(.malformed)
        }
    }

    /// An INTEGER small enough to be a version or an iteration count.
    static func integer(_ node: ASN1Node) throws(Failure) -> Int {
        do {
            return try Int(derEncoded: node)
        } catch {
            throw Failure.notReadable(.malformed)
        }
    }

    /// An INTEGER's big-endian magnitude, without the leading `0x00` DER
    /// writes to keep a high top bit from reading as a negative number.
    static func magnitude(_ node: ASN1Node) throws(Failure) -> Data {
        guard node.identifier == .integer else { throw Failure.notReadable(.malformed) }
        var bytes = Array(try content(node))
        while bytes.count > 1, bytes.first == 0x00 { bytes.removeFirst() }
        return Data(bytes)
    }

    /// The single node inside an explicit context-specific tag, e.g. SEC1's
    /// `[0] parameters`.
    static func explicitlyTagged(_ nodes: [ASN1Node], number: UInt) throws(Failure) -> ASN1Node? {
        for node in nodes where node.identifier.tagClass == .contextSpecific
            && node.identifier.tagNumber == number {
            guard let inner = try children(node).first else { throw Failure.notReadable(.malformed) }
            return inner
        }
        return nil
    }

    static let idEcPublicKey: ASN1ObjectIdentifier = [1, 2, 840, 10_045, 2, 1]
    static let rsaEncryption: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 1, 1]
    static let idEd25519: ASN1ObjectIdentifier = [1, 3, 101, 112]
    static let idDSA: ASN1ObjectIdentifier = [1, 2, 840, 10_040, 4, 1]
    static let primeField: ASN1ObjectIdentifier = [1, 2, 840, 10_045, 1, 1]
    static let secp256r1: ASN1ObjectIdentifier = [1, 2, 840, 10_045, 3, 1, 7]
    static let secp384r1: ASN1ObjectIdentifier = [1, 3, 132, 0, 34]
    static let secp521r1: ASN1ObjectIdentifier = [1, 3, 132, 0, 35]
}

extension PEMPrivateKeyDecoder.Curve {
    /// The scalar's fixed length, and the length a decoded scalar is padded
    /// to: 32, 48, 66 — what `P256/P384/P521.Signing.PrivateKey
    /// (rawRepresentation:)` take.
    var scalarByteCount: Int {
        switch self {
        case .p256: return 32
        case .p384: return 48
        case .p521: return 66
        }
    }

    /// The field prime, big-endian. A SEC1 key written with EXPLICIT domain
    /// parameters — which is what ssh-keygen writes (design table) — names no
    /// curve, so the prime is the identification.
    var fieldPrime: [UInt8] {
        switch self {
        case .p256:
            // 2^256 − 2^224 + 2^192 + 2^96 − 1
            return [0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        case .p384:
            // 2^384 − 2^128 − 2^96 + 2^32 − 1
            return [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
                    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff]
        case .p521:
            // 2^521 − 1: a leading 0x01, then 65 bytes of 0xff.
            return [0x01] + [UInt8](repeating: 0xff, count: 65)
        }
    }
}

/// PKCS#1, SEC1 and PKCS#8 — the three DER structures a PEM private key body
/// can be, once any encryption is off it.
enum PEMKeyStructures {
    typealias Failure = PEMPrivateKeyDecoder.DecodeError
    typealias Curve = PEMPrivateKeyDecoder.Curve
    typealias Components = PEMPrivateKeyDecoder.RSAPrivateKeyComponents

    /// `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qInv }`.
    static func rsaPKCS1(_ der: Data) throws(Failure) -> Components {
        let nodes = try PEMDER.children(try PEMDER.parse(der))
        guard nodes.count >= 9 else { throw Failure.notReadable(.malformed) }
        switch try PEMDER.integer(nodes[0]) {
        case 0: break
        // Version 1 is multi-prime (RFC 3447 §3.2): there are further primes
        // after qInv that no SSH key format carries.
        case 1: throw Failure.notReadable(.keyType("multi-prime RSA"))
        default: throw Failure.notReadable(.malformed)
        }
        return Components(n: try PEMDER.magnitude(nodes[1]),
                          e: try PEMDER.magnitude(nodes[2]),
                          d: try PEMDER.magnitude(nodes[3]),
                          p: try PEMDER.magnitude(nodes[4]),
                          q: try PEMDER.magnitude(nodes[5]),
                          iqmp: try PEMDER.magnitude(nodes[8]))
    }

    /// `ECPrivateKey ::= SEQUENCE { version, privateKey OCTET STRING,
    /// [0] parameters OPTIONAL, [1] publicKey OPTIONAL }`.
    ///
    /// `outerCurve` is what a PKCS#8 wrapper's `AlgorithmIdentifier` named;
    /// the inner structure may omit its own parameters, and then that is the
    /// only place the curve is written. When the inner structure DOES carry
    /// parameters they decide, and a refusal from them is this function's
    /// refusal — `pkcs8` has by then already dropped an outer
    /// `AlgorithmIdentifier` it could not name, so both places failing to name
    /// a curve is the only way to reach `.keyType("unknown")` from a file any
    /// producer in the design table writes. Each of them writes the domain in
    /// exactly ONE of the two places (measured 2026-09-10, `openssl asn1parse`
    /// on ssh-keygen `-m PKCS8` and `-m PEM` output).
    static func ecSEC1(_ der: Data, outerCurve: Curve?) throws(Failure) -> (Curve, Data) {
        let nodes = try PEMDER.children(try PEMDER.parse(der))
        guard nodes.count >= 2, try PEMDER.integer(nodes[0]) == 1 else {
            throw Failure.notReadable(.malformed)
        }
        let raw = try PEMDER.octets(nodes[1])
        let curve: Curve
        if let parameters = try PEMDER.explicitlyTagged(nodes, number: 0) {
            curve = try self.curve(fromParameters: parameters)
        } else if let outerCurve {
            curve = outerCurve
        } else {
            throw Failure.notReadable(.keyType("unknown"))
        }
        guard raw.count <= curve.scalarByteCount else { throw Failure.notReadable(.malformed) }
        let scalar = Data(repeating: 0x00, count: curve.scalarByteCount - raw.count) + raw
        return (curve, scalar)
    }

    /// EC domain parameters: either a named-curve OID (what
    /// `openssl ecparam -genkey` writes) or a `SpecifiedECDomain` (what
    /// ssh-keygen writes), in which case the field prime identifies the
    /// curve.
    static func curve(fromParameters node: ASN1Node) throws(Failure) -> Curve {
        if node.identifier == .objectIdentifier {
            switch try PEMDER.oid(node) {
            case PEMDER.secp256r1: return .p256
            case PEMDER.secp384r1: return .p384
            case PEMDER.secp521r1: return .p521
            default: throw Failure.notReadable(.keyType("unknown"))
            }
        }
        guard node.identifier == .sequence else { throw Failure.notReadable(.keyType("unknown")) }
        // SpecifiedECDomain ::= SEQUENCE { version, fieldID, curve, base,
        // order, cofactor OPTIONAL }; fieldID ::= SEQUENCE { fieldType,
        // parameters } and for a prime field the parameters are the prime.
        let domain = try PEMDER.children(node)
        guard domain.count >= 2 else { throw Failure.notReadable(.malformed) }
        let fieldID = try PEMDER.children(domain[1])
        guard fieldID.count >= 2 else { throw Failure.notReadable(.malformed) }
        guard try PEMDER.oid(fieldID[0]) == PEMDER.primeField else {
            throw Failure.notReadable(.keyType("unknown"))
        }
        let prime = Array(try PEMDER.magnitude(fieldID[1]))
        for candidate in [Curve.p256, .p384, .p521] where candidate.fieldPrime == prime {
            return candidate
        }
        throw Failure.notReadable(.keyType("unknown"))
    }

    /// `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier,
    /// privateKey OCTET STRING, ... }`.
    static func pkcs8(_ der: Data) throws(Failure) -> PEMPrivateKeyDecoder.DecodedPrivateKey {
        let nodes = try PEMDER.children(try PEMDER.parse(der))
        guard nodes.count >= 3 else { throw Failure.notReadable(.malformed) }
        let algorithm = try PEMDER.children(nodes[1])
        guard let algorithmOID = algorithm.first else { throw Failure.notReadable(.malformed) }
        let inner = try PEMDER.octets(nodes[2])

        switch try PEMDER.oid(algorithmOID) {
        case PEMDER.rsaEncryption:
            return .rsa(try rsaPKCS1(inner))
        case PEMDER.idEcPublicKey:
            // The outer parameters are OPTIONAL, and when they are there they
            // may be something this reader cannot turn into a curve — a `NULL`,
            // or a curve it does not carry. That is not a refusal on its own:
            // `ecSEC1` prefers the inner structure's own `[0] parameters`
            // anyway, and refuses with `.keyType("unknown")` only when NEITHER
            // place names a curve. So an unreadable outer AlgorithmIdentifier
            // falls through to the inner one rather than ending the read here.
            var outerCurve: Curve?
            if algorithm.count >= 2 {
                outerCurve = try? curve(fromParameters: algorithm[1])
            }
            let (curve, scalar) = try ecSEC1(inner, outerCurve: outerCurve)
            return .ecdsa(curve: curve, scalar: scalar)
        case PEMDER.idEd25519:
            // RFC 8410: the privateKey OCTET STRING holds a `CurvePrivateKey`,
            // which is itself an OCTET STRING — the seed is one layer down.
            let seed = try PEMDER.octets(try PEMDER.parse(inner))
            guard seed.count == 32 else { throw Failure.notReadable(.malformed) }
            return .ed25519(seed: seed)
        case PEMDER.idDSA:
            throw Failure.notReadable(.keyType("DSA"))
        default:
            throw Failure.notReadable(.keyType("unknown"))
        }
    }
}
