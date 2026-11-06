import Foundation

/// Where a passive reply says a data connection goes.
///
/// A value, not a string pair at a call site, so the one function that
/// decides whether an address may be dialled has a return type that says what
/// it produced.
struct FTPDataEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
}

/// One whole FTP transfer: the passive negotiation, the data connection, the
/// optional restart marker, the transfer command and both of its replies.
///
/// **This is the only place in the backend that opens a data connection**, and
/// it opens it through `FTPControlConnection.openDataConnection(host:port:)` —
/// the instance method, which derives the owner and the protection from the
/// connection itself. The static that takes an `owner:` argument, and refuses
/// a mismatch at run time, has no caller here: a data connection paired with
/// another control connection's TLS session is not something that can be
/// written on this path (CLAUDE.md, "Guards that name what they watch" —
/// prefer a violation that will not compile to one more anchor).
///
/// **The drain runs with the command turn HELD**, because
/// `FTPControlConnection.transferCommand` holds it across both of a
/// transfer's replies. So nothing here issues a command on the same
/// connection between the `150` and the `226`; a caller that needs one takes
/// a second connection, which is what `FTPConnectionPool` is for.
enum FTPDataConnection {
    /// RFC 2428's `229 Entering Extended Passive Mode`.
    private static let extendedPassiveAccepted = 229
    /// RFC 959's `227 Entering Passive Mode`.
    private static let passiveAccepted = 227
    /// `350 Requested file action pending further information`, the reply
    /// `REST` is answered with (RFC 3659 section 5.4).
    private static let restartAccepted = 350
    /// The refusal a server with `require_ssl_reuse` answers a data
    /// connection it will not accept with.
    private static let sessionReuseRefused = 522
    /// How many times a transfer refused for session reuse is attempted. Two:
    /// one try and one retry. A `522` reaching the user is a diagnosis nobody
    /// can act on, and a loop is worse than either.
    private static let attemptsOnSessionRefusal = 2

    // MARK: - Reading a passive reply

    /// The endpoint a `229` names, or a refusal.
    ///
    /// RFC 2428 section 3: the reply's parenthesised field is
    /// `<d><net-prt><d><net-addr><d><tcp-port><d>` where `<d>` is any
    /// printable ASCII character the server picks, and a server answering
    /// `EPSV` normally leaves the first two empty. An address that IS named
    /// goes through the same comparison a `227`'s does, so there is one rule
    /// and not two.
    static func extendedPassiveEndpoint(
        _ reply: FTPReply, peerHost: String
    ) throws -> FTPDataEndpoint {
        guard let field = Self.parenthesised(reply) else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        let delimiter = field.first
        guard let delimiter else { throw FTPConnectionFailure.passiveAddressRefused }
        // Four fields with the trailing delimiter, five parts when split.
        let parts = field.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[4].isEmpty else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        let named = String(parts[2])
        guard named.isEmpty || named == peerHost else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        guard let port = Int(parts[3]), (1...65535).contains(port) else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        return FTPDataEndpoint(host: peerHost, port: port)
    }

