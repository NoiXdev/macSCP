/// The terminal cursor's shape (M9d). Combined with `SettingsStore
/// .terminalCursorBlink`, the pair maps to SwiftTerm's six cursor modes at
/// the app layer.
public enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable {
    case block
    case bar
    case underline
}
