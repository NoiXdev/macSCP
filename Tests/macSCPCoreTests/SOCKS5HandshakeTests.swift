import Foundation
import NIOCore
import NIOEmbedded
import Testing

@testable import macSCPCore

/// The SOCKS5 server side of a dynamic forward (`-D`), driven on an
/// `EmbeddedChannel` with byte fixtures — no socket, no SSH, no server.
///
/// **Eleven inbound byte fixtures**, counted 2026-09-06 and listed here
/// because a fixture that is not named is a fixture nobody re-reads:
/// `greetingOfferingNoAuth`, `greetingWithoutNoAuth`,
/// `greetingWithTheWrongVersion`, `connectToIPv4`, `connectToADomain`,
/// `connectToIPv6`, `bindRequest`, `udpAssociateRequest`,
/// `requestWithAnUnknownAddressType`, `requestWithANonZeroReservedByte`,
/// `requestWithTheWrongVersion`. Each is spelled out as literal bytes
/// rather than built by the code under test, so a change to the encoder
/// cannot quietly change what the decoder is measured against.
///
/// Every case here is a SYNCHRONOUS `@Test func … throws`, for the reason
/// `BytePumpTests` gives: `EmbeddedEventLoop.checkCorrectThread` only
/// tolerates the thread it was created on, and an `await` in a Swift
/// Testing body can resume elsewhere.
@Suite("SOCKS5 handshake", .timeLimit(.minutes(1)))
struct SOCKS5HandshakeTests {

    // MARK: - Turning reading on

    /// The handler asks for its own reads, and asks on the EVENT LOOP.
    ///
    /// The listener accepts with `autoRead` off, so something has to turn it
    /// on; doing it from the accept task races NIO's registration of the
    /// accepted channel, and the loser of that race is a channel registered
    /// for no read interest at all (see `handlerAdded`'s comment). Measured
    /// as a hang, 3 of 7 whole-suite runs, before the reads moved in here.
    ///
    /// The two cases below are the two orders the handler can be installed
    /// in, and exactly one entry point may fire in each.
    @Test func aHandlerAddedBeforeActivationReadsOnceTheChannelIsActive() throws {
        let channel = EmbeddedChannel()
        let reads = ReadRecorder()
        try channel.pipeline.syncOperations.addHandler(reads)
        try channel.pipeline.syncOperations.addHandler(SOCKS5HandshakeHandler())

        #expect(channel.isActive == false)
        #expect(reads.count == 0, "nothing may be read before the channel is active")

        channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)