    /// The endpoint a `227` names, or a refusal.
    ///
    /// Four ways to be unusable, and the fourth is the one with teeth: an
    /// address that is not the peer the control connection is talking to.
    /// See `FTPConnectionFailure.passiveAddressRefused` for why it is refused
    /// rather than substituted or dialled, and for the interop cost that
    /// carries.
    static func passiveEndpoint(_ reply: FTPReply, peerHost: String) throws -> FTPDataEndpoint {
        guard let field = Self.parenthesised(reply) else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        // Parsed with `map` and counted twice, not `compactMap` and counted
        // once: a field that is not a number must be a refusal, and
        // compacting it away would leave six good numbers out of seven and
        // read as a well-formed reply.
        let parsed = field.split(separator: ",").map {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard parsed.count == 6 else { throw FTPConnectionFailure.passiveAddressRefused }
        let octets = parsed.compactMap { $0 }
        guard octets.count == 6, octets.allSatisfy({ (0...255).contains($0) }) else {
            throw FTPConnectionFailure.passiveAddressRefused
        }
        let named = octets[0..<4].map(String.init).joined(separator: ".")
        guard named == peerHost else { throw FTPConnectionFailure.passiveAddressRefused }
        let port = octets[4] * 256 + octets[5]
        guard port > 0 else { throw FTPConnectionFailure.passiveAddressRefused }
        return FTPDataEndpoint(host: peerHost, port: port)
    }

    /// What stands between the FIRST `(` and the LAST `)` of a reply's text,
    /// or `nil` when the reply has no such pair.
    ///
    /// Outermost rather than first-to-first: a server's human text before the
    /// address may carry parentheses of its own, and the address is the last
    /// thing on the line.
    private static func parenthesised(_ reply: FTPReply) -> String? {
        let text = reply.lines.joined(separator: " ")
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
            open < close
        else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    // MARK: - Opening

    /// A data connection on `control`, negotiated passively.
    ///
    /// `EPSV` first, `PASV` after it. The preference is not a taste: `EPSV`
    /// carries no address at all, so the question
    /// `passiveEndpoint(_:peerHost:)` has to answer — may this address be
    /// dialled — never arises on the preferred path. A server that refuses
    /// `EPSV` is remembered on the connection, so the extra round trip is
    /// paid once rather than once per transfer.
    ///
    /// Active mode (`PORT`) is not here and is not planned: it needs the
    /// client to listen, which is what firewalls and NAT have made
    /// unworkable, and it is why passive mode exists.
    static func openPassive(on control: FTPControlConnection) async throws -> FTPDataChannel {
        let prefersClassic = await control.prefersClassicPassive
        if !prefersClassic {
            let extended = try await control.send("EPSV", argument: nil)
            if extended.code == Self.extendedPassiveAccepted {
                let endpoint = try Self.extendedPassiveEndpoint(
                    extended, peerHost: control.peerHost)
                return try await control.openDataConnection(
                    host: endpoint.host, port: endpoint.port)
            }
            await control.noteExtendedPassiveRefused()
        }
        let classic = try await control.send("PASV", argument: nil)
        guard classic.code == Self.passiveAccepted else {
            throw FTPConnectionFailure.passiveModeRefused(code: classic.code)
        }
        let endpoint = try Self.passiveEndpoint(classic, peerHost: control.peerHost)
        return try await control.openDataConnection(host: endpoint.host, port: endpoint.port)
    }

    // MARK: - One transfer

    /// Runs one transfer command on `control` and hands its data connection
    /// to `body`.
    ///
    /// `restartingAt` is `REST`'s marker, sent before the transfer command
    /// and only when it is asked for. A refused `REST` ends the transfer
    /// here: see `FTPConnectionFailure.restRefused`.
    ///
    /// **The data connection is closed on every exit from `body`**, before
    /// the completion reply is read. It has to be: a server that is still
    /// writing into a socket nobody drains does not get to its `226`, so a
    /// drain that gave up without closing would park the completion reply
    /// until the reply bound. Closing is idempotent, so the close on the
    /// refusal path below cannot return a TLS session twice.
    ///
    /// **`body` is `@Sendable`, and that is forced rather than chosen.** It
    /// is handed to `FTPControlConnection.transferCommand`, which is an
    /// actor's method, so the drain closure crosses an isolation boundary;
    /// and the retry below may cross it twice, which rules out `sending` —
    /// a `sending` value may be sent once. So a drain that accumulates
    /// cannot capture a mutable local: it takes a sink of its own, which is
    /// what a drain writing to a file does anyway.
    static func transfer(
        _ command: String, argument: String? = nil,
        restartingAt offset: Int64? = nil,
        on control: FTPControlConnection,
        draining body: @Sendable (FTPDataChannel) async throws -> Void
    ) async throws {
        var attempt = 1
        while true {
            if let offset {
                let marker = try await control.send("REST", argument: String(offset))
                guard marker.code == Self.restartAccepted else {
                    throw FTPConnectionFailure.restRefused(code: marker.code)
                }
            }
            let channel = try await Self.openPassive(on: control)
            let replies: (opening: FTPReply, completion: FTPReply?)
            do {
                replies = try await control.transferCommand(command, argument: argument) {
                    do {
                        try await body(channel)
                        await channel.close()
                    } catch {
                        await channel.close()
                        throw error
                    }
                }
            } catch {
                await channel.close()
                throw error
            }

            guard replies.opening.isPreliminary else {
                // The body never ran — only a preliminary reply promises a
                // second one — so the channel is still this function's to
                // close.
                let refusedTheSession = replies.opening.code == Self.sessionReuseRefused
                let resumed = channel.didResumeTLSSession
                await channel.close(returningSession: !(refusedTheSession && resumed))
                if refusedTheSession, attempt < Self.attemptsOnSessionRefusal {
                    attempt += 1
                    continue
                }
                throw FTPConnectionFailure.transferRefused(code: replies.opening.code)
            }
            guard let completion = replies.completion, completion.isPositiveCompletion else {
                throw FTPConnectionFailure.transferRefused(
                    code: replies.completion?.code ?? replies.opening.code)
            }
            return
        }
    }
}
