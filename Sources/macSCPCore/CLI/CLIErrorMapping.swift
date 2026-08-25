import Foundation

/// Maps a thrown error to the process exit code AND a human-readable stderr
/// message. Lives in Core, not the CLI target (M20 Task 10): the CLI has no
/// test target, so this — the actual decision logic ArgumentParser's default
/// error handling otherwise collapses to a flat exit code 1 — needs to live
/// somewhere it can be pinned by a test (the pattern `CLISecretSources.swift`
/// established in Task 8). Pure lookup, no I/O.
///
/// NOT responsible for ArgumentParser's OWN errors (help requests, usage
/// validation, unknown flags): those never reach here — the CLI's `main()`
/// override only routes errors thrown by a subcommand's `run()` through this
/// mapping, leaving parse-time errors to ArgumentParser's default handling.
public enum CLIErrorMapping {
    public static func exitCode(for error: Error) -> CLIExitCode {
        switch error {
        case is TransferSourceError:
            return .usage
        case is DeleteSourceError:
            return .usage
        case let error as TransferPlanError:
            switch error {
            case .conflict: return .conflict
            // A malformed argument, not a real destination collision — see
            // the case's own doc comment (M20 Task 10 fix).
            case .emptyDestinationDirectory: return .usage
            }
        case is SessionReferenceError:
            return .usage
        case let error as HostKeyError:
            switch error {
            case .mismatch: return .hostKeyMismatch
            case .rejectedByUser: return .hostKeyUnknown
            }
        case is StoredSessionConnectionError, is PasswordCommandError, is KeychainError:
            return .auth
        case let error as RemoteFSError:
            switch error {
            case .authenticationFailed, .jumpAuthenticationFailed:
                return .auth
            case .connectionFailed:
                return .connection
            case .notFound, .permissionDenied, .protocolError:
                return .remote
            }
        default:
            return .connection
        }
    }

    /// A readable line for stderr. `ExitCode`'s own message is empty by
    /// design (see the CLI's `main()` override), so without this the user
    /// would see nothing at all rather than a bare case name — this is
    /// strictly better than today's "Error: secretRequired", not a
    /// replacement for proper localization (CLI output stays plain English
    /// per the project's language policy).
    public static func message(for error: Error) -> String {
        switch error {
        case let error as TransferSourceError:
            switch error {
            case .isDirectory(let path):
                return "Error: '\(path)' is a directory; get/put transfer a single file only"
            }
        case let error as DeleteSourceError:
            switch error {
            case .isDirectory(let path):
                return "Error: '\(path)' is a directory; pass --recursive to delete it and its contents"
            case .isSessionRoot(let path):
                return "Error: '\(path)' is the session root; pass --recursive --allow-root-delete "
                    + "to delete everything under it"
            }
        case let error as TransferPlanError:
            switch error {
            case .conflict(let path):
                return "Error: destination already exists: \(path) "
                    + "(pass --on-conflict skip or --on-conflict overwrite)"
            case .emptyDestinationDirectory:
                return "Error: destination directory is empty"
            }
        case let error as SessionReferenceError:
            switch error {
            case .unknown(let name):
                return "Error: no stored session named '\(name)' "
                    + "(or the path is missing its 'name:' session prefix)"
            case .ambiguous(let name, let count):
                return "Error: '\(name)' matches \(count) stored sessions; disambiguate by UUID"
            }
        case let error as HostKeyError:
            switch error {
            case .mismatch(let host, let expected, let presented):
                return """
                    Error: host key MISMATCH for \(host) — expected \(expected), got \(presented). \
                    This can mean the host key legitimately changed, or a machine-in-the-middle attack. \
                    Not auto-resolvable: update the known-hosts entry only after confirming out of band.
                    """
            case .rejectedByUser:
                return "Error: unknown host key was not accepted "
                    + "(pass --accept-new to trust new hosts, or confirm interactively)"
            }
        case let error as StoredSessionConnectionError:
            switch error {
            case .loginSetSessionsNotSupported:
                return "Error: this session's credentials come from a login set, "
                    + "which the CLI does not resolve yet"
            case .jumpSessionsNotSupported:
                return "Error: this session dials through a jump host, "
                    + "which the CLI does not resolve yet"
            case .missingBackendConfiguration(let kind):
                // Names the protocol exactly as the two per-protocol messages
                // this replaced did (M22/T10) — the descriptor's badge label
                // is the one English name each backend already carries.
                return "Error: the stored session is missing its "
                    + "\(BackendDescriptor.descriptor(for: kind).badgeLabelDefault) configuration"
            case .secretRequired:
                return "Error: no secret available (checked --password-command, "
                    + "the environment, and the keychain)"
            case .incompleteConfiguration(let field):
                return "Error: the stored session's \(field) is missing or invalid"
            }
        case is PasswordCommandError:
            return "Error: --password-command failed: \(error)"
        case is KeychainError:
            return "Error: keychain access failed: \(error)"
        case let error as RemoteFSError:
            switch error {
            case .authenticationFailed:
                return "Error: authentication failed"
            case .jumpAuthenticationFailed:
                return "Error: authentication to the jump host failed"
            case .connectionFailed(let reason):
                return "Error: connection failed: \(reason)"
            case .notFound(let path):
                return "Error: not found: \(path)"
            case .permissionDenied(let path):
                return "Error: permission denied: \(path)"
            case .protocolError(let reason):
                return "Error: \(reason)"
            }
        default:
            // Stringifying an arbitrary, unmapped error is a FLOOR, not a
            // guarantee, and this comment used to claim the opposite: that
            // no error type reachable from a subcommand's `run()` carries
            // user-supplied secret material in an associated value. That
            // was measured false. A `URLError` from `URLSession` reached
            // here through any WebDAV operation, and an `NSError`'s
            // `description` prints its whole `userInfo` — including the
            // failing URL verbatim, userinfo component and all, so a stored
            // WebDAV session whose base URL carries `user:password@` handed
            // that password to stderr through this line.
            //
            // What makes the fallback safe is not a property of this switch
            // but a habit at every throw site: each backend wraps foreign
            // errors before they leave it (`WebDAVFileSystem.surfaceable`,
            // `S3FileSystem`'s `localizedDescription` wrapping,
            // `CitadelFileSystem`'s mapping). A backend that forgets is a
            // leak here, and this fallback cannot tell the difference —
            // which is exactly what happened on the WebDAV path, where the
            // wrap sat on the dial alone while six other operations threw
            // straight through.
            //
            // So: an error type that embeds user input, or a backend that
            // rethrows a foreign one unwrapped, leaks to stderr through
            // this line. Adding a case here is one fix; wrapping at the
            // throw site is the better one, because this fallback is not
            // the only thing that stringifies an error.
            return "Error: \(error)"
        }
    }
}
