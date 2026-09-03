import Foundation

/// S3's field identifiers — the single source for its two schemas, its config
/// factory and its persistence adapter (M22).
public enum S3Field: String, CaseIterable, BackendFieldID {
    case endpoint, region, bucket, accessKeyID, secretAccessKey, usePathStyle
    case startsAtBucketList

    public static let namespace = "S3Field"
}

/// S3's data-driven registration (M22). Everything the generic layers need to
/// know about S3 lives here; nothing outside branches on `.s3`.
public enum S3FieldSchema {
    public static let connection = ConnectionFieldSchema(
        fields: [
            // Endpoint and bucket here, plus `accessKeyID` in the credential
            // schema, are what make an S3 connection distinct on import
            // (M23/P3). VERBATIM throughout: unlike a host name, a URL path
            // and a bucket name are case-sensitive.
            ConnectionField(id: S3Field.endpoint.rawValue,
                            labelKey: "connection.s3.endpoint", labelDefault: "Endpoint",
                            kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            identity: .verbatim),
            // NOT identifying, though it is required: the region is part of
            // the SigV4 credential scope, not of which bucket this is. Two
            // sessions naming the same bucket under different regions are one
            // connection, one of them misconfigured.
            ConnectionField(id: S3Field.region.rawValue,
                            labelKey: "connection.s3.region", labelDefault: "Region",
                            kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3RegionRequired"),
            // BEFORE the bucket, because it decides whether the bucket row
            // is there at all: a control that removes the row above itself
            // reads as a glitch.
            //
            // NOT identifying, for the same reason `usePathStyle` is not:
            // it decides where the browser OPENS, not which account or
            // bucket is reached.
            //
            // What makes that decision safe is `bucketToCarry` below, not
            // this sentence: with the toggle on, the bucket that leaves
            // these values is the EMPTY string, so a bucket-list session
            // and a session for one bucket of the same account differ in
            // `bucket` and are told apart by the identity key. Two
            // bucket-list sessions on one endpoint with one key are then
            // the SAME connection, which is the intended reading — same
            // account, same credentials, same thing browsed
            // (`twoBucketListSessionsForTheSameAccountAreOneConnection`).
            // An earlier version of this comment asserted the blank bucket
            // as a premise while nothing enforced it (Task 3 review, I-4).
            ConnectionField(id: S3Field.startsAtBucketList.rawValue,
                            labelKey: "connection.s3.startsAtBucketList",
                            labelDefault: "Start at the bucket list", kind: .toggle),
            // Hidden while the connection starts at the bucket LIST, where
            // there is no one bucket to name (2026-09-02). `firstViolation`
            // walks `visibleFields`, so a hidden bucket is not a blank
            // required field either — and `makeConfig` carries the same
            // exemption, because it never sees the schema.
            //
            // The condition compares against the string "false" rather than
            // negating "true", because `FieldCondition` has no negation and
            // is not being given one for this. That makes an ABSENT key read
            // as "not visible", so both baselines below write the toggle out
            // explicitly and `bothBaselinesWriteTheToggleOutAsOff` holds them
            // to it. Nothing else in the tree hands this schema a bag that
            // skipped them: `values(from:)` writes the key, and
            // `SessionImportPlanner` overlays a file's bag onto
            // `defaultValues`.
            ConnectionField(id: S3Field.bucket.rawValue,
                            labelKey: "connection.s3.bucket", labelDefault: "Bucket",
                            kind: .text,
                            visibleWhen: FieldCondition(
                                field: S3Field.startsAtBucketList.rawValue, equals: "false"),
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3BucketRequired",
                            identity: .verbatim),
            // NOT identifying: path-style versus virtual-host addressing is
            // how a client reaches the bucket, not which bucket it reaches.
            // Two sessions differing only here are the same connection, and
            // the user must be asked rather than handed a silent second copy.
            ConnectionField(id: S3Field.usePathStyle.rawValue,
                            labelKey: "connection.s3.pathStyle",
                            labelDefault: "Use path-style URLs", kind: .toggle),
        ],
        presets: [
            ConnectionPreset(id: "aws", nameKey: "connection.s3.preset.aws",
                             nameDefault: "Amazon S3",
                             values: [S3Field.endpoint.rawValue: "https://s3.amazonaws.com",
                                      S3Field.usePathStyle.rawValue: "false"]),
            ConnectionPreset(id: "hetzner", nameKey: "connection.s3.preset.hetzner",
                             nameDefault: "Hetzner Object Storage",
                             values: [S3Field.endpoint.rawValue: "https://fsn1.your-objectstorage.com",
                                      S3Field.usePathStyle.rawValue: "true"]),
            ConnectionPreset(id: "custom", nameKey: "connection.s3.preset.custom",
                             nameDefault: "Custom", values: [:]),
        ])

    /// What a brand-new S3 form starts with (M22/T8) -- `BackendDescriptor
    /// .defaultValues`'s S3 case. The toggle is written out rather than left
    /// absent so the checkbox reads "off" from a real value instead of from
    /// `FieldValues`'s absent-means-false rule.
    ///
    /// Built on `editBaseline` below, PLUS the region: a new form has no
    /// saved values to merge on top and show instead, so the assumed default
    /// is safe to show here and only here.
    public static let defaults: FieldValues = {
        var values = editBaseline
        // A new form starts with the region most S3-compatible providers accept
        // because they do not check it. That is an ASSUMPTION about third-party
        // servers, which is why it is a visible, editable default on a new form
        // and never written into an existing session. AWS itself does check —
        // the AWS preset's user still has to enter theirs. Measured against the
        // rig's MinIO (us-east-1 in the gated suite); not measured against
        // Servinga, the provider in the report.
        values[S3Field.region] = "us-east-1"
        return values
    }()

    /// What the EDIT form starts from before the stored session's own values
    /// are merged on top (`BackendDescriptor.editBaseline`'s S3 case) --
    /// `defaults` above MINUS the region assumption. A session whose S3
    /// block is missing must show an EMPTY region and fail Save with
    /// `core.connect.s3RegionRequired`, the same way a truly blank field
    /// would; if the assumed default leaked in here it would instead get
    /// silently written back into that session on the next Save via
    /// `stored(from:)`, which is exactly the "never written into an existing
    /// session" promise `defaults`' own comment makes.
    public static let editBaseline: FieldValues = {
        var values = FieldValues()
        values[bool: S3Field.usePathStyle] = false
        // Written out for the same reason as `usePathStyle` — and for one
        // more: the bucket field's `visibleWhen` compares against the
        // literal "false", so an absent key would hide the bucket row.
        values[bool: S3Field.startsAtBucketList] = false
        return values
    }()

    /// What a login set carries: the credentials, not the endpoint. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            // Identifying, and legitimately so: two different keys against one
            // bucket are two connections with different rights. It is an
            // opaque credential but NOT a secret — the secret is
            // `secretAccessKey` below, which carries no identity and never
            // enters a key.
            ConnectionField(id: S3Field.accessKeyID.rawValue,
                            labelKey: "connection.s3.accessKey",
                            labelDefault: "Access Key ID", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            identity: .verbatim),
            ConnectionField(id: S3Field.secretAccessKey.rawValue,
                            labelKey: "connection.s3.secretKey",
                            labelDefault: "Secret Access Key", kind: .secret,
                            isRequired: true,
                            invalidMessageKey: "core.connect.s3FieldRequired",
                            secretRole: .credential),
        ],
        presets: [])

    /// The bucket these values describe: the trimmed field, or the EMPTY
    /// string while the connection starts at the bucket list (Task 3
    /// review, I-4).
    ///
    /// Hiding a field does not clear its value — `SchemaFormView` filters
    /// only what it renders — so without this a user who types a bucket and
    /// then turns the toggle on saves a bucket the connection never reads.
    /// That stale value is not merely untidy: `identifyingFields` ignores
    /// visibility, so it enters the import duplicate key, where it made a
    /// bucket-list session collide with the plain session for that same
    /// bucket and offer Replace — which takes over the stored session's id.
    ///
    /// The BAG is deliberately left alone. Only the two boundaries out of
    /// it (the runtime config and the stored config) blank the bucket, so
    /// a toggle flipped on and back off inside one unsaved form still shows
    /// what the user typed.
    private static func bucketToCarry(_ values: FieldValues) -> String {
        guard !values[bool: S3Field.startsAtBucketList] else { return "" }
        return values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The scheme a schemeless endpoint is read as (see
    /// `endpointComponents`). TLS, because that is what every hosted S3
    /// provider speaks and because the wrong guess fails visibly — a plain
    /// `http` server answers an `https` request with nothing, while the
    /// reverse would send a signed request in the clear.
    public static let assumedEndpointScheme = "https"

    /// The ONE parse of an S3 endpoint string in this project.
    ///
    /// Shared with the connect path — `S3FileSystem`'s three request-URL
    /// builders call it — so "what is a usable endpoint" is answered in one
    /// place. That sharing is the point, and it is what makes the rule below
    /// safe to state: an earlier version of the diagnosis reader prepended
    /// `https://` HERE ONLY, while the connect path parsed the same string
    /// verbatim, so a diagnosis reported resolve ok / tcp accepted / dial ok
    /// for a session the app could not dial at all
    /// (`S3RequestSigning.signedRequest` throws "S3 endpoint has no host"
    /// for it).
    ///
    /// **A schemeless endpoint means `https`, and its port is honoured**
    /// (2026-09-03, maintainer report: `host:9000` could not connect).
    /// Foundation is the reason the rule needs code: `URLComponents(string:)`
    /// reads `minio.lan:9000` as a SCHEME of `minio.lan` with no host at all,
    /// and refuses `192.0.2.10:9000` outright because a scheme may not begin
    /// with a digit. FOUR of the eight spellings in
    /// `S3EndpointParsingTests`' table parsed without a host before the
    /// prefix, and a fifth (`192.0.2.10:9000`) did not parse at all — counted
    /// from that table's own before-measurement on 2026-09-03.
    ///
    /// Those two outcomes are refused in two different places, and an earlier
    /// version of this comment conflated them (review 2026-09-04, I-1;
    /// `S3AccessProbe.answer(for:)` states it correctly): a string that does
    /// not parse is refused by `S3FileSystem`'s URL builders with "Invalid S3
    /// endpoint", while a string that parses with NO HOST gets past them
    /// under path-style addressing and is refused by
    /// `S3RequestSigning.signedRequest` with "S3 endpoint has no host"
    /// (virtual-hosted addressing refuses it one step earlier, in
    /// `requestURL`/`keyRequestURL`, with "Invalid S3 endpoint host").
    ///
    /// The trim happens BEFORE the scheme test, or a pasted leading space
    /// would make ` https://host` look schemeless and earn a second prefix.
    ///
    /// Returns components, not a URL, because the connect path mutates them
    /// (path-style writes the path; virtual-hosted rewrites the host).
    public static func endpointComponents(_ endpoint: String) -> URLComponents? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let qualified = hasScheme(trimmed) ? trimmed : "\(assumedEndpointScheme)://\(trimmed)"
        return URLComponents(string: qualified)
    }

    /// Whether `text` already opens with a URL scheme — RFC 3986's
    /// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` followed by `://`.
    ///
    /// The `//` is part of the test on purpose. A bare colon is not evidence
    /// of a scheme: `minio.lan:9000` and `[::1]:9000` both carry one and are
    /// exactly the spellings this must treat as schemeless.
    private static func hasScheme(_ text: String) -> Bool {
        guard let separator = text.range(of: "://") else { return false }
        let scheme = text[text.startIndex..<separator.lowerBound]
        guard let first = scheme.first, first.isLetter, first.isASCII else { return false }
        return scheme.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
    }

    /// The endpoint as a URL, or nil when the connect path could not use it
    /// either — the two read the same string through the same parse.
    public static func endpointURL(_ values: FieldValues) -> URL? {
        guard let components = endpointComponents(values[S3Field.endpoint]),
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// What this project understood an endpoint to mean: scheme, host and
    /// port, with nothing else. Nil when the string names no host, which is
    /// the same nil the connect path refuses on.
    ///
    /// The form shows this under the endpoint field, so a user who types
    /// `minio.lan:9000` can see that it became `https://minio.lan:9000`
    /// BEFORE a connection is attempted. Core composes the origin only; the
    /// sentence around it is the App's, out of its catalogs.
    ///
    /// Deliberately origin-only: the connect path OVERWRITES the endpoint's
    /// path with `/bucket/key`, so a path typed into the field takes no part
    /// in any request, and repeating it here would claim otherwise.
    public static func canonicalEndpoint(_ endpoint: String) -> String? {
        guard let components = endpointComponents(endpoint),
            let host = components.host, !host.isEmpty,
            // Never nil in practice — the parse above either found a scheme
            // or wrote one — but read rather than defaulted: a `??` here
            // would be a second, unreachable answer to "what scheme is this",
            // and refusing is the right outcome if the parse ever stops
            // guaranteeing one.
            let scheme = components.scheme
        else { return nil }
        return spelling(scheme: scheme, host: host, port: components.port)
    }

    /// Whether these values force path-style addressing whatever the toggle
    /// says: the endpoint's host is an IP LITERAL (review 2026-09-04, I-3).
    ///
    /// Virtual-hosted addressing puts the bucket in front of the host —
    /// `S3FileSystem.requestURL` writes `"\(bucket).\(host)"` — and
    /// `backups.192.0.2.10` is a name no resolver answers, nor is
    /// `backups.[::1]` an address. The maintainer's own `192.0.2.10:9000` is
    /// exactly that case: accepted by the parse, announced by the form, and
    /// then failing in DNS for a name nobody typed.
    ///
    /// A rule about what a resolver can answer, so it belongs to the values
    /// and not to the view: `makeConfig` and `stored(from:)` both write the
    /// forced value, and the form disables the toggle it can no longer
    /// change.
    public static func pathStyleIsForced(_ values: FieldValues) -> Bool {
        guard let host = endpointComponents(values[S3Field.endpoint])?.host
        else { return false }
        return isIPLiteral(host)
    }

    /// The addressing this connection actually uses: the toggle, OR the
    /// forcing above. Every reader of "is this path-style?" outside the
    /// stored config goes through here.
    public static func usesPathStyle(_ values: FieldValues) -> Bool {
        values[bool: S3Field.usePathStyle] || pathStyleIsForced(values)
    }

    /// Whether `host` is an IP address rather than a name. Accepts the
    /// BRACKETED spelling too, because that is what `URLComponents.host`
    /// hands back for an IPv6 literal.
    ///
    /// `inet_pton` rather than a pattern: it is the same parser the resolver
    /// uses, so "looks like an address" and "is one" cannot drift. A literal
    /// carrying a zone id (`fe80::1%en0`) is not recognised — `inet_pton`
    /// rejects it — which errs toward leaving the user's toggle alone.
    private static func isIPLiteral(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, bare, &v6) == 1
    }

    /// The origin the REQUEST reaches — not the origin the endpoint field
    /// names, which are two different things under virtual-hosted addressing
    /// (review 2026-09-04, I-3).
    ///
    /// With `usePathStyle` off and a bucket set, `S3FileSystem` addresses
    /// `<bucket>.<host>`; every other case (path-style, or a bucket-list
    /// session that has no one bucket) reaches the endpoint's own host. The
    /// form prints this, so what it announces is where the connection goes.
    ///
    /// The bucket comes from `bucketToCarry`, the same reader the config and
    /// the stored session use, so a bucket-list session contributes none.
    /// An IP literal can never take the virtual-hosted branch here, because
    /// `usesPathStyle` is already true for it.
    public static func requestOrigin(_ values: FieldValues) -> String? {
        guard let components = endpointComponents(values[S3Field.endpoint]),
            let host = components.host, !host.isEmpty,
            let scheme = components.scheme
        else { return nil }
        let bucket = bucketToCarry(values)
        let requestHost = !usesPathStyle(values) && !bucket.isEmpty
            ? "\(bucket).\(host)" : host
        return spelling(scheme: scheme, host: requestHost, port: components.port)
    }

    /// The endpoint spelling for a host and an optional port — what the
    /// Cyberduck importer writes for a custom endpoint, composed HERE so the
    /// importer cannot grow a second idea of the canonical form. Round-trips
    /// through `endpointComponents` by construction; `S3EndpointParsingTests`
    /// holds it to that.
    public static func endpointSpelling(host: String, port: Int?) -> String {
        spelling(scheme: assumedEndpointScheme, host: host, port: port)
    }

    /// `host[:port]` as the endpoint names it — the summary's half of
    /// `spelling` below, without the scheme. Nil when the endpoint names no
    /// host, which is what makes the caller's fallback to the raw field
    /// text reachable.
    private static func endpointHostText(_ values: FieldValues) -> String? {
        guard let components = endpointComponents(values[S3Field.endpoint]),
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// `scheme://host[:port]`, bracketing an IPv6 literal exactly once —
    /// `::1` has to read as `[::1]:9000`, or it parses back as a host of
    /// `` with the port `:1` (the same rule `Endpoint.text` follows).
    private static func spelling(scheme: String, host: String, port: Int?) -> String {
        let literal = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port.map { "\(scheme)://\(literal):\($0)" } ?? "\(scheme)://\(literal)"
    }

    /// Where a diagnosis points for this session (`BackendDescriptor
    /// .endpoint`): the CONFIGURED endpoint's origin.
    ///
    /// Not the virtual-hosted `<bucket>.<endpoint>` name a request may
    /// actually carry with `usePathStyle` off. The two differ only in a label
    /// the same server answers for, and the configured origin is the one the
    /// user typed and can check — a resolve step naming a host nobody
    /// configured explains nothing.
    public static func endpoint(_ values: FieldValues) -> Endpoint? {
        endpointURL(values).flatMap { Endpoint(url: $0) }
    }

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // The switch is exhaustive, so a case added to `S3Field` cannot reach
        // this factory without an arm here. That buys ACKNOWLEDGMENT, not
        // correctness: appending the new case to the `break` arm below
        // satisfies the compiler while deciding nothing. Which is why that
        // arm says why each of its fields needs no check — a new case joining
        // it has to fit the stated reason or move out.
        for field in S3Field.allCases {
            switch field {
            case .bucket:
                // Not required while the connection starts at the bucket
                // list: there is no one bucket then, and the form does not
                // show the field. The same exemption `visibleWhen` gives
                // `firstViolation`, restated here because this factory
                // reads the values and not the schema.
                guard !values[bool: S3Field.startsAtBucketList] else { break }
                guard !values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the bucket") }
            case .endpoint:
                guard !values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the endpoint") }
            case .region, .accessKeyID, .secretAccessKey, .usePathStyle,
                 .startsAtBucketList:
                // `region` needs no check HERE, but it is not optional: the
                // schema marks it `isRequired: true` above, and
                // `BackendDescriptor.firstViolation` enforces that before this
                // factory ever runs. Some S3-compatible servers (MinIO, probed
                // against the Docker rig) never look at the value, which reads
                // as "blank is fine" -- it is not. `region` is part of the
                // SigV4 credential scope (`AK/date/REGION/s3/aws4_request`);
                // an empty segment there is a scope real AWS rejects with an
                // opaque `AuthorizationHeaderMalformed` OR `SignatureDoesNotMatch`
                // — which one depends on what else about the request is off,
                // but both mean AWS rejected it. A server that ignores the
                // field is not evidence the field is unneeded, only that
                // it isn't the one enforcing it. `usePathStyle` and
                // `startsAtBucketList` are toggles whose every value is
                // valid. The two credential fields belong
                // to the LOGIN, not the bucket: both `connect()` and
                // `validateForEditSave()` check them against the schema's own
                // `isRequired` via `BackendDescriptor.firstViolation` (M23/T6)
                // -- the latter passes `requireSecrets: false`, which is what
                // owns the rule that an empty secret means "unchanged" during
                // an edit.
                break
            }
        }
        return .s3(S3ConnectionConfig(
            accessKeyID: values[S3Field.accessKeyID].trimmingCharacters(in: .whitespacesAndNewlines),
            // TRIMMED, unlike every other backend's secret (maintainer
            // decision, M23/T5 fix round 1). An SSH or WebDAV password is sent
            // verbatim because whitespace can be a legitimate part of it; an
            // AWS secret access key is a base64-ish token that never contains
            // any, so the only thing trimming can remove is what a paste
            // brought along. Leaving it in produces a SigV4 signature mismatch
            // that surfaces as a bare "access denied" with nothing pointing at
            // the stray space. Kept HERE, in S3's own factory, rather than in
            // the shared connect path, so the policy stays S3's.
            secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            region: values[S3Field.region].trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucketToCarry(values),
            // `usesPathStyle`, not the toggle: an IP-literal endpoint is
            // addressed path-style whatever the form says, because
            // `<bucket>.192.0.2.10` is a name no resolver answers (I-3).
            usePathStyle: usesPathStyle(values),
            sessionToken: nil,
            startsAtBucketList: values[bool: S3Field.startsAtBucketList]))
    }

    /// Bucket and endpoint host — what identifies an S3 connection to a
    /// human. Rendered in the sidebar subtitle and in audit lines.
    ///
    /// With the toggle on there is no bucket, and the "bucket @ host" shape
    /// would degrade to a leading " @ " with nothing in front of it. The
    /// host alone is what such a connection actually is.
    ///
    /// Reads the host through `endpointComponents` and not through a
    /// `URL(string:)` of its own (2026-09-03): the second parse disagreed
    /// with the first for exactly the spellings this task is about — for
    /// `minio.lan:9000` it found no host and the sidebar fell back to
    /// printing the whole endpoint string.
    ///
    /// The PORT is part of it (review 2026-09-04): without it a MinIO on
    /// 9000 and one on 9001, same host, are one line in the sidebar and one
    /// sentence in every audit entry. Omitted when the endpoint names none,
    /// where there is nothing to tell apart. The credentials are not here in
    /// any spelling — this is host and port, composed the same way
    /// `canonicalEndpoint` composes its origin.
    public static func displaySummary(_ values: FieldValues) -> String {
        let host = endpointHostText(values) ?? values[S3Field.endpoint]
        guard !values[bool: S3Field.startsAtBucketList] else { return host }
        return "\(values[S3Field.bucket]) @ \(host)"
    }

    // MARK: - Persistence adapter

    /// The on-disk format is unchanged; this translates in both directions.
    public static func values(from stored: StoredS3Config) -> FieldValues {
        var values = FieldValues()
        values[S3Field.endpoint] = stored.endpoint
        values[S3Field.region] = stored.region
        values[S3Field.bucket] = stored.bucket
        values[S3Field.accessKeyID] = stored.accessKeyID
        values[bool: S3Field.usePathStyle] = stored.usePathStyle
        values[bool: S3Field.startsAtBucketList] = stored.startsAtBucketList
        // secretAccessKey deliberately absent: it lives in the Keychain.
        return values
    }

    /// A login set's credentials in schema shape (M22/T9) — see
    /// `SSHFieldSchema.values(from:)`. The secret access key is absent for the
    /// same reason an SSH password is: it lives in the Keychain under the
    /// set's id.
    public static func values(from set: LoginSet) -> FieldValues {
        var values = FieldValues()
        values[S3Field.accessKeyID] = set.accessKeyID ?? ""
        return values
    }

    /// The set a filled-in credential form describes. `username`/`authKind`/
    /// `keyPath` are SSH's columns and stay at their neutral values here.
    public static func loginSet(id: UUID, name: String, from values: FieldValues) -> LoginSet {
        LoginSet(
            id: id, name: name, username: "", authKind: .password, keyPath: nil, kind: .s3,
            accessKeyID: values[S3Field.accessKeyID]
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every text field is TRIMMED on the way in (M23/T7 fix round 1), for the
    /// same reason as `SSHFieldSchema.apply` and matching what `makeConfig`
    /// already does for the CONNECT direction: without it the same typed value
    /// connected fine and persisted with whitespace. The App's S3 save branch
    /// trimmed all four before building this config; collapsing it onto the
    /// descriptor moved the responsibility here. The secret access key is not
    /// among them because it is not stored here at all.
    public static func stored(from values: FieldValues) -> StoredS3Config {
        StoredS3Config(
            accessKeyID: values[S3Field.accessKeyID]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            region: values[S3Field.region].trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: values[S3Field.endpoint].trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucketToCarry(values),
            // Stored as it will be USED (see `makeConfig`): a session saved
            // with an IP-literal endpoint carries path-style, so reopening it
            // shows the addressing it actually dials with.
            usePathStyle: usesPathStyle(values),
            startsAtBucketList: values[bool: S3Field.startsAtBucketList])
    }

    /// Writes ONLY the fields `S3Field` covers, mirroring
    /// `SSHFieldSchema.apply(_:to:)`. `StoredSession` carries group, login-set
    /// binding and the other backends' blocks; rebuilding it from these values
    /// would silently drop them.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.s3 = stored(from: values)
    }
}
