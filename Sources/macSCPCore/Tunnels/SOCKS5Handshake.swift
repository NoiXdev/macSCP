import Foundation
import NIOCore

/// Where a SOCKS5 client asked to be connected — **as the SSH server will
/// have to reach it**, which is why the host is a string and not a resolved
/// address: a domain name in a CONNECT request is resolved by the far side,
/// never here, and resolving it locally would defeat the point of a dynamic
/// forward.
public struct SOCKS5Destination: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// The reply codes of RFC 1928 §6 this app can produce.
///
/// Not the complete set: `02` (connection not allowed by ruleset), `03`
/// (network unreachable) and `06` (TTL expired) are absent because nothing
/// here can tell them apart from the codes below — see
/// `SOCKS5ReplyCode.init(_:)` for what the SSH layer actually hands over.
public enum SOCKS5ReplyCode: UInt8, Sendable, Equatable {
    case succeeded = 0x00
    case generalFailure = 0x01
    /// Defined by RFC 1928 and **produced by no arm of `init(_:)`**, for the
    /// reason that initialiser documents: an SSH `direct-tcpip` refusal
    /// reaches this module with its reason code already discarded, so "the
    /// destination was unreachable" cannot be distinguished from any other
    /// refusal. Kept named rather than dropped so the day the distinction
    /// becomes available there is somewhere for it to go.
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

extension SOCKS5ReplyCode {
    /// What the SOCKS client is told when a tunnel's transport failed.
    ///
    /// **Which codes actually reach a client**, re-derived from the tree on
    /// 2026-09-06 after `LocalForwardListener.acceptFailure` began passing a
    /// `TunnelFailure` through unchanged instead of re-mapping every error to
    /// `channelOpenFailed`. `reject` is called from exactly one place — that
    /// accept path's catch — so the reachable set is whatever can be thrown
    /// between the factory call and `startReading`:
    ///
    /// | `TunnelFailure` | code | raised by, today |
    /// |---|---|---|
    /// | `.channelOpenFailed` | `01` | `CitadelFileSystem.openDirectTCPIP`'s own catch, and any foreign error before the factory answers |
    /// | `.pumpFailed` | `01` | a foreign error after the factory answered — `BytePump.install`, `confirm`, `startReading` |
    /// | `.connectFailed` | `05` | nothing on this path. Its one producer is `TunnelConnection.connect`, for a session that is not SSH, which runs before a listener exists. Reachable only through the `DirectTCPIPFactory` seam, which is how `SOCKS5ListenerTests` measures it |
    /// | `.portInUse`, `.bindFailed`, `.alreadyStarted` | `01` | `start`, before any client has connected — unreachable here |
    ///
    /// So in production **`01` is what every refusal produces**, `05` is
    /// waiting for a factory that distinguishes a refusal, and `04` is
    /// produced by nothing. Counted 2026-09-06 with `grep -rn "throw
    /// TunnelFailure\." Sources/`: FOUR throw sites —
    /// `TunnelConnection.swift:57`, `LocalForwardListener.swift:168` and
    /// `:194`, `CitadelFileSystem.swift:1451` — plus the two helpers that
    /// RETURN one rather than throw it, `LocalForwardListener.bindFailure`
    /// and `.acceptFailure`.
    ///
    /// The mapping reads the FAILURE'S CASE and never its `reason` text. Two
    /// measurements, both 2026-09-06, say it has to:
    ///
    /// 1. **The SSH reason code does not survive the trip.** RFC 4254 §5.1
    ///    gives `SSH_MSG_CHANNEL_OPEN_FAILURE` a numeric reason —
    ///    `1` administratively prohibited, `2` connect failed, `3` unknown
    ///    channel type, `4` resource shortage — and NIOSSH does read it:
    ///    `SSHChildChannel.handleInboundChannelOpenFailure` builds
    ///    `NIOSSHError.channelSetupRejected(reasonCode:reason:)` from the
    ///    message. But `SSHMessage.ChannelOpenFailureMessage` is internal,
    ///    `NIOSSHError`'s `diagnostics` is private, and the only public
    ///    surface is `type` (`.channelSetupRejected`, one value for all four
    ///    codes) and a `description` string. `DialSupport.reason(for:)` then
    ///    reduces any error it does not spell out to
    ///    `NSError.localizedDescription`, which for `NIOSSHError` reads "The
    ///    operation couldn't be completed. (NIOSSH.NIOSSHError error 1.)" —
    ///    no code, no sentence. So `.channelOpenFailed` becomes `01`.
    ///    `openDirectTCPIP` now keeps its `TunnelFailure` intact all the way
    ///    here, but what it kept was already built from that sentence — the
    ///    reason survives, the reason CODE was never in it.
    /// 2. **The reason text is not a channel.** `DialSupport.reason(for:)`
    ///    exists to produce a fixed, secret-free SENTENCE for a human; a
    ///    mapping that pattern-matched it would turn every rewording of that
    ///    sentence into a silent behaviour change here.
    ///
    /// Exhaustive with no `default`: a case added to `TunnelFailure` fails to
    /// compile until someone decides what the client should be told.
    public init(_ failure: TunnelFailure) {
        switch failure {
        case .channelOpenFailed, .pumpFailed:
            // `pumpFailed` reaches a client that IS connected — the accept
            // path rejects a negotiation with it — and there is no SOCKS5
            // code for "the far end answered but we could not wire you to
            // it", so it joins the general failure.
            self = .generalFailure
        case .connectFailed:
            // The one arm that IS specific: `connectFailed` means this
            // machine dialled something itself and was turned away, and a
            // refusal is the overwhelmingly common cause. No factory in the
            // tree raises it on this path (see the table above); the arm
            // exists for the one that will.
            self = .connectionRefused
        case .portInUse, .bindFailed, .alreadyStarted:
            // None of the three can reach a connected SOCKS client — the
            // listener is already bound by the time anyone speaks to it —
            // but a failure enum is not the place for an unreachable arm to
            // be spelled `fatalError`.
            self = .generalFailure
        }
    }
}

/// Why a SOCKS5 conversation ended before it named a destination.
///
/// Every case closes the connection. `noAcceptableMethod`,
/// `unsupportedCommand` and `unsupportedAddressType` are answered with a
/// SOCKS5 frame first; `malformedFrame` is not, because the peer has just
/// demonstrated that it is not reading SOCKS5.
enum SOCKS5HandshakeError: Error, Equatable {
    case noAcceptableMethod
    case unsupportedCommand
    case unsupportedAddressType
    case malformedFrame
    case closedBeforeARequest
}

// MARK: - The frames

/// RFC 1928 on the wire: the two frames this server reads, and the two it
/// writes. Pure — nothing here touches a channel — so the whole protocol can
/// be measured against byte fixtures.
enum SOCKS5Frames {
    static let version: UInt8 = 0x05
    static let noAuthentication: UInt8 = 0x00
    static let noAcceptableMethod: UInt8 = 0xFF
    private static let connect: UInt8 = 0x01
    private static let reserved: UInt8 = 0x00
    private static let atypIPv4: UInt8 = 0x01
    private static let atypDomain: UInt8 = 0x03
    private static let atypIPv6: UInt8 = 0x04

