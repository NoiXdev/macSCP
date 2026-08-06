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
