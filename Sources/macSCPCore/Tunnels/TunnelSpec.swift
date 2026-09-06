import Foundation

/// Why a piece of text is not a forwarding specification.
///
/// Every case renders an English sentence naming the text it refused, because
/// the command line prints it verbatim and CLI output is not localized. A
/// spec carries no secret — it is a bind address, a port, a host name and a
/// port — so naming the offending text here is safe in a way that naming an
/// arbitrary error's contents is not.
public enum TunnelSpecError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The text does not have the field count, or the field contents, any of
    /// the three shapes accepts. Carries the WHOLE spec rather than the one
    /// bad field: which field is wrong is often the reader's disagreement
    /// with where the colons fall, so showing the fragment would hide the
    /// cause.
    case malformed(String)
    /// A field parsed as a number that is not a TCP port.
    case portOutOfRange(Int)
    /// A remote forwarding asked the server to choose the port. See
    /// `CitadelFileSystem.withRemotePortForward`, which refuses the same
    /// thing for the same reason one layer down.
    case remotePortZero

    public var description: String {
        switch self {
        case .malformed(let spec):
            return "not a forwarding spec: \"\(spec)\" — expected "
                + "[bind:]port:host:hostport, or [bind:]port for a dynamic forward"
        case .portOutOfRange(let port):
            return "port \(port) is out of range (0-65535)"
        case .remotePortZero:
            return "a remote forwarding cannot listen on port 0 — it must name the port "
                + "the server listens on, because this client cannot learn a port the "
                + "server chose for itself"
        }
    }
}

/// OpenSSH forwarding notation, parsed into `TunnelProfile.Kind` and rendered
/// back out.
///
/// One place, because more than one caller needs the same answer: the command
/// line takes a spec on `-L`/`-R`/`-D`, the app shows one in a profile row,
/// and the matrix tests compare what one produced against what the other
/// read. A second parser would disagree about the bind default long before it
/// disagreed about anything visible.
///
/// **The grammar**, the same OpenSSH's `ssh(1)` accepts:
///
/// | Shape | Notation |
/// |---|---|
/// | local (`-L`) | `[bind:]port:host:hostport` |
/// | remote (`-R`) | `[bind:]port:host:hostport` |
/// | dynamic (`-D`) | `[bind:]port` |
///
/// The bind address defaults to `127.0.0.1` when it is left out — loopback,
/// never `0.0.0.0`: a forward that listens on every interface is a decision
/// somebody makes by typing it, not one they inherit by leaving a field
/// blank. An IPv6 literal is written in brackets on either side of the
/// colon-separated form (`[::1]:8080:db:5432`, `8080:[::1]:5432`), which is
/// what makes the notation parsable at all — the brackets are notation and
/// are not part of the address.
///
/// **Port 0 is allowed on this machine's listener and refused on the
/// server's.** A local or dynamic forward configured on port 0 binds an
/// ephemeral port and reports the number back (`LocalForwardListener
/// .boundPort`, `SOCKS5Listener.boundPort`). A remote forward cannot: the
/// pinned Citadel registers its channel handler under the port that was
/// REQUESTED, so a server-chosen port never matches and every connection is
/// swallowed inside the library. `CitadelFileSystem.withRemotePortForward`
/// carries the measurement; `parse(remote:)` refuses the spec before a dial
/// is even attempted so the message names the spec rather than the dial.
public enum TunnelSpec {
    /// The bind address a spec that omits one means.
    public static let defaultBind = "127.0.0.1"

    // MARK: - Parsing

    public static func parse(local spec: String) throws -> TunnelProfile.Kind {
        let forward = try forward(spec)
        return .local(
            bind: forward.bind, localPort: forward.listenPort,
            host: forward.host, remotePort: forward.hostPort)
    }

    public static func parse(remote spec: String) throws -> TunnelProfile.Kind {
        let forward = try forward(spec)
        guard forward.listenPort != 0 else { throw TunnelSpecError.remotePortZero }
        return .remote(
            bind: forward.bind, remotePort: forward.listenPort,
            localHost: forward.host, localPort: forward.hostPort)
    }