    enum Greeting: Equatable {
        case needMoreData
        case malformed
        /// The client's method list, and how many bytes it occupied.
        case methods([UInt8], consumed: Int)
    }

    enum Request: Equatable {
        case needMoreData
        case malformed
        case unsupportedCommand
        case unsupportedAddressType
        case connect(SOCKS5Destination, consumed: Int)
    }

    /// `05 NMETHODS METHODS…`, read without consuming: the caller advances
    /// its own buffer by `consumed` once it has decided what to do.
    static func greeting(in buffer: ByteBuffer) -> Greeting {
        guard let header = buffer.getBytes(at: buffer.readerIndex, length: 2) else {
            return .needMoreData
        }
        guard header[0] == version else { return .malformed }
        let count = Int(header[1])
        // RFC 1928 §3: NMETHODS is "the number of method identifier octets
        // that appear in the METHODS field", and the field is not optional.
        guard count > 0 else { return .malformed }
        guard let methods = buffer.getBytes(at: buffer.readerIndex + 2, length: count) else {
            return .needMoreData
        }
        return .methods(methods, consumed: 2 + count)
    }

    /// `05 CMD 00 ATYP ADDR PORT`.
    ///
    /// The order of the checks is not free: the address type decides how long
    /// the frame is, so it is validated FIRST — an unknown one leaves no way
    /// to find the end of the frame, let alone the command. Only once the
    /// whole frame is present is the command judged, so that a BIND request
    /// is answered with "command not supported" rather than being mistaken
    /// for a short read.
    static func request(in buffer: ByteBuffer) -> Request {
        guard let header = buffer.getBytes(at: buffer.readerIndex, length: 4) else {
            return .needMoreData
        }
        guard header[0] == version, header[2] == reserved else { return .malformed }

        let addressStart = buffer.readerIndex + 4
        let addressLength: Int
        switch header[3] {
        case atypIPv4:
            addressLength = 4
        case atypIPv6:
            addressLength = 16
        case atypDomain:
            guard let length = buffer.getBytes(at: addressStart, length: 1) else {
                return .needMoreData
            }
            guard length[0] > 0 else { return .malformed }
            addressLength = 1 + Int(length[0])
        default:
            return .unsupportedAddressType
        }

        guard let address = buffer.getBytes(at: addressStart, length: addressLength),
            let portBytes = buffer.getBytes(at: addressStart + addressLength, length: 2)
        else {
            return .needMoreData
        }
        guard header[1] == connect else { return .unsupportedCommand }

        let host: String?
        switch header[3] {
        case atypIPv4:
            host = "\(address[0]).\(address[1]).\(address[2]).\(address[3])"
        case atypIPv6:
            host = ipv6Text(address)
        default:
            host = String(bytes: address.dropFirst(), encoding: .utf8)
        }
        guard let host, !host.isEmpty else { return .malformed }

        let port = Int(portBytes[0]) << 8 | Int(portBytes[1])
        return .connect(
            SOCKS5Destination(host: host, port: port), consumed: 4 + addressLength + 2)
    }

