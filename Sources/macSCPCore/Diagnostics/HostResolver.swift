import Darwin
import Foundation

/// One address `getaddrinfo` returned for a host, kept together with the
/// socket address the TCP ping then dials.
///
/// The bytes travel WITH the presentation form rather than being re-parsed
/// from it: re-parsing would lose the scope id an IPv6 link-local address
/// carries, and a probe that dialled a different address than the one it
/// printed would be reporting about something else.
struct ResolvedAddress: Sendable, Equatable {
    enum Family: String, Sendable, Equatable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
    }

    let family: Family
    /// Numeric presentation form, from `getnameinfo` with `NI_NUMERICHOST`.
    let text: String
    let socketAddress: ProbeSocketAddress
}

/// A `sockaddr` as bytes, so it can cross an `async` boundary.
///
/// `Probe`-prefixed because NIO exports a `SocketAddress` of its own, and
/// every file in this module that imports `NIOCore` would otherwise have to
/// disambiguate which one it meant — including files that have nothing to do
/// with diagnostics (`SSHAgentClient` was the one that failed to compile).
///
/// The bytes are copied back into a real `sockaddr_storage` before any call
/// reads them: a `[UInt8]`'s buffer is only guaranteed to be aligned for
/// `UInt8`, and `sockaddr_in6` wants more than that. Rebinding the array's
/// own memory would be an alignment bet that happens to win on this
/// allocator.
struct ProbeSocketAddress: Sendable, Equatable {
    private let bytes: [UInt8]

    init(_ pointer: UnsafePointer<sockaddr>, length: socklen_t) {
        bytes = [UInt8](
            UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(length)))
    }

    var length: socklen_t { socklen_t(bytes.count) }

    /// The address family the BYTES declare.
    ///
    /// Read from the `sockaddr` rather than from `ResolvedAddress.family`,
    /// which is a label for the report: what `socket` is asked to open has to
    /// be what `sendto` will dial, and the record's label is one copy of that
    /// fact while the bytes are the fact itself.
    var family: Int32 { withSockaddr { pointer, _ in Int32(pointer.pointee.sa_family) } }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var storage = sockaddr_storage()
        let copied = withUnsafeMutableBytes(of: &storage) { destination -> Int in
            let count = min(destination.count, bytes.count)
            bytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
            }
            return count
        }
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(copied))
            }
        }
    }
}

/// What a name lookup ended as.
enum HostResolverOutcome: Sendable, Equatable {
    case resolved([ResolvedAddress])
    /// `gai_strerror`'s own sentence — the resolver's answer, not this
    /// project's guess at what it meant.
    case failed(String)
    /// The deadline (or the calling task's cancellation) beat the resolver.
    case timedOut
}

/// `getaddrinfo`, off the cooperative pool and under a deadline.
///
/// `Host`-prefixed for the same reason `ProbeSocketAddress` is prefixed: NIO
/// exports a `Resolver` protocol, and a bare `Resolver` here made the name
/// ambiguous in every file that sees both modules — `ConnectMainActorLivenessTests`,
/// which conforms a fake to NIO's, stopped compiling.
enum HostResolver {
    /// - Parameter flags: `ai_flags`. Defaults to none, which is what a
    ///   diagnosis wants: every family the host has, resolved however the
    ///   machine resolves names. Tests pass `AI_NUMERICHOST` to provoke a
    ///   resolver error without putting a DNS query on the wire.
    static func resolve(
        host: String, port: Int, timeout: Duration, flags: Int32 = 0
    ) async -> HostResolverOutcome {
        await BlockingProbe.run(label: "dev.noidee.macscp.diagnostics.resolve", timeout: timeout) {
            lookUp(host: host, port: port, flags: flags)
        } ?? .timedOut
    }

