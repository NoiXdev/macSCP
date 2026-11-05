import Foundation

/// FTP's field identifiers -- the single source for its two schemas, its
/// config factory and (once the stored block exists) its persistence adapter.
public enum FTPField: String, CaseIterable, BackendFieldID {
    case host, port, security, initialPath, username, password

    public static let namespace = "FTPField"
}

/// FTP's data-driven registration, modelled on `WebDAVFieldSchema`.
/// Everything the generic layers need to know about FTP lives here; nothing
/// outside the descriptor branches on `.ftp` except the places that hold a
/// per-kind stored block.
public enum FTPFieldSchema {
    /// The three security modes, addressed by `FTPSecurityMode`'s raw values
    /// so a picked option IS the persisted value, with no mapping table
    /// between them.
    private static let securityOptions = [
        FieldOption(id: FTPSecurityMode.plain.rawValue,
                    labelKey: "connection.ftp.security.plain",
                    labelDefault: "None (plain FTP)"),
        FieldOption(id: FTPSecurityMode.explicitTLS.rawValue,
                    labelKey: "connection.ftp.security.explicitTLS",
                    labelDefault: "Explicit FTPS (recommended)"),
        FieldOption(id: FTPSecurityMode.implicitTLS.rawValue,
                    labelKey: "connection.ftp.security.implicitTLS",
                    labelDefault: "Implicit FTPS"),
    ]

