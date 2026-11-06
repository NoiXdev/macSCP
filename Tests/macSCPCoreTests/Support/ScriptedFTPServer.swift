import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// A control connection with a SCRIPT instead of a protocol: it writes a
/// greeting, answers each command line from a queue in order, and goes silent
/// once the queue runs out.
///
/// **Why this exists beside `LoopbackFTPServer`.** That one is a real FTP
/// server and answers like one, which is what nearly every test wants. The
/// reply-code rules a control connection has to enforce are about replies a
/// well-behaved server does not send: a `120` in front of the greeting (RFC
/// 959 section 5.4 allows it), a `332 Need account for login` where a `230`
/// belongs, a `334` to `AUTH TLS`, and silence where a reply belongs. Four
/// more seams on the real fixture would be four more ways for it to be wrong
/// about FTP; this speaks no FTP at all, so it cannot disagree with itself.
///
/// It also records whether the CLIENT closed the socket, which is the only
/// way to see from outside that a connection whose reply bound fired took
/// itself down.
actor ScriptedFTPServer {
    /// What the server writes before any command arrives, one reply per
    /// element, each element one or more lines.
    private let greeting: [[String]]
    /// The replies to the commands that arrive, in order. A command that
    /// arrives after the last one is answered with nothing at all.
    private let replies: [[String]]
    private let state = ScriptedFTPState()

    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?

    init(greeting: [[String]], replies: [[String]]) {
        self.greeting = greeting
        self.replies = replies
    }

    /// Binds `127.0.0.1` on a port the kernel picks.
    func start() async throws -> (host: String, port: Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = self.state
        let greeting = self.greeting
        state.load(replies)
        let bound: Channel
        do {
            bound = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(CRLFLineDecoder()))
                        try channel.pipeline.syncOperations.addHandler(
                            ScriptedFTPHandler(greeting: greeting, state: state))
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        self.group = group
        self.listener = bound
        guard let port = bound.localAddress?.port else {
            try? await bound.close().get()
            try? await group.shutdownGracefully()
            throw ScriptedFTPServerError.noLocalPort
        }
        return ("127.0.0.1", port)
    }

    /// Closes the listener and takes the loop down, which closes whatever is
    /// still connected. Idempotent.
    func stop() async {
        if let listener {
            self.listener = nil
            _ = try? await listener.close().get()
        }
        if let group {
            self.group = nil
            try? await group.shutdownGracefully()
        }
    }

    /// The command lines that arrived, as the server saw them.
    ///
    /// **A `PASS` argument is never stored**, for the reason
    /// `LoopbackFTPReceivedCommand` gives: a test that asks "did a credential
    /// reach the wire" needs the verb, and a failed `#expect` prints every
    /// operand it touched.
    var receivedCommands: [String] { state.commands }

    /// The client closed its end.
    var peerClosed: Bool { state.peerClosed }
}

enum ScriptedFTPServerError: Error, Equatable {
    case noLocalPort
}

/// What the scripted server records and what it has left to say. A class with
/// a `Mutex` rather than actor state, because the handler writes to it from
/// the event loop, in the callback that learns of each line.
final class ScriptedFTPState: Sendable {
    private struct Inner {
        var commands: [String] = []
        var replies: [[String]] = []
        var peerClosed = false
    }

    private let inner = Mutex(Inner())

    var commands: [String] { inner.withLock { $0.commands } }
    var peerClosed: Bool { inner.withLock { $0.peerClosed } }

    func load(_ replies: [[String]]) {
        inner.withLock { $0.replies = replies }
    }

    /// Records the line and takes the next reply, or `nil` when the script is
    /// exhausted — which is this fixture's "silence".
    func answer(to line: String) -> [String]? {
        inner.withLock { inner in
            let verb = String(line.split(separator: " ").first ?? "")
            inner.commands.append(verb == "PASS" ? verb : line)
            guard !inner.replies.isEmpty else { return nil }
            return inner.replies.removeFirst()
        }
    }

    func notePeerClosed() {
        inner.withLock { $0.peerClosed = true }
    }
}

/// Writes the greeting when the connection opens and one scripted reply per
/// command line.
final class ScriptedFTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let greeting: [[String]]
    private let state: ScriptedFTPState

    init(greeting: [[String]], state: ScriptedFTPState) {
        self.greeting = greeting
        self.state = state
    }

    func channelActive(context: ChannelHandlerContext) {
        for reply in greeting { Self.write(reply, to: context) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = String(buffer: unwrapInboundIn(data))
        guard let reply = state.answer(to: line) else { return }
        Self.write(reply, to: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.notePeerClosed()
        context.fireChannelInactive()
    }

    private static func write(_ reply: [String], to context: ChannelHandlerContext) {
        var text = ""
        for line in reply { text += line + "\r\n" }
        context.writeAndFlush(NIOAny(ByteBuffer(string: text)), promise: nil)
    }
}
