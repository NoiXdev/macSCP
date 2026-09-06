import Foundation

/// JSON persistence for port-forwarding profiles. Stateless, the same shape
/// as `SessionStore`: every operation reads and writes `tunnels.json` in
/// full (a small number of profiles per install, atomic writes). Written
/// fields are ids, names, hosts and ports — never a secret; a running
/// tunnel's SSH connection is authenticated through its session's own
/// stored login at connect time, through the existing
/// `SecretSource`/`SecretResolver` path.
public struct TunnelStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("tunnels.json")
    }

    /// On-disk container. `tunnels.json` sits beside `sessions-v2.json`
    /// rather than adding a version key inside this file — the same choice
    /// `SessionStore` made for its own current-format file (see that type's
    /// `fileURL` doc comment): a new name is what a FUTURE reader benefits
    /// from, and a build that predates this file simply never sees one.
    private struct StoreFile: Codable {
        var profiles: [TunnelProfile] = []
    }

    /// A present-but-undecodable file reads as empty rather than throwing.
    /// Unlike `SessionStore.all()` — whose caller has an error banner to
    /// show — this store feeds the sidebar glyph and autostart, neither of
    /// which has anywhere to put a load failure; logging the failure here
    /// and returning no profiles is the only record of it, at `.error` in
    /// the `app` category (the fixed list `DiagnosticLogSecrecyGuardTests`
    /// holds every call site to).
    private func load() -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        do {
            return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
        } catch {
            DiagnosticLog.shared.log(
                .error, "app", "tunnels.json unreadable, returning no profiles", reason: error)
            return StoreFile()
        }
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    public func allProfiles() -> [TunnelProfile] { load().profiles }

    public func profiles(for sessionID: UUID) -> [TunnelProfile] {
        load().profiles.filter { $0.sessionID == sessionID }
    }

    public func upsert(_ profile: TunnelProfile) throws {
        var file = load()
        if let index = file.profiles.firstIndex(where: { $0.id == profile.id }) {
            file.profiles[index] = profile
        } else {
            file.profiles.append(profile)
        }
        try persist(file)
    }

    public func delete(id: UUID) throws {
        var file = load()
        file.profiles.removeAll { $0.id == id }
        try persist(file)
    }

    /// Removes every profile belonging to `sessionID`, so a deleted session
    /// leaves no orphaned profile behind.
    ///
    /// The session-deletion seam (`SessionDeletionObserver`, declared on
    /// `SessionListViewModel`) ends here, but it does NOT end here directly:
    /// the registered observer is `TunnelManager.deletionObserver` in the App
    /// target, which stops the session's runners as well as deleting their
    /// rows — a store that only rewrote `tunnels.json` left the tunnels
    /// themselves running. `TunnelStore` used to carry the conformance
    /// itself; it was deleted in the final review's fix round (2026-09-06)
    /// once nothing but a test registered it.
    public func deleteAll(for sessionID: UUID) throws {
        var file = load()
        file.profiles.removeAll { $0.sessionID == sessionID }
        try persist(file)
    }

    public func autoStart(_ when: TunnelProfile.AutoStart) -> [TunnelProfile] {
        load().profiles.filter { $0.autoStart == when }
    }
}