    public static func parse(dynamic spec: String) throws -> TunnelProfile.Kind {
        guard let fields = fields(in: spec) else { throw TunnelSpecError.malformed(spec) }
        switch fields.count {
        case 1:
            return .dynamic(bind: defaultBind, localPort: try port(fields[0], in: spec))
        case 2:
            return .dynamic(bind: fields[0], localPort: try port(fields[1], in: spec))
        default:
            throw TunnelSpecError.malformed(spec)
        }
    }

    // MARK: - Rendering

    /// The canonical spelling of a kind: the bind address always written out,
    /// IPv6 literals bracketed.
    ///
    /// Canonical rather than "as typed" on purpose — a stored profile keeps
    /// the parsed fields, not the text, so there is nothing to reproduce.
    /// Writing the default bind out is the point: a row that reads
    /// `127.0.0.1:8080:db:5432` says which interface it listens on, where
    /// `8080:db:5432` leaves the reader to remember the default.
    public static func render(_ kind: TunnelProfile.Kind) -> String {
        switch kind {
        case .local(let bind, let localPort, let host, let remotePort):
            return "\(literal(bind)):\(localPort):\(literal(host)):\(remotePort)"
        case .remote(let bind, let remotePort, let localHost, let localPort):
            return "\(literal(bind)):\(remotePort):\(literal(localHost)):\(localPort)"
        case .dynamic(let bind, let localPort):
            return "\(literal(bind)):\(localPort)"
        }
    }

    // MARK: - Internals

    /// The four values both `-L` and `-R` carry. The two shapes differ only
    /// in which end of the pair listens, which is why they share a parser
    /// and not a case.
    private struct Forward {
        let bind: String
        /// The port whichever end listens binds — this Mac's for `-L`, the
        /// server's for `-R`.
        let listenPort: Int
        let host: String
        let hostPort: Int
    }

    private static func forward(_ spec: String) throws -> Forward {
        guard let fields = fields(in: spec), (3...4).contains(fields.count) else {
            throw TunnelSpecError.malformed(spec)
        }
        let bind = fields.count == 4 ? fields[0] : defaultBind
        let rest = fields.count == 4 ? Array(fields.dropFirst()) : fields
        return Forward(
            bind: bind,
            listenPort: try port(rest[0], in: spec),
            host: rest[1],
            hostPort: try port(rest[2], in: spec))
    }

    /// Splits on `:`, treating a bracketed group as one field.
    ///
    /// Returns `nil` — never an empty or partial list — for anything that is
    /// not splittable at all: an unclosed bracket, an empty field, a leading
    /// or trailing colon, or text following a `]` that is not a separator.
    /// The caller turns that into `.malformed` with the whole spec, so this
    /// function never has to decide what to say about it.
    private static func fields(in text: String) -> [String]? {
        var fields: [String] = []
        var rest = Substring(text)
        while true {
            let field: String
            if rest.first == "[" {
                guard let close = rest.firstIndex(of: "]") else { return nil }
                field = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                // Only a separator or the end may follow a bracketed field:
                // `[::1]x:1` is not an address followed by anything.
                guard rest.isEmpty || rest.first == ":" else { return nil }
            } else if let separator = rest.firstIndex(of: ":") {
                field = String(rest[..<separator])
                rest = rest[separator...]
            } else {
                field = String(rest)
                rest = rest[rest.endIndex...]
            }
            guard field.isEmpty == false else { return nil }
            fields.append(field)
            if rest.isEmpty { return fields }
            rest = rest.dropFirst()  // the separator
            guard rest.isEmpty == false else { return nil }  // a trailing colon
        }
    }

    /// A TCP port, or a refusal naming the whole spec.
    ///
    /// ASCII digits only: `Character.isNumber` is true of digits no
    /// initializer here accepts, and a field that looks numeric to a reader
    /// and not to `Int` would otherwise be refused with a message about the
    /// wrong thing. A run of digits too long for `Int` is `.malformed` rather
    /// than `.portOutOfRange`, because there is no number to name.
    private static func port(_ text: String, in spec: String) throws -> Int {
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text) else {
            throw TunnelSpecError.malformed(spec)
        }
        guard (0...65535).contains(value) else { throw TunnelSpecError.portOutOfRange(value) }
        return value
    }

    /// Brackets an address that needs them. An IPv6 literal is the only
    /// address containing a colon, and a colon is the separator.
    private static func literal(_ address: String) -> String {
        address.contains(":") ? "[\(address)]" : address
    }
}
