import Foundation

/// A protocol-specific FILE-level action a backend contributes to the context
/// menu (M12 seam). The list a backend contributes is its descriptor's
/// `fileActions`; S3's holds `s3.presignedURL`.
///
/// This comment used to end "(M12 seam; empty for ssh/s3 now — S3 presigned
/// URL lands in M14)", and both halves are withdrawn: S3's list stopped being
/// empty when `df0a74a3` added `s3.presignedURL` to it (found with `git log
/// -S'FileActionContribution(id: "s3.presignedURL"' -- Sources/macSCPCore/
/// Capabilities/BackendDescriptor.swift`), and "lands in M14" was a promise in
/// the future tense that had been kept.
public struct FileActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    public init(id: String, titleKey: String, titleDefault: String) {
        self.id = id; self.titleKey = titleKey; self.titleDefault = titleDefault
    }
}

/// A CONNECTION-level action a backend contributes to the window's toolbar:
/// something the user does to the connection's store as a whole rather than
/// to a selected file (S3 bucket settings, Task 7).
///
/// The sibling of `FileActionContribution` above, and deliberately the same
/// shape plus an icon: the toolbar draws a glyph where the context menu does
/// not. `id` is the dispatch key -- the window is meant to route by it and
/// never by `ConnectionKind`, as it already does for `FileActionContribution`
/// -- and `titleKey`/`titleDefault` follow the catalogue convention every
/// contribution here uses.
///
/// Nothing routes by a connection action's `id` yet: the toolbar menu has no
/// handler wired (`ConnectionActionsMenu.onSelect`), so the rows render
/// disabled. An earlier wording of this paragraph said "the window routes by
/// it and never by `ConnectionKind`", present tense; that was true of the file
/// actions and aspirational here, and is withdrawn.
public struct ConnectionActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    /// An SF Symbol name.
    public let systemImage: String
    public init(id: String, titleKey: String, titleDefault: String, systemImage: String) {
        self.id = id; self.titleKey = titleKey; self.titleDefault = titleDefault
        self.systemImage = systemImage
    }
}

/// Everything a diagnostic probe needs beyond the form values it is handed.
///
/// The secret arrives as its SOURCE plus the session it answers for, never as
/// a string and never as a source alone: `SecretSource.secret(for:)` is keyed
/// by session, so a source without its session id cannot answer at all and a
/// caller holding only one of the two would have to invent the other. Bundled
/// into one value so that cannot happen — the design's rule is that a
/// contribution authenticates "through the same resolver the connect uses,
/// never a second copy of a secret".
///
/// `timeout` is the runner's per-step budget, passed in so a probe whose own
/// transport takes a timeout (SSH's connect timeout, `URLRequest`'s
/// `timeoutInterval`) can hand it down. The runner enforces the same deadline
/// from outside regardless; giving the probe the number as well is what lets
/// it stop its own work instead of being abandoned mid-dial.
public struct DiagnosticContext: Sendable {
    public let secrets: (any SecretSource)?
    public let sessionID: UUID?
    public let timeout: Duration

    public init(secrets: (any SecretSource)?, sessionID: UUID?, timeout: Duration) {
        self.secrets = secrets
        self.sessionID = sessionID
        self.timeout = timeout
    }

    /// The session's secret, or nil when there is no source, no session id,
    /// or nothing stored for it. Throws whatever the source throws — a vault
    /// that failed is not the same as a session with no password, and a probe
    /// that flattened the two would report a missing credential for a broken
    /// keychain.
    public func secret() throws -> String? {
        guard let secrets, let sessionID else { return nil }
        return try secrets.secret(for: sessionID)
    }
}

/// A protocol's OWN probe, contributed to the diagnosis beside the universal
/// steps (design §3).
///
/// Unlike the universal half, a contribution MAY authenticate — it is the
/// backend asking its own server a question the generic resolve/ping/dial
/// cannot. What it returns is one finished row; the runner holds it to the
/// step timeout from outside and never inspects what it did.
public struct DiagnosticContribution: Sendable, Identifiable {
    public let id: String
    public let titleKey: String
    public let run: @Sendable (FieldValues, DiagnosticContext) async -> DiagnosticStep

    public init(
        id: String, titleKey: String,
        run: @escaping @Sendable (FieldValues, DiagnosticContext) async -> DiagnosticStep
    ) {
        self.id = id
        self.titleKey = titleKey
        self.run = run
    }
}