        #expect(autoRead(of: channel) == true)
        #expect(reads.count >= 1)
    }

    @Test func aHandlerAddedAfterActivationReadsAtOnce() throws {
        let channel = EmbeddedChannel()
        let reads = ReadRecorder()
        try channel.pipeline.syncOperations.addHandler(reads)
        channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        #expect(channel.isActive)
        #expect(reads.count == 0)

        try channel.pipeline.syncOperations.addHandler(SOCKS5HandshakeHandler())

        #expect(autoRead(of: channel) == true)
        #expect(reads.count >= 1)
    }

    // MARK: - The greeting

    @Test func aGreetingOfferingNoAuthIsAnswered() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00])
        #expect(socks.channel.isActive)
        #expect(isSettled(socks.handshake) == false)
    }

    @Test func aGreetingWithoutNoAuthIsRefusedAndTheConnectionCloses() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingWithoutNoAuth))

        #expect(try outboundBytes(socks.channel) == [0x05, 0xFF])
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .noAcceptableMethod)
    }

    /// A version byte that is not 5 is not SOCKS5 at all: nothing is written
    /// back, because a reply would itself be a SOCKS5 frame and this peer has
    /// just said it does not speak that.
    @Test func aGreetingWithTheWrongVersionClosesWithoutAReply() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingWithTheWrongVersion))

        #expect(try outboundBytes(socks.channel).isEmpty)
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .malformedFrame)
    }

    // MARK: - The request

    @Test func aConnectToAnIPv4AddressIsDecoded() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv4))

        #expect(decodedDestination(socks.handshake) == SOCKS5Destination(host: "10.0.0.1", port: 80))
        // Nothing is answered yet: the reply waits for the channel through
        // the SSH server, which is the whole reason the destination is handed
        // out asynchronously.
        #expect(try outboundBytes(socks.channel) == [0x05, 0x00])
    }

    @Test func aConnectToADomainNameIsDecodedExactly() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToADomain))

        #expect(
            decodedDestination(socks.handshake) == SOCKS5Destination(host: "example.com", port: 443))
    }

    @Test func aConnectToAnIPv6AddressIsDecoded() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv6))

        #expect(
            decodedDestination(socks.handshake) == SOCKS5Destination(host: "2001:db8::1", port: 8080))
    }

    /// A whole conversation delivered one byte at a time still decodes: the
    /// handler owns its accumulator and re-parses from the top on every read
    /// until a frame is complete.
    @Test func aFrameSplitAcrossReadsIsStillDecoded() throws {
        let socks = try socks5Channel()
        for byte in greetingOfferingNoAuth + connectToADomain {
            try socks.channel.writeInbound(ByteBuffer(bytes: [byte]))
        }

        #expect(
            decodedDestination(socks.handshake) == SOCKS5Destination(host: "example.com", port: 443))
        #expect(try outboundBytes(socks.channel) == [0x05, 0x00])
    }

    @Test func aBindRequestIsRefusedWithCommandNotSupported() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: bindRequest))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x07))
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .unsupportedCommand)
    }

    @Test func aUDPAssociateRequestIsRefusedWithCommandNotSupported() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: udpAssociateRequest))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x07))
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .unsupportedCommand)
    }

    @Test func anUnknownAddressTypeIsRefused() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: requestWithAnUnknownAddressType))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x08))
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .unsupportedAddressType)
    }

    @Test func aRequestWithANonZeroReservedByteIsMalformedAndCloses() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: requestWithANonZeroReservedByte))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00])
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .malformedFrame)
    }

    @Test func aRequestWithTheWrongVersionClosesTheConnection() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: requestWithTheWrongVersion))

        #expect(try outboundBytes(socks.channel) == [0x05, 0x00])
        #expect(socks.channel.isActive == false)
        #expect(handshakeError(socks.handshake) == .malformedFrame)
    }

    // MARK: - Handing the connection over

    /// The success reply goes out, the handler leaves the pipeline, and what
    /// arrives next reaches whatever sits behind it — in production the
    /// `BytePump`, here a recorder standing in for it.
    @Test func successRepliesRemovesTheHandlerAndLetsTheNextBytesThrough() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv4))

        let finished = CompletionBox()
        socks.handshake.succeed(on: socks.channel).whenComplete { finished.record($0) }
        socks.channel.embeddedEventLoop.run()

        #expect(finished.succeeded)
        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x00))
        // A positive check beside the negative one: the recorder IS in the
        // pipeline, so "the handshake is not" means something.
        #expect(throws: (any Error).self) {
            try socks.channel.pipeline.syncOperations.context(handler: socks.handshake)
        }
        #expect(throws: Never.self) {
            try socks.channel.pipeline.syncOperations.context(handler: socks.tail)
        }

        try socks.channel.writeInbound(ByteBuffer(string: "hello"))
        #expect(socks.tail.bytes == Array("hello".utf8))
    }

    /// Bytes that arrive after the request but before the reply — a client
    /// that pipelines its first payload behind CONNECT — are buffered by the
    /// handler and handed on when it leaves, not dropped.
    @Test func bytesArrivingBeforeTheReplyAreHandedToThePump() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv4 + Array("early".utf8)))

        #expect(socks.tail.bytes.isEmpty)

        socks.handshake.succeed(on: socks.channel).whenComplete { _ in }
        socks.channel.embeddedEventLoop.run()

        #expect(socks.tail.bytes == Array("early".utf8))
    }

    /// **After the handover, a rejection writes nothing.** The accept path
    /// calls `reject` for a `pumpFailed` as well, and `pumpFailed` is what
    /// `startReading` raises — which runs AFTER `confirm` has already sent
    /// the success frame and let the pump take over. Ten bytes of `05 01 …`
    /// at that point are not a reply; they are ten bytes injected into an
    /// established payload stream.
    ///
    /// The negative check — nothing written by the reject — has the positive
    /// one beside it in the same case: the success frame WAS written first,
    /// so "no bytes" is a statement about a channel that demonstrably writes.
    @Test func aRejectionAfterTheHandoverWritesNothing() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv4))

        socks.handshake.succeed(on: socks.channel).whenComplete { _ in }
        socks.channel.embeddedEventLoop.run()
        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x00))

        let finished = CompletionBox()
        socks.handshake.reject(.generalFailure, on: socks.channel).whenComplete {
            finished.record($0)
        }
        socks.channel.embeddedEventLoop.run()

        #expect(finished.succeeded)
        #expect(try outboundBytes(socks.channel).isEmpty)
        #expect(socks.channel.isActive == false)
    }

    /// A refused `direct-tcpip` channel is answered with a SOCKS5 failure
    /// reply and the connection closed — the client learns WHY rather than
    /// seeing a bare disconnect.
    @Test func aRefusedChannelIsReportedAsASOCKS5Failure() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        try socks.channel.writeInbound(ByteBuffer(bytes: connectToIPv4))

        let finished = CompletionBox()
        socks.handshake.reject(.generalFailure, on: socks.channel).whenComplete { finished.record($0) }
        socks.channel.embeddedEventLoop.run()

        #expect(finished.succeeded)
        #expect(try outboundBytes(socks.channel) == [0x05, 0x00] + replyFrame(code: 0x01))
        #expect(socks.channel.isActive == false)
    }

    /// The mapping from a transport failure to a reply code, exhaustively —
    /// `SOCKS5ReplyCode.init(_:)` switches over `TunnelFailure` with no
    /// `default`, so a case added there fails to compile until someone
    /// decides what the SOCKS client should be told.
    @Test func everyTunnelFailureMapsToAReplyCode() {
        #expect(SOCKS5ReplyCode(.channelOpenFailed(reason: "refused")) == .generalFailure)
        #expect(SOCKS5ReplyCode(.connectFailed(reason: "refused")) == .connectionRefused)
        #expect(SOCKS5ReplyCode(.portInUse(port: 1080)) == .generalFailure)
        #expect(SOCKS5ReplyCode(.bindFailed(reason: "no such address")) == .generalFailure)
        #expect(SOCKS5ReplyCode(.pumpFailed(reason: "the pump did not install")) == .generalFailure)
        #expect(SOCKS5ReplyCode(.alreadyStarted) == .generalFailure)
    }

    /// A connection that goes away mid-handshake resolves the wait rather
    /// than parking it: `LocalForwardListener`'s accept task awaits the
    /// destination, and a client that hangs up before naming one must not
    /// leave that task alive forever.
    @Test func aConnectionClosedBeforeTheRequestEndsTheWait() throws {
        let socks = try socks5Channel()
        try socks.channel.writeInbound(ByteBuffer(bytes: greetingOfferingNoAuth))
        socks.channel.close(promise: nil)
        socks.channel.embeddedEventLoop.run()

        #expect(handshakeError(socks.handshake) == .closedBeforeARequest)
    }
}

