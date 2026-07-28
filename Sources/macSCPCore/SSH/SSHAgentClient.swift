import Foundation
import NIOCore
import NIOPosix

/// Transport abstraction for the ssh-agent protocol: exactly one framed
/// request out, one framed response in. Production talks over the Unix
/// domain socket named by `SSH_AUTH_SOCK` via NIO; tests substitute a mock
/// that records requests and replays canned responses.
public protocol SSHAgentTransport: Sendable {
    func roundTrip(_ request: Data) async throws -> Data
    func close() async
}

/// A client for the ssh-agent wire protocol (draft-miller). Framing/parsing
/// is delegated to the pure `SSHAgentCodec`; I/O is delegated to an
/// injectable `SSHAgentTransport`.
public final class SSHAgentClient: Sendable {
    private let transport: SSHAgentTransport

    public init(transport: SSHAgentTransport) {
        self.transport = transport
    }

    /// Connects to the ssh-agent listening on the given Unix domain socket
    /// path (typically the value of `SSH_AUTH_SOCK`). Any failure to
    /// establish the connection — missing socket file, nothing listening,
    /// permission denied — is surfaced as `.socketUnavailable`.
    public static func connect(socketPath: String) async throws -> SSHAgentClient {
        do {
            let transport = try await NIOUnixSocketAgentTransport.connect(socketPath: socketPath)
            return SSHAgentClient(transport: transport)
        } catch {
            throw AgentError.socketUnavailable
        }
    }

    /// Lists the identities the agent currently holds.
    public func listIdentities() async throws -> [AgentIdentity] {
        let response = try await performRoundTrip(SSHAgentCodec.requestIdentitiesFrame())
        return try SSHAgentCodec.parseIdentitiesAnswer(response)
    }

    /// Asks the agent to sign `data` with the private key matching
    /// `publicKeyBlob`. Returns the raw `string signature` payload (still
    /// SSH-encoded: algorithm name + signature blob) — T2 decodes it.
    public func sign(publicKeyBlob: Data, data: Data, flags: UInt32) async throws -> Data {
        let request = SSHAgentCodec.signRequestFrame(
            publicKeyBlob: publicKeyBlob, data: data, flags: flags)
        let response = try await performRoundTrip(request)
        return try SSHAgentCodec.parseSignResponse(response)
    }

    public func close() async {
        await transport.close()
    }

    /// Runs one request/response cycle over the transport. Any error the
    /// transport raises while ALREADY connected (as opposed to a connect-time
    /// failure, which becomes `.socketUnavailable` in `connect(socketPath:)`)
    /// is reported as `.protocolError` — the agent connection is only ever
    /// established once, so an in-flight I/O failure is a protocol-level
    /// problem for the caller, not a "no agent" condition.
    private func performRoundTrip(_ request: Data) async throws -> Data {
        do {
            return try await transport.roundTrip(request)
        } catch {
            throw AgentError.protocolError(reason: "\(error)")
        }
    }
}

// MARK: - Production transport (NIO over a Unix domain socket)

/// The production `SSHAgentTransport`: a single NIO channel over a Unix
/// domain socket. ssh-agent connections are used strictly serially by
/// `SSHAgentClient` (list once, then sign one identity at a time), so this
/// transport only ever has one request in flight at a time.
final class NIOUnixSocketAgentTransport: SSHAgentTransport, @unchecked Sendable {
    /// How long to wait for a response before failing with a timeout.
    private static let responseDeadline: TimeAmount = .seconds(10)

    private let channel: Channel
    private let group: EventLoopGroup
    private let handler: FrameAccumulatingHandler

    private init(channel: Channel, group: EventLoopGroup, handler: FrameAccumulatingHandler) {
        self.channel = channel
        self.group = group
        self.handler = handler
    }

    static func connect(socketPath: String) async throws -> NIOUnixSocketAgentTransport {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = FrameAccumulatingHandler()
        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
            let address = try SocketAddress(unixDomainSocketPath: socketPath)
            let channel = try await bootstrap.connect(to: address).get()
            return NIOUnixSocketAgentTransport(channel: channel, group: group, handler: handler)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func roundTrip(_ request: Data) async throws -> Data {
        try await handler.send(request, over: channel, deadline: Self.responseDeadline).get()
    }

    func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

/// Accumulates inbound bytes until exactly one length-prefixed ssh-agent
/// frame is available, then completes the pending promise. All mutable
/// state is only ever touched on the channel's event loop (either directly,
/// as NIO guarantees for channel callbacks, or via `eventLoop.execute` from
/// `send`), so the `@unchecked Sendable` below is safe.
private final class FrameAccumulatingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 0)
    private var promise: EventLoopPromise<Data>?
    private var timeoutTask: Scheduled<Void>?

    /// Sends `request` and returns a future for the next complete response
    /// frame, failing with `.protocolError("timeout")` if none arrives
    /// within `deadline`.
    func send(_ request: Data, over channel: Channel, deadline: TimeAmount) -> EventLoopFuture<Data> {
        let eventLoop = channel.eventLoop
        let promise = eventLoop.makePromise(of: Data.self)
        eventLoop.execute {
            self.buffer.clear()
            self.promise = promise
            var outbound = channel.allocator.buffer(capacity: request.count)
            outbound.writeBytes(request)
            channel.writeAndFlush(outbound, promise: nil)
            self.timeoutTask = eventLoop.scheduleTask(in: deadline) {
                guard self.promise != nil else { return }
                self.promise = nil
                promise.fail(AgentError.protocolError(reason: "timeout"))
            }
        }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        tryCompletePendingRequest()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completePending(with: .failure(error))
    }

    func channelInactive(context: ChannelHandlerContext) {
        completePending(with: .failure(AgentError.protocolError(reason: "agent connection closed")))
    }

    /// Reads the outer `uint32` length (without consuming) to decide whether
    /// a full frame is buffered yet; only then consumes and completes.
    private func tryCompletePendingRequest() {
        guard promise != nil else { return }
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
            return
        }
        let total = 4 + Int(length)
        guard buffer.readableBytes >= total, let frameBytes = buffer.readBytes(length: total) else {
            return
        }
        completePending(with: .success(Data(frameBytes)))
    }

    private func completePending(with result: Result<Data, Error>) {
        guard let promise else { return }
        self.promise = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        switch result {
        case .success(let data): promise.succeed(data)
        case .failure(let error): promise.fail(error)
        }
    }
}