    /// Where to dial and how to protect it. `host` and `port`, plus
    /// `username` in the credential schema, are what make an FTP connection
    /// distinct on import. The security mode is NOT identifying: the same
    /// server reached plain or upgraded is one machine addressed two ways, as
    /// S3's `usePathStyle` is.
    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: FTPField.host.rawValue,
                            labelKey: "connection.field.host",
                            labelDefault: "Host", kind: .text,
                            isRequired: true,
                            // ONE key covers a blank host and a host with
                            // user-info in it (the field's `format` below),
                            // as S3's endpoint does; the text names both.
                            format: .hostWithoutUserinfo,
                            invalidMessageKey: "core.connect.ftpHostInvalid",
                            identity: .caseInsensitive),
            ConnectionField(id: FTPField.port.rawValue,
                            labelKey: "connection.field.port",
                            labelDefault: "Port", kind: .number,
                            format: .numeric,
                            invalidMessageKey: "core.connect.portNumeric",
                            identity: .verbatim),
            ConnectionField(id: FTPField.security.rawValue,
                            labelKey: "connection.ftp.security",
                            labelDefault: "Security",
                            kind: .picker(.fixed(securityOptions))),
            ConnectionField(id: FTPField.initialPath.rawValue,
                            labelKey: "connection.ftp.initialPath",
                            labelDefault: "Initial folder", kind: .text),
        ],
        presets: [])

    /// What a brand-new FTP form starts with. Explicit FTPS, because the
    /// default of a form is what most connections get, and the safe mode
    /// should be the one nobody has to choose. The port is written out
    /// because a blank port field would be refused by `.numeric`.
    public static let defaults: FieldValues = {
        var values = FieldValues()
        values[FTPField.security] = FTPSecurityMode.explicitTLS.rawValue
        values[FTPField.port] = String(FTPSecurityMode.explicitTLS.defaultPort)
        return values
    }()

    /// What a login set carries: the credentials, not the server.
    ///
    /// NEITHER field is required, for the reason `WebDAVFieldSchema
    /// .credential` gives: anonymous FTP is the oldest real deployment this
    /// protocol has, and marking these required would refuse it before the
    /// connect was attempted.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: FTPField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "Username", kind: .text,
                            identity: .verbatim),
            ConnectionField(id: FTPField.password.rawValue,
                            labelKey: "connection.auth.password",
                            labelDefault: "Password", kind: .secret,
                            secretRole: .credential),
        ],
        presets: [])

    // MARK: - Reading the fields

    /// Whether the text carries user-info or a scheme: an `@` anywhere, or
    /// `://`. The shapes of a pasted `ftp://user:secret@host/`, and of
    /// `user@host` typed into the wrong field. A host never holds a
    /// credential, so no view that renders one needs to filter it
    /// (`SessionCatalog.target(for:)` and the overview's host fact print it
    /// as stored), and this is the one place to get that right.
    public static func hostCarriesUserinfo(_ text: String) -> Bool {
        text.contains("@") || text.contains("://")
    }

    /// The host as a connectable name, or nil when the text names none.
    ///
    /// Trimmed. A bracketed IPv6 literal loses its brackets (the dial wants
    /// the bare address). What is refused is everything a host name cannot
    /// be: blank, user-info or a scheme (`hostCarriesUserinfo`), any
    /// whitespace or control character, and the characters that make this a
    /// path or a URL (`/ ? #` and stray brackets).
    ///
    /// **A `:` is deliberately NOT refused and not validated.** An IPv6
    /// literal contains colons and whether this project accepts one in a host
    /// field is not settled here, so `host:21` is accepted as a host and
    /// fails at the dial. That is a known gap with a named reason, not a
    /// decision that it is valid: FTP plan Task 10 inherits it.
    public static func normalizedHost(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !hostCarriesUserinfo(text) else { return nil }

        var bracketed = false
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
            bracketed = true
            guard !text.isEmpty else { return nil }
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            {
                return nil
            }
            if "/?#[]".unicodeScalars.contains(scalar) { return nil }
        }
        // Brackets exist to hold an IPv6 literal; around anything else they
        // are a typo.
        if bracketed && !text.contains(":") { return nil }
        return text
    }

    /// The port these characters name, or nil when they name none.
    ///
    /// A blank field means the mode's own default -- that is what lets the
    /// form leave the port untouched and have it follow the security mode.
    /// Anything else must be an integer in 1...65535; there is no fallback to
    /// the default for a value that does not parse, because dialling the
    /// default when the user typed something else is the silent-wrong-port
    /// bug `SSHFieldSchema.port(_:)` documents.
    public static func port(_ raw: String, for mode: FTPSecurityMode) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return mode.defaultPort }
        guard text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
            let value = Int(text), (1...65535).contains(value)
        else { return nil }
        return value
    }

    /// The security mode these values name; a missing or unknown value reads
    /// as explicit FTPS, the form's own default, never as plain.
    public static func security(_ values: FieldValues) -> FTPSecurityMode {
        FTPSecurityMode(rawValue: values[FTPField.security]) ?? .explicitTLS
    }

    /// The port these values name, for a diagnosis that must not fail on a
    /// half-typed form: an unparsable port falls back to the mode's default.
    /// `makeConfig` is the strict reader.
    private static func lenientPort(_ values: FieldValues) -> Int {
        let mode = security(values)
        return port(values[FTPField.port], for: mode) ?? mode.defaultPort
    }

    /// Where a diagnosis points for this session (`BackendDescriptor
    /// .endpoint`).
    public static func endpoint(_ values: FieldValues) -> Endpoint? {
        guard let host = normalizedHost(values[FTPField.host]) else { return nil }
        return Endpoint(host: host, port: lenientPort(values))
    }

    /// The field values a bare host and optional port make
    /// (`BackendDescriptor.endpointValues(host:port:)`). Without a port the
    /// field is left blank rather than set to 21, so it follows the security
    /// mode's default like any untouched form.
    public static func endpointValues(host: String, port: Int?, base: FieldValues) -> FieldValues {
        var values = base
        values[FTPField.host] = host
        values[FTPField.port] = port.map(String.init) ?? ""
        return values
    }

    // MARK: - Config factory

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // Exhaustive over `FTPField`, so a case added there cannot reach this
        // factory without an arm. That buys ACKNOWLEDGMENT, not correctness:
        // every arm below says what it decided.
        var host = ""
        var port = 0
        for field in FTPField.allCases {
            switch field {
            case .host:
                guard let normalized = normalizedHost(values[FTPField.host]) else {
                    // Three different complaints, three different sentences:
                    // nothing typed, a credential or scheme typed, and a host
                    // with whitespace or path characters in it.
                    let typed = values[FTPField.host].trimmingCharacters(in: .whitespacesAndNewlines)
                    let key =
                        typed.isEmpty
                        ? "core.connect.emptyHost"
                        : hostCarriesUserinfo(typed)
                            ? "core.connect.ftpHostInvalid" : "core.connect.hostInvalid"
                    throw RemoteFSError.connectionFailed(reason: CoreL10n.string(key))
                }
                host = normalized
            case .port:
                guard let parsed = Self.port(values[FTPField.port], for: security(values))
                else {
                    throw RemoteFSError.connectionFailed(
                        reason: CoreL10n.string("core.connect.portNumeric"))
                }
                port = parsed
            case .security:
                break  // read through `security(_:)`, which has no failing case
            case .initialPath, .username, .password:
                // `initialPath` is free text and any value is valid. The other
                // two belong to the LOGIN; the secret does not even come from
                // `values` -- it arrives as the parameter.
                break
            }
        }
        let path = values[FTPField.initialPath].trimmingCharacters(in: .whitespacesAndNewlines)
        return .ftp(FTPConnectionConfig(
            host: host, port: port,
            username: values[FTPField.username].trimmingCharacters(in: .whitespacesAndNewlines),
            security: security(values),
            initialPath: path.isEmpty ? nil : path,
            password: secret))
    }

    /// User name and host -- what identifies an FTP connection to a human.
    /// The port is appended only when it is not the mode's own default.
    public static func displaySummary(_ values: FieldValues) -> String {
        let mode = security(values)
        let host = normalizedHost(values[FTPField.host]) ?? values[FTPField.host]
        let user = values[FTPField.username]
        let base = user.isEmpty ? host : "\(user) @ \(host)"
        let port = lenientPort(values)
        return port == mode.defaultPort ? base : "\(base):\(port)"
    }

    // MARK: - Persistence adapter

    /// The stored block as form values. The password is deliberately absent:
    /// it lives in the Keychain.
    public static func values(from stored: StoredFTPConfig) -> FieldValues {
        var values = FieldValues()
        values[FTPField.host] = stored.host
        values[FTPField.port] = String(stored.port)
        values[FTPField.security] = stored.security.rawValue
        values[FTPField.initialPath] = stored.initialPath ?? ""
        values[FTPField.username] = stored.username
        return values
    }

    /// The block a filled-in form describes. Text fields are TRIMMED on the
    /// way in, for the reason `S3FieldSchema.stored(from:)` gives: an import's
    /// duplicate key reads these byte for byte. A blank port is the mode's own
    /// default, a port that does not parse falls back to it too (the strict
    /// reader is `makeConfig`, which refuses it before a session is saved),
    /// and a blank initial folder is `nil`.
    public static func stored(from values: FieldValues) -> StoredFTPConfig {
        let mode = security(values)
        let path = values[FTPField.initialPath].trimmingCharacters(in: .whitespacesAndNewlines)
        return StoredFTPConfig(
            host: values[FTPField.host].trimmingCharacters(in: .whitespacesAndNewlines),
            port: port(values[FTPField.port], for: mode) ?? mode.defaultPort,
            username: values[FTPField.username].trimmingCharacters(in: .whitespacesAndNewlines),
            security: mode,
            initialPath: path.isEmpty ? nil : path)
    }

    /// Writes ONLY the fields `FTPField` covers -- same contract as the other
    /// backends' `apply`: group, login-set binding and tags are not touched.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.ftp = stored(from: values)
    }

    // MARK: - Login sets

    /// A login set's credentials in schema shape: the user name only. The
    /// secret lives in the Keychain under the set's id.
    public static func values(from set: LoginSet) -> FieldValues {
        var values = FieldValues()
        values[FTPField.username] = set.username
        return values
    }

    /// The set a filled-in credential form describes. `authKind` is SSH's
    /// column; `.password` is the only value that means anything here.
    public static func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        LoginSet(
            id: id, name: name,
            username: values[FTPField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authKind: .password, keyPath: nil, kind: .ftp)
    }
}
