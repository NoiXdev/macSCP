import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferPlan")
struct TransferPlanTests {
    @Test func fileIntoDirectoryKeepsTheName() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: false, action: .fail)
        #expect(jobs == [TransferJob(source: "/local/dist.tar.gz",
                                     destination: "/tmp/dist.tar.gz")])
    }

    /// The default refuses rather than overwrites. A nightly `put` that
    /// silently replaces a production file is the accident no default may
    /// enable.
    @Test func anExistingDestinationFailsByDefault() {
        #expect(throws: TransferPlanError.conflict("/tmp/dist.tar.gz")) {
            try TransferPlan.jobs(
                source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
                destinationExists: true, action: .fail)
        }
    }

    @Test func skipYieldsNoJob() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: true, action: .skip)
        #expect(jobs.isEmpty)
    }

    @Test func overwriteYieldsTheJobAnyway() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: true, action: .overwrite)
        #expect(jobs.count == 1)
    }
}
