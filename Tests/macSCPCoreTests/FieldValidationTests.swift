import Foundation
import Testing
@testable import macSCPCore

@Suite struct FieldValidationTests {
    private let ssh = BackendDescriptor.descriptor(for: .ssh)

    private func sshValues(
        host: String = "example.com", port: String = "22",
        username: String = "tim", authKind: StoredSession.AuthKind = .password,
        password: String = "hunter2", keyPath: String = ""
    ) -> FieldValues {
        var values = FieldValues()
        values[SSHField.host] = host
        values[SSHField.port] = port
        values[SSHField.username] = username
        values[SSHField.authKind] = authKind.rawValue
        values[SSHField.password] = password
        values[SSHField.keyPath] = keyPath
        return values
    }

    @Test func aCompleteFormHasNoViolation() {
        #expect(ssh.firstViolation(in: sshValues(), requireSecrets: true) == nil)
    }

    @Test func aBlankRequiredFieldReportsItsOwnMessageAndKey() {
        let violation = ssh.firstViolation(in: sshValues(host: ""), requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.emptyHost")
        #expect(violation?.fieldKey == "SSHField.host")
    }

    /// Whitespace is not a value. A row of spaces in the host field used to
    /// reach `SSHConnectionConfig.init` and fail there with a different text.
    @Test func whitespaceDoesNotCountAsFilled() {
        let violation = ssh.firstViolation(in: sshValues(host: "   "), requireSecrets: true)
        #expect(violation?.fieldKey == "SSHField.host")
    }

    @Test func aNonNumericPortReportsThePortMessage() {
        let violation = ssh.firstViolation(in: sshValues(port: "http"), requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.portNumeric")
        #expect(violation?.fieldKey == "SSHField.port")
    }

    /// `SSHField.port` is `format: .numeric` but NOT `isRequired`, so a blank
    /// port is a live production path (the user clears the field) rather than
    /// the "blank + required" case `aBlankRequiredFieldReportsItsOwnMessageAndKey`
    /// already covers. `firstViolation`'s `isUnparsable` check
    /// (`field.format == .numeric && Int(value) == nil`) fires regardless of
    /// `isRequired` -- `Int("")` is nil the same as `Int("http")` is -- so a
    /// blank port must report the same violation a non-numeric one does. Before
    /// this test, blank was the one arm of that check the suite never entered.
    @Test func aBlankNumericFieldReportsThePortMessage() {
        let violation = ssh.firstViolation(in: sshValues(port: ""), requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.portNumeric")
        #expect(violation?.fieldKey == "SSHField.port")
    }

    /// A SECRET is checked verbatim, never trimmed: " " is a legal password
    /// and rejecting it would lock a user out of their own server.
    @Test func aSecretMadeOfSpacesIsAccepted() {
        #expect(ssh.firstViolation(in: sshValues(password: " "), requireSecrets: true) == nil)
    }

    @Test func anEmptySecretIsRejectedOnlyWhenSecretsAreRequired() {
        let values = sshValues(password: "")
        #expect(ssh.firstViolation(in: values, requireSecrets: true)?.fieldKey
                == "SSHField.password")
        #expect(ssh.firstViolation(in: values, requireSecrets: false) == nil)
    }

    /// The whole point of walking `visibleFields`: the auth-kind branching
    /// `connectSSH` did by hand falls out of the visibility conditions.
    @Test func anInvisibleFieldIsNotValidated() {
        // Agent auth shows neither secret nor key path.
        let agent = sshValues(authKind: .agent, password: "", keyPath: "")
        #expect(ssh.firstViolation(in: agent, requireSecrets: true) == nil)
        // Private-key auth shows the key path, and it is blank.
        let key = sshValues(authKind: .privateKey, password: "", keyPath: "")
        #expect(ssh.firstViolation(in: key, requireSecrets: true)?.fieldKey
                == "SSHField.keyPath")
    }

    @Test func s3ReportsItsOwnFieldsAndMessage() {
        var values = BackendDescriptor.descriptor(for: .s3).defaultValues
        values[S3Field.endpoint] = "https://s3.example.com"
        values[S3Field.region] = "eu-central-1"
        values[S3Field.bucket] = ""
        values[S3Field.accessKeyID] = "AKIA"
        values[S3Field.secretAccessKey] = "secret"
        let violation = BackendDescriptor.descriptor(for: .s3)
            .firstViolation(in: values, requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.s3FieldRequired")
        #expect(violation?.fieldKey == "S3Field.bucket")
    }

    @Test func webdavReportsItsOwnFieldsAndMessage() {
        var values = BackendDescriptor.descriptor(for: .webdav).defaultValues
        values[WebDAVField.baseURL] = ""
        values[WebDAVField.username] = "tim"
        values[WebDAVField.password] = "pw"
        let violation = BackendDescriptor.descriptor(for: .webdav)
            .firstViolation(in: values, requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.webdavFieldRequired")
        #expect(violation?.fieldKey == "WebDAVField.baseURL")
    }
}
