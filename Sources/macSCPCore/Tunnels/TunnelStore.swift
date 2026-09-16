import Foundation

/// Why `TunnelStore` refused a write.
public enum TunnelStoreError: Error, Equatable, Sendable {
    /// `tunnels.json` exists and could not be decoded — garbage, or a format
    /// a later version wrote — so the write was refused and the file was
    /// left exactly as it was. `path` is the file, for the person who has to
    /// inspect it; the decoder's own error is not carried, because nothing
    /// that shows this refusal has a use for it.
    case unreadable(path: String)
}

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

    /// The read, with its outcome intact — the one place this file is
    /// decoded. Neither logs nor flattens: `load()` below is what decides
    /// that a failure reads as empty, while `readProfiles()` hands the
    /// failure to a caller that must not treat it that way and
    /// `writableFile()` turns it into a refused write.
    ///
    /// **A MISSING file is a success, not a failure**, and it is genuinely
    /// an empty store: only a fresh install has none. Deleting the LAST
    /// profile goes through `delete(id:)`, which persists the emptied
    /// container — so an emptied store is a PRESENT file holding
    /// `"profiles": []`, and nothing this app or its CLI does removes the
    /// file itself (measured 2026-09-06,
    /// `TunnelStoreTests.deletingTheLastProfileLeavesAnEmptyFileRatherThanNoFile`).
    /// That is what lets `TunnelManager.reloadReconciling()` treat "absent
    /// from a successful read" as a deletion without having to ask which of
    /// the two empty states it is looking at.
    private func decode() -> Result<StoreFile, any Error> {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return .success(StoreFile())
        }
        do {
            return .success(
                try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL)))
        } catch {
            return .failure(error)
        }
    }

    /// A present-but-undecodable file reads as empty rather than throwing.
    /// Unlike `SessionStore.all()` — whose caller has an error banner to
    /// show — this store feeds the sidebar glyph and autostart, neither of
    /// which has anywhere to put a load failure; logging the failure here
    /// and returning no profiles is the only record of it, at `.error` in
    /// the `app` category (the fixed list `DiagnosticLogSecrecyGuardTests`
    /// holds every call site to).
    ///
    /// **Only the lenient READERS go through this** — `allProfiles()`,
    /// `profiles(for:)` and `autoStart(_:)`. No write does: a write that
    /// read an unreadable file as empty would persist that empty reading,
    /// replacing every profile with the one being written (the BACKLOG row
    /// "`TunnelStore` writes rewrite an unreadable file from empty", fixed
    /// 2026-09-16). The writes read through `writableFile()` instead, and
    /// the reader that stops things — the activation reconcile — through
    /// `readProfiles()`.
    private func load() -> StoreFile {
        switch decode() {
        case .success(let file):
            return file
        case .failure(let error):
            DiagnosticLog.shared.log(
                .error, "app", "tunnels.json unreadable, returning no profiles", reason: error)
            return StoreFile()
        }
    }

    /// The file a write starts from, or `TunnelStoreError.unreadable` when a
    /// present file cannot be decoded. A MISSING file is an empty store here
    /// as everywhere (see `decode()`), so the first write still creates it.
    ///
    /// Throws before anything is written, and writes no log line of its
    /// own: the refusal goes to a caller that shows it (the profiles sheet,
    /// the command line) or records it (`TunnelManager
    /// .forgetEverything(for:)`), for the reason `readProfiles()` gives.
    private func writableFile() throws -> StoreFile {
        switch decode() {
        case .success(let file):
            return file
        case .failure:
            throw TunnelStoreError.unreadable(path: fileURL.path(percentEncoded: false))
        }
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    public func allProfiles() -> [TunnelProfile] { load().profiles }

    /// Every stored profile, or the reason the file could not be read.
    ///
    /// **Why this exists beside `allProfiles()`** (CLI sessions and tunnels
    /// plan, Task 5, fix round 2). `allProfiles()` answers `[]` for a
    /// present-but-undecodable file, which is right for the readers it was
    /// built for — the sidebar glyph and autostart have nowhere to put a
    /// failure. It is wrong for any caller that acts on ABSENCE:
    /// `TunnelManager.reloadReconciling()` stops the runners of profiles
    /// that are no longer listed, so a corrupt or version-mismatched
    /// `tunnels.json` read through `allProfiles()` would have said "every
    /// profile was deleted" and dropped every running forwarding on the next
    /// activation. This reader reports the failure so that caller can keep
    /// what it has.
    ///
    /// It does NOT log: `load()` logs because it is swallowing something,
    /// and this hands the error to a caller that writes its own line. Two
    /// records of one unreadable file would be two lines saying different
    /// things happened.
    public func readProfiles() -> Result<[TunnelProfile], any Error> {
        decode().map(\.profiles)
    }

    public func profiles(for sessionID: UUID) -> [TunnelProfile] {
        load().profiles.filter { $0.sessionID == sessionID }
    }

    /// Adds or replaces `profile`. Throws `TunnelStoreError.unreadable`,
    /// changing nothing, when `tunnels.json` is present but undecodable.
    public func upsert(_ profile: TunnelProfile) throws {
        var file = try writableFile()
        if let index = file.profiles.firstIndex(where: { $0.id == profile.id }) {
            file.profiles[index] = profile
        } else {
            file.profiles.append(profile)
        }
        try persist(file)
    }

    /// Removes the profile `id`. Throws `TunnelStoreError.unreadable`,
    /// changing nothing, when `tunnels.json` is present but undecodable.
    public func delete(id: UUID) throws {
        var file = try writableFile()
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
    ///
    /// Throws `TunnelStoreError.unreadable`, changing nothing, when
    /// `tunnels.json` is present but undecodable. Neither caller lets that
    /// stop the session deletion — see `TunnelManager
    /// .forgetEverything(for:)` and `StoreEditing.deleteSession(_:)`.
    public func deleteAll(for sessionID: UUID) throws {
        var file = try writableFile()
        file.profiles.removeAll { $0.sessionID == sessionID }
        try persist(file)
    }

    public func autoStart(_ when: TunnelProfile.AutoStart) -> [TunnelProfile] {
        load().profiles.filter { $0.autoStart == when }
    }
}