// MARK: - The byte fixtures

/// `05 01 00` — version 5, one method, "no authentication required".
private let greetingOfferingNoAuth: [UInt8] = [0x05, 0x01, 0x00]

/// `05 02 01 02` — GSSAPI and username/password, neither of which this
/// server offers.
private let greetingWithoutNoAuth: [UInt8] = [0x05, 0x02, 0x01, 0x02]

/// `04 01 00` — a SOCKS4 client.
private let greetingWithTheWrongVersion: [UInt8] = [0x04, 0x01, 0x00]

/// `05 01 00 01 0a 00 00 01 00 50` — CONNECT 10.0.0.1:80.
private let connectToIPv4: [UInt8] = [0x05, 0x01, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x50]

/// `05 01 00 03 0b "example.com" 01 bb` — CONNECT example.com:443. The name
/// is spelled as its eleven ASCII bytes rather than as `Array("…".utf8)` so
/// the length byte in front of it can be read against something.
private let connectToADomain: [UInt8] = [
    0x05, 0x01, 0x00, 0x03, 0x0B,
    101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109,
    0x01, 0xBB,
]

/// `05 01 00 04 2001:0db8:…:0001 1f 90` — CONNECT [2001:db8::1]:8080.
private let connectToIPv6: [UInt8] = [
    0x05, 0x01, 0x00, 0x04,
    0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
    0x1F, 0x90,
]

