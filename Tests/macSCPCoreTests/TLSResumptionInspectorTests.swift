import Foundation
import Testing

@testable import macSCPCore

/// `TLSResumptionInspector` is a pure function over bytes, so its cases are
/// built here from the RFC's own layouts rather than captured from a library:
/// a capture would only prove the inspector agrees with the library that made
/// it. The live side -- a real stack's real handshakes, resumed and not -- is
/// `LoopbackFTPServerTests.theServerReadsAResumedHandshakeOffTheWire`.
@Suite("TLS resumption inspector", .timeLimit(.minutes(5)))
struct TLSResumptionInspectorTests {
    // MARK: Builders (RFC 5246 section 6.2.1 and 7.4, RFC 8446 section 4.1.3)

    private static func record(_ contentType: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [contentType, 3, 3, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }

    private static func message(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private static let ordinaryRandom = [UInt8](repeating: 0x11, count: 32)

    /// RFC 8446 section 4.1.3, written out again here on purpose: a test that
    /// read the inspector's own constant would pass if that constant were wrong.
    private static let helloRetryRandom: [UInt8] = [
        0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
        0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
    ]

    private static func serverHello(
        random: [UInt8] = ordinaryRandom, extensions: [(type: UInt16, data: [UInt8])]
    ) -> [UInt8] {
        var encoded: [UInt8] = []
        for item in extensions {
            encoded += [UInt8(item.type >> 8), UInt8(item.type & 0xFF)]
            encoded += [UInt8(item.data.count >> 8), UInt8(item.data.count & 0xFF)]
            encoded += item.data
        }
        var body: [UInt8] = [3, 3] + random + [0]  // legacy_version, random, empty session id
        body += [0x13, 0x01, 0]  // cipher suite, null compression
        body += [UInt8(encoded.count >> 8), UInt8(encoded.count & 0xFF)] + encoded
        return message(2, body)
    }

    private static let supportedVersions13: (type: UInt16, data: [UInt8]) = (0x002B, [3, 4])
    private static let keyShare: (type: UInt16, data: [UInt8]) = (0x0033, [0, 0x1D, 0, 0])
    private static let preSharedKey: (type: UInt16, data: [UInt8]) = (0x0029, [0, 0])

    private static func verdict(of wire: [UInt8]) -> TLSResumptionInspector.Verdict {
        var inspector = TLSResumptionInspector()
        inspector.feed(wire)
        return inspector.verdict
    }

    // MARK: TLS 1.3

    @Test func aTLS13ServerHelloWithAPreSharedKeyIsAResumption() {
        let hello = Self.serverHello(extensions: [Self.supportedVersions13, Self.preSharedKey])
        #expect(Self.verdict(of: Self.record(22, hello)) == .resumed)
    }

    @Test func aTLS13ServerHelloWithoutOneIsAFullHandshake() {
        let hello = Self.serverHello(extensions: [Self.supportedVersions13, Self.keyShare])
        #expect(Self.verdict(of: Self.record(22, hello)) == .fullHandshake)
    }

    @Test func aHelloRetryRequestIsSkippedAndTheNextServerHelloDecides() {
        let retry = Self.serverHello(
            random: Self.helloRetryRandom, extensions: [Self.supportedVersions13, Self.keyShare])
        let resumed = Self.serverHello(extensions: [Self.supportedVersions13, Self.preSharedKey])
        let wire = Self.record(22, retry) + Self.record(20, [1]) + Self.record(22, resumed)

        var inspector = TLSResumptionInspector()
        inspector.feed(Self.record(22, retry))
        // Not decided by the retry request: it is not a ServerHello proper.
        #expect(inspector.verdict == .undecided)
        #expect(Self.verdict(of: wire) == .resumed)
    }

    // MARK: TLS 1.2

    @Test func aTLS12ServerHelloFollowedByACertificateIsAFullHandshake() {
        let hello = Self.serverHello(extensions: [])
        let certificate = Self.message(11, [0, 0, 0])
        // Together in one record, and apart in two: both occur on the wire.
        #expect(Self.verdict(of: Self.record(22, hello + certificate)) == .fullHandshake)
        #expect(
            Self.verdict(of: Self.record(22, hello) + Self.record(22, certificate)) == .fullHandshake)
    }

    @Test func aTLS12ServerHelloFollowedByChangeCipherSpecIsAResumption() {
        let wire = Self.record(22, Self.serverHello(extensions: [])) + Self.record(20, [1])
        #expect(Self.verdict(of: wire) == .resumed)
    }

    @Test func aTLS12ServerHelloFollowedByANewSessionTicketIsAResumption() {
        let ticket = Self.message(4, [0, 0, 0, 0, 0, 0])
        let wire = Self.record(22, Self.serverHello(extensions: []) + ticket) + Self.record(20, [1])
        #expect(Self.verdict(of: wire) == .resumed)
    }

    // MARK: What it must not decide

    @Test func theVerdictIsTheSameWhenTheBytesArriveOneAtATime() {
        let wire = Self.record(22, Self.serverHello(extensions: []) + Self.message(11, [0, 0, 0]))
        var inspector = TLSResumptionInspector()
        var seen: [TLSResumptionInspector.Verdict] = []
        for byte in wire {
            inspector.feed([byte])
            seen.append(inspector.verdict)
        }
        #expect(seen.last == .fullHandshake)
        // And not before the Certificate's last byte: a verdict reached early
        // would be a guess.
        #expect(seen.dropLast().allSatisfy { $0 == .undecided })
    }

    @Test func aServerHelloAloneDecidesNothingInTLS12() {
        #expect(Self.verdict(of: Self.record(22, Self.serverHello(extensions: []))) == .undecided)
    }

    @Test func bytesThatAreNotARecordDecideNothing() {
        #expect(Self.verdict(of: [0x16, 0x03]) == .undecided)
        #expect(Self.verdict(of: []) == .undecided)
        // A positive beside the two negatives: the same inspector does decide
        // given a real flight, so "undecided" above is not a dead inspector.
        #expect(
            Self.verdict(of: Self.record(22, Self.serverHello(extensions: [Self.supportedVersions13])))
                == .fullHandshake)
    }

    @Test func aDecidedVerdictIsNotChangedByWhatFollows() {
        var inspector = TLSResumptionInspector()
        inspector.feed(
            Self.record(22, Self.serverHello(extensions: [Self.supportedVersions13, Self.keyShare])))
        #expect(inspector.verdict == .fullHandshake)
        // TLS 1.3's compatibility ChangeCipherSpec, which in TLS 1.2 would
        // mean "resumed".
        inspector.feed(Self.record(20, [1]))
        #expect(inspector.verdict == .fullHandshake)
    }
}