    /// `05 METHOD` — the server's answer to the greeting.
    static func methodSelection(_ method: UInt8) -> [UInt8] { [version, method] }

    /// `05 REP 00 01 00000000 0000`.
    ///
    /// The bound address every reply carries is `0.0.0.0:0`. RFC 1928 wants
    /// the address the server bound on the client's behalf; for a CONNECT
    /// that address is the SSH server's, which this side never learns, and
    /// every SOCKS client in practice ignores the field. OpenSSH's own
    /// dynamic forward answers the same way.
    static func reply(_ code: SOCKS5ReplyCode) -> [UInt8] {
        [version, code.rawValue, reserved, atypIPv4, 0, 0, 0, 0, 0, 0]
    }

    /// The canonical (compressed, lowercase) text of 16 address bytes.
    /// `inet_ntop` rather than hand-rolled hex: `::` elision has rules, and
    /// the string is handed to an SSH server that will parse it again.
    private static func ipv6Text(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { raw in
            raw.copyBytes(from: bytes)
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let rendered = withUnsafePointer(to: address) { pointer in
            inet_ntop(AF_INET6, pointer, &text, socklen_t(INET6_ADDRSTRLEN))
        }
        guard rendered != nil else { return nil }
        // Not `String(cString:)`: it is deprecated, and the array is
        // NUL-padded to `INET6_ADDRSTRLEN` rather than exactly terminated.
        return String(
            decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - The conversation

/// The SOCKS5 server side of one accepted connection.
///
/// **A hand-written `ChannelInboundHandler` with its own accumulator, not a
/// `ByteToMessageDecoder`.** The choice is about the END of the handshake,
/// not its parsing. A decoder inside `ByteToMessageHandler` gives up two
/// things this needs: it owns the buffered bytes, and it hands them on only
/// through `decodeLast` during a removal that `removeHandler` defers with
/// `eventLoop.execute` — while the moment those bytes must be delivered is
/// "after the `direct-tcpip` channel opened and the `BytePump` was added to
/// this pipeline", which is an `await` away from the last `decode` call and
/// invisible from inside one. Holding the accumulator here makes that a
/// plain sequence: write the reply, fire the leftovers at the pump, leave.
/// The framing itself stays pure and separately measurable in
/// `SOCKS5Frames`.
final class SOCKS5HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// Where the decoded destination (or the reason there is none) is
    /// published. The only member touched from off the event loop.
    let requested = SOCKS5RequestBox()

    private enum State {
        case greeting
        case request
        /// The destination is out; the channel through the server is being
        /// opened. Anything that arrives now is kept for the pump.
        case connecting
        /// The reply is written and this handler is on its way out of the
        /// pipeline; anything still arriving goes straight through.
        case handedOver
        case done
    }

    /// Touched only on the channel's event loop.
    private var state: State = .greeting
    private var accumulator = ByteBuffer()

    /// Reading is turned on HERE, on the event loop, and not by whoever
    /// installed this handler.
    ///
    /// The listener accepts with `autoRead` off — nothing may be read before
    /// there is somewhere to put it — so something has to turn it back on,
    /// and doing that from the accept task races NIO's registration of the
    /// accepted channel. `BaseSocketChannel.setOption0` only kicks a read
    /// when `lifecycleManager.isPreRegistered` ("this will be automatically
    /// done once register0 is called", `BaseSocketChannel.swift:700-707`),
    /// and `read0` (`:833-844`) latches `readPending = true` while
    /// registering interest only if pre-registered. Registration itself asks
    /// for `[.reset, .error]` and never consults `readPending`
    /// (`becomeFullyRegistered0`, `:1398`), and the `readIfNeeded0` that
    /// follows activation (`:755-765`) skips its `pipeline.read()` precisely
    /// BECAUSE `readPending` is already true. An early `setOption` + `read()`
    /// therefore leaves a channel that is open, active, and registered for no
    /// read interest at all — forever.
    ///
    /// Both entry points below run on the event loop and both imply
    /// registration, and exactly one of them fires: a handler added before
    /// activation sees `isActive == false` and gets `channelActive` later; a
    /// handler added after it sees `isActive == true` and will never get
    /// another `channelActive`.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { startReading(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        startReading(context: context)
        context.fireChannelActive()
    }

    private func startReading(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .handedOver = state {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        accumulator.writeBuffer(&incoming)
        advance(context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if case .handedOver = state { context.fireChannelReadComplete() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        requested.resolve(.failure(SOCKS5HandshakeError.closedBeforeARequest))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        requested.resolve(.failure(SOCKS5HandshakeError.closedBeforeARequest))
        context.close(promise: nil)
    }

    /// The channel through the SSH server is open and the pump is installed:
    /// tell the client, hand the pump whatever arrived in the meantime, and
    /// get out of the way.
    ///
    /// The order matters. The reply is written OUTBOUND (head-ward, so it
    /// reaches the socket) before the leftovers are fired INBOUND (tail-ward,
    /// so they reach the pump) — a client that pipelined its first request
    /// behind CONNECT must not see its own payload answered before the reply
    /// that says the tunnel is up.
    func succeed(on channel: Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.flatSubmit {
            let context: ChannelHandlerContext
            do {
                context = try channel.pipeline.syncOperations.context(handler: self)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
            self.state = .handedOver
            context.writeAndFlush(
                NIOAny(ByteBuffer(bytes: SOCKS5Frames.reply(.succeeded))), promise: nil)
            if self.accumulator.readableBytes > 0 {
                let leftovers = self.accumulator
                self.accumulator = ByteBuffer()
                context.fireChannelRead(NIOAny(leftovers))
                context.fireChannelReadComplete()
            }
            return channel.pipeline.removeHandler(self)
        }
    }

    /// The channel through the SSH server could not be opened: tell the
    /// client which kind of "no" it was, then close.
    /// **A reply frame is written only while the client is still waiting for
    /// one.** After `succeed` handed the connection over, the ten bytes of a
    /// reply are no longer a reply: they are ten bytes of `05 01 …` injected
    /// into an established payload stream, which the client would read as
    /// part of whatever it asked for. That is reachable — the accept path
    /// calls `reject` for a `pumpFailed` too, and `pumpFailed` is raised by
    /// `startReading`, which runs AFTER `confirm` — so the state is checked
    /// rather than assumed. In `.handedOver` and `.done` the connection is
    /// closed and nothing is written.
    func reject(_ code: SOCKS5ReplyCode, on channel: Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.flatSubmit {
            switch self.state {
            case .handedOver, .done:
                channel.close(promise: nil)
                return channel.eventLoop.makeSucceededVoidFuture()
            case .greeting, .request, .connecting:
                self.state = .done
                return channel.writeAndFlush(ByteBuffer(bytes: SOCKS5Frames.reply(code)))
                    .always { _ in channel.close(promise: nil) }
            }
        }
    }

    // MARK: - The state machine

    private func advance(context: ChannelHandlerContext) {
        while true {
            switch state {
            case .greeting:
                switch SOCKS5Frames.greeting(in: accumulator) {
                case .needMoreData:
                    return
                case .malformed:
                    refuse(nil, because: .malformedFrame, context: context)
                    return
                case .methods(let methods, let consumed):
                    consume(consumed)
                    guard methods.contains(SOCKS5Frames.noAuthentication) else {
                        refuse(
                            SOCKS5Frames.methodSelection(SOCKS5Frames.noAcceptableMethod),
                            because: .noAcceptableMethod, context: context)
                        return
                    }
                    context.writeAndFlush(
                        NIOAny(
                            ByteBuffer(
                                bytes: SOCKS5Frames.methodSelection(SOCKS5Frames.noAuthentication))),
                        promise: nil)
                    state = .request
                }
            case .request:
                switch SOCKS5Frames.request(in: accumulator) {
                case .needMoreData:
                    return
                case .malformed:
                    refuse(nil, because: .malformedFrame, context: context)
                    return
                case .unsupportedCommand:
                    refuse(
                        SOCKS5Frames.reply(.commandNotSupported), because: .unsupportedCommand,
                        context: context)
                    return
                case .unsupportedAddressType:
                    refuse(
                        SOCKS5Frames.reply(.addressTypeNotSupported),
                        because: .unsupportedAddressType, context: context)
                    return
                case .connect(let destination, let consumed):
                    consume(consumed)
                    state = .connecting
                    // Stop asking the socket for more while the channel
                    // through the server is opened. Whatever was already
                    // delivered stays in `accumulator` and is handed to the
                    // pump by `succeed`; the kernel's receive buffer holds
                    // the rest, which is the backpressure a bare `accumulate
                    // everything` would not have. `BytePump.startReading`
                    // turns reading back on.
                    context.channel.setOption(ChannelOptions.autoRead, value: false)
                        .whenFailure { _ in }
                    requested.resolve(.success(destination))
                    return
                }
            case .connecting, .handedOver, .done:
                return
            }
        }
    }

    private func consume(_ bytes: Int) {
        accumulator.moveReaderIndex(forwardBy: bytes)
        accumulator.discardReadBytes()
    }

    /// End the conversation: publish the reason, optionally write one last
    /// frame, and close once it is out. The close is chained to the write's
    /// completion rather than issued beside it, so the client reads the
    /// refusal instead of a bare disconnect.
    private func refuse(
        _ reply: [UInt8]?, because error: SOCKS5HandshakeError, context: ChannelHandlerContext
    ) {
        state = .done
        requested.resolve(.failure(error))
        let channel = context.channel
        guard let reply else {
            channel.close(promise: nil)
            return
        }
        context.writeAndFlush(NIOAny(ByteBuffer(bytes: reply)))
            .always { _ in channel.close(promise: nil) }
            .whenFailure { _ in }
    }
}

/// The one-shot handover of the decoded destination from the event loop to
/// the accept task waiting on it.
///
/// `NSLock` and not an actor, for the reason `BytePumpCounters` gives: it is
/// written from inside `channelRead` on an event loop, where there is no
/// `await`. Resolved at most once — a second `resolve` is dropped — so the
/// continuation is resumed exactly once however the conversation ends,
/// including `channelInactive` after a refusal has already been published.
final class SOCKS5RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<SOCKS5Destination, any Error>?
    private var waiter: CheckedContinuation<SOCKS5Destination, any Error>?

    /// What the conversation settled on, or `nil` while it is still running.
    var settled: Result<SOCKS5Destination, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    func resolve(_ result: Result<SOCKS5Destination, any Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func value() async throws -> SOCKS5Destination {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Installing the handshake on an accepted connection and driving it to the
/// point where a destination is known.
enum SOCKS5Handshake {
    /// Adds the handshake to `channel`, lets the client speak, and answers
    /// once it has named a destination.
    ///
    /// Nothing here touches `autoRead` or calls `read()`. The handler turns
    /// reading on itself, from `handlerAdded`/`channelActive` — see the long
    /// comment on those, which is the whole reason this function is three
    /// lines instead of five.
    static func negotiate(on channel: Channel) async throws -> any ForwardNegotiation {
        let handshake = SOCKS5HandshakeHandler()
        try await channel.pipeline.addHandler(handshake).get()
        let destination = try await handshake.requested.value()
        return SOCKS5Negotiation(handshake: handshake, destination: destination)
    }
}

/// One negotiated SOCKS5 connection, as the listener's accept path sees it.
private struct SOCKS5Negotiation: ForwardNegotiation {
    let handshake: SOCKS5HandshakeHandler
    let destination: SOCKS5Destination

    var host: String { destination.host }
    var port: Int { destination.port }

    func confirm(on channel: Channel) async throws {
        try await handshake.succeed(on: channel).get()
    }

    /// Best effort by construction: the client may already be gone, and a
    /// failure to tell it so must not replace the tunnel's own failure with
    /// a write error.
    func reject(_ failure: TunnelFailure, on channel: Channel) async {
        _ = try? await handshake.reject(SOCKS5ReplyCode(failure), on: channel).get()
    }
}