/// BIND (`02`) — refused; the design says CONNECT only.
private let bindRequest: [UInt8] = [0x05, 0x02, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x50]

/// UDP ASSOCIATE (`03`) — refused for the same reason.
private let udpAssociateRequest: [UInt8] = [0x05, 0x03, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x50]

/// Address type `02`, which RFC 1928 does not define.
private let requestWithAnUnknownAddressType: [UInt8] = [
    0x05, 0x01, 0x00, 0x02, 10, 0, 0, 1, 0x00, 0x50,
]

/// The reserved byte is `01` where RFC 1928 requires `00`.
private let requestWithANonZeroReservedByte: [UInt8] = [
    0x05, 0x01, 0x01, 0x01, 10, 0, 0, 1, 0x00, 0x50,
]

/// Version `04` in the request, after a version-5 greeting.
private let requestWithTheWrongVersion: [UInt8] = [
    0x04, 0x01, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x50,
]

/// A reply frame: version, code, reserved, then the bound address RFC 1928
/// requires and every client ignores — `0.0.0.0:0`.
private func replyFrame(code: UInt8) -> [UInt8] {
    [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
}

// MARK: - Helpers

private func socks5Channel() throws
    -> (channel: EmbeddedChannel, handshake: SOCKS5HandshakeHandler, tail: ByteRecorder)
{
    let channel = EmbeddedChannel()
    let handshake = SOCKS5HandshakeHandler()
    let tail = ByteRecorder()
    try channel.pipeline.syncOperations.addHandler(handshake)
    try channel.pipeline.syncOperations.addHandler(tail)
    // A bare `EmbeddedChannel()` is registered but never activated; the fake
    // connect is what `EmbeddedChannelCore.connect0` treats as activation,
    // and without it `isActive` would be false before anything closed it.
    channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
    return (channel, handshake, tail)
}

/// Counts the outbound `read()` events that pass it. A handler added BEFORE
/// the handshake sits closer to the head, so the handshake's own reads travel
/// through it.
private final class ReadRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer

    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func read(context: ChannelHandlerContext) {
        lock.lock()
        reads += 1
        lock.unlock()
        context.read()
    }
}

private func autoRead(of channel: EmbeddedChannel) -> Bool? {
    channel.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool
}

private func outboundBytes(_ channel: EmbeddedChannel) throws -> [UInt8] {
    var bytes: [UInt8] = []
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
    }
    return bytes
}

private func isSettled(_ handshake: SOCKS5HandshakeHandler) -> Bool {
    handshake.requested.settled != nil
}

private func decodedDestination(_ handshake: SOCKS5HandshakeHandler) -> SOCKS5Destination? {
    guard case .success(let destination)? = handshake.requested.settled else { return nil }
    return destination
}

private func handshakeError(_ handshake: SOCKS5HandshakeHandler) -> SOCKS5HandshakeError? {
    guard case .failure(let error)? = handshake.requested.settled else { return nil }
    return error as? SOCKS5HandshakeError
}

/// Stands in for the `BytePump` behind the handshake: everything that
/// reaches the next handler, in order.
private final class ByteRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var collected: [UInt8] = []

    var bytes: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let chunk = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.lock()
        collected += chunk
        lock.unlock()
    }
}

/// Records how a future finished, so a synchronous test can assert on it
/// without a blocking wait.
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .success? = outcome { return true }
        return false
    }

    func record(_ result: Result<Void, any Error>) {
        lock.lock()
        outcome = result
        lock.unlock()
    }
}
