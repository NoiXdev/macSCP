import Foundation

/// What to do when the destination already exists.
public enum ConflictAction: String, CaseIterable, Sendable {
    case fail, skip, overwrite
}

public struct TransferJob: Equatable, Sendable {
    public let source: String
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}

public enum TransferPlanError: Error, Equatable, Sendable {
    case conflict(String)
    /// `RemotePath.join("", name)` silently yields `"/name"` — an empty
    /// destination directory would otherwise retarget the transfer to the
    /// filesystem ROOT instead of failing (M20 Task 9 review, fixed in
    /// Task 10). Kept distinct from `.conflict`: this is a malformed
    /// argument, not "the destination already has something there".
    case emptyDestinationDirectory
}

/// Turns a source and a destination directory into concrete jobs, applying the
/// conflict rule. Separate from the engine so the case analysis is provable
/// without a network.
public enum TransferPlan {
    public static func jobs(
        source: String,
        destinationDirectory: String,
        destinationExists: Bool,
        action: ConflictAction
    ) throws -> [TransferJob] {
        guard !destinationDirectory.isEmpty else {
            throw TransferPlanError.emptyDestinationDirectory
        }
        let name = (source as NSString).lastPathComponent
        let destination = RemotePath.join(destinationDirectory, name)
        guard destinationExists else {
            return [TransferJob(source: source, destination: destination)]
        }
        switch action {
        case .fail: throw TransferPlanError.conflict(destination)
        case .skip: return []
        case .overwrite: return [TransferJob(source: source, destination: destination)]
        }
    }
}
