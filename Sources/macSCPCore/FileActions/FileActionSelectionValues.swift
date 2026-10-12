import Foundation

/// The values one selected item binds, under the names
/// `FileActionTemplate.reservedNames` holds.
///
/// **All three are server data.** They come from a directory listing, not
/// from anything the user typed, which is the trust boundary this whole
/// subsystem exists to hold. Whatever places one into a remote command must
/// quote it first, and whatever places one into a local argv must not hand
/// it over unchecked.
public enum FileActionSelectionValues {
    /// `PATH` and `DIR` are ABSOLUTE, because a remote action is typed into
    /// the user's own shell and that shell's working directory is wherever
    /// the user left it — not the directory the pane is showing. This
    /// feature issues no `cd`: that would change the state of a shell the
    /// user is also using by hand.
    ///
    /// The path is normalized first. `RemotePath` states that it "expects
    /// absolute, single-slash-normalized paths" and that behaviour on other
    /// input is unspecified, and a server's listing is other input;
    /// `normalizedAbsolute` is the one function in that type documented as
    /// safe on hostile input.
    public static func values(for item: RemoteFileItem) -> [String: String] {
        let path = RemotePath.normalizedAbsolute(item.path)
        return [
            "PATH": path,
            "DIR": RemotePath.parent(of: path),
            "NAME": item.name,
        ]
    }
}
