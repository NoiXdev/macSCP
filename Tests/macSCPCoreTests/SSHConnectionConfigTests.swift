import Testing
@testable import macSCPCore

@Suite("SSHConnectionConfig")
struct SSHConnectionConfigTests {
    @Test func defaultsToPort22() throws {
        let config = try SSHConnectionConfig(host: "example.com", username: "tim", auth: .password("x"))
        #expect(config.port == 22)
    }

    @Test func emptyHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyHost) {
            _ = try SSHConnectionConfig(host: "", username: "tim", auth: .password("x"))
        }
    }

    @Test func emptyUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "", auth: .password("x"))
        }
    }

    @Test func whitespaceOnlyHostThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyHost) {
            _ = try SSHConnectionConfig(host: "   ", username: "tim", auth: .password("x"))
        }
    }

    @Test func whitespaceOnlyUsernameThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.emptyUsername) {
            _ = try SSHConnectionConfig(host: "example.com", username: "\t", auth: .password("x"))
        }
    }

    @Test func portOutOfRangeThrows() {
        #expect(throws: SSHConnectionConfig.ConfigError.invalidPort(70000)) {
            _ = try SSHConnectionConfig(host: "example.com", port: 70000, username: "tim", auth: .password("x"))
        }
    }
}