    /// A NUL-terminated C buffer as a `String`, without `String(cString:)`'s
    /// deprecated array overload: truncate at the terminator, then decode.
    /// `getnameinfo` fills only as much of the buffer as the name needs, so
    /// decoding the whole `NI_MAXHOST` bytes would append 1000 NULs.
    private static func text(from buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    /// An address's numeric presentation form: `getnameinfo` with
    /// `NI_NUMERICHOST`, which never asks a resolver anything. `nil` for a
    /// record `getnameinfo` cannot render, which the callers skip.
    private static func numericText(_ raw: UnsafePointer<sockaddr>, _ length: socklen_t) -> String? {
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(raw, length, &name, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return text(from: name)
    }

    /// Blocking. Only ever called on `BlockingProbe`'s private queue.
    private static func lookUp(host: String, port: Int, flags: Int32) -> HostResolverOutcome {
        var hints = addrinfo()
        hints.ai_flags = flags
        // Both families, and TCP specifically: a `SOCK_STREAM`/`IPPROTO_TCP`
        // lookup returns one record per address rather than one per socket
        // type, so the list below is the list of ADDRESSES the connect would
        // try — which is exactly what the TCP ping walks.
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &head)
        defer { if let head { freeaddrinfo(head) } }
        guard status == 0 else {
            return .failed(String(cString: gai_strerror(status)))
        }

        var addresses: [ResolvedAddress] = []
        var node = head
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard let raw = current.pointee.ai_addr else { continue }
            let length = current.pointee.ai_addrlen
            guard let text = Self.numericText(raw, length) else { continue }
            // Duplicates are what a machine with several interfaces returns
            // for the same address; probing one twice would double the step's
            // duration and say nothing new.
            guard !addresses.contains(where: { $0.text == text }) else { continue }
            addresses.append(
                ResolvedAddress(
                    family: current.pointee.ai_family == AF_INET6 ? .ipv6 : .ipv4,
                    text: text,
                    socketAddress: ProbeSocketAddress(raw, length: length)))
        }
        // A zero-address success is not a success: `getaddrinfo` said yes and
        // there is nothing to dial, which is a failure of the lookup however
        // it is spelled.
        guard !addresses.isEmpty else { return .failed("no address returned") }
        return .resolved(addresses)
    }
}

// MARK: - Naming an address

extension HostResolver {
    /// The name the machine's resolver gives an address, and whether that
    /// name leads back to it — the two blocking halves of the resolve step's
    /// name table (`ResolveLookups.live`). Both only ever run on
    /// `BlockingProbe`'s private queue.
    ///
    /// **Reverse**: `getnameinfo` with `NI_NAMEREQD` and no other flag. The
    /// flag is what makes it a question at all — without it `getnameinfo`
    /// falls back to the numeric form, and "no name" would come back as the
    /// address itself. No `NI_NOFQDN` (the whole name is the finding) and no
    /// `NI_NUMERICHOST` (that is the resolve's own rendering, which asks
    /// nobody). What answers is the machine's resolver, as for every other
    /// lookup here — the hosts file and DNS's PTR records, in whatever order
    /// the system resolver consults them. Which of the two named `127.0.0.1`
    /// in `ResolveNamesTests` was not measured; that a name came back and
    /// resolved back was.
    static func reverseLookUp(_ address: ProbeSocketAddress) -> ResolveLookups.Reverse {
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = address.withSockaddr { raw, length in
            getnameinfo(raw, length, &name, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
        }
        switch status {
        case 0:
            let text = text(from: name)
            return text.isEmpty ? .noName : .name(text)
        case EAI_NONAME:
            return .noName
        default:
            return .failed(String(cString: gai_strerror(status)))
        }
    }

    /// **Forward**: `getaddrinfo` for the name, in the address's own family
    /// only, so confirming an IPv4 address asks for A records and never puts
    /// an AAAA query on the wire for nothing. The same TCP hints as the
    /// resolve, and no `ai_flags`: the name is resolved however the machine
    /// resolves names, which is the question. Each answer in its numeric
    /// form, the spelling `ResolvedAddress.text` has.
    static func forwardLookUp(
        _ name: String, family: ResolvedAddress.Family
    ) -> ResolveLookups.Forward {
        var hints = addrinfo()
        hints.ai_family = family == .ipv6 ? AF_INET6 : AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &head)
        defer { if let head { freeaddrinfo(head) } }
        // "No such name" and "no record of this family" are both the name not
        // leading back — findings about the name, not about the lookup.
        if status == EAI_NONAME || status == EAI_NODATA { return .noAddress }
        guard status == 0 else { return .failed(String(cString: gai_strerror(status))) }

        var addresses: [String] = []
        var node = head
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard let raw = current.pointee.ai_addr,
                let text = numericText(raw, current.pointee.ai_addrlen),
                !addresses.contains(text)
            else { continue }
            addresses.append(text)
        }
        return addresses.isEmpty ? .noAddress : .addresses(addresses)
    }
}
