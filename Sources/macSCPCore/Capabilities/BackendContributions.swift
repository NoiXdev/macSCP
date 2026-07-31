/// An extra detail row a backend contributes to the Info sheet (M12 seam).
public struct InfoField: Sendable, Equatable, Identifiable {
    public let id: String
    public let labelKey: String
    public let labelDefault: String
    public let value: String
    public init(id: String, labelKey: String, labelDefault: String, value: String) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault; self.value = value
    }
}

/// A protocol-specific FILE-level action a backend contributes to the context
/// menu (M12 seam; empty for ssh/s3 now — S3 presigned URL lands in M14).
public struct FileActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    public init(id: String, titleKey: String, titleDefault: String) {
        self.id = id; self.titleKey = titleKey; self.titleDefault = titleDefault
    }
}

/// A CONNECTION-level action a backend contributes to the session/tab context
/// menu (M12 seam; empty now — diagnostics ping/traceroute/speedtest land in a
/// later milestone).
public struct ConnectionActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    public init(id: String, titleKey: String, titleDefault: String) {
        self.id = id; self.titleKey = titleKey; self.titleDefault = titleDefault
    }
}
