/// Where a session's shell opens (M11d): the built-in terminal panel, a
/// well-known external app resolved by bundle identifier, or a custom app at
/// a stored path. Combined with `SettingsStore.customTerminalAppPath` at the
/// App layer (`ExternalTerminalLauncher`) to resolve an actual application
/// URL.
public enum TerminalTarget: String, Codable, CaseIterable, Sendable {
    case builtIn
    case terminalApp
    case iTerm
    case custom
}
