import Foundation
import Testing
@testable import macSCPCore

/// `UpdateSchedule.shouldCheck` (spec §2): the pure once-a-day interval rule
/// behind the automatic (non-manual) update check.
@Suite("UpdateSchedule")
struct UpdateScheduleTests {
    @Test func respectsDisabledAndInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, enabled: false) == false)
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, enabled: true) == true)

        let justUnder24h = now.addingTimeInterval(-(24 * 3600 - 60))
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: justUnder24h, enabled: true) == false)

        let justOver24h = now.addingTimeInterval(-(24 * 3600 + 60))
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: justOver24h, enabled: true) == true)
    }
}
