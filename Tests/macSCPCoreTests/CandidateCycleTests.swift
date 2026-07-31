import Testing
@testable import macSCPCore

@Suite("CandidateCycle")
struct CandidateCycleTests {
    // MARK: - next

    @Test func nextFromNilIsFirst() {
        #expect(CandidateCycle.next(from: nil, count: 3) == 0)
    }

    @Test func nextWrapsFromLastToFirst() {
        #expect(CandidateCycle.next(from: 2, count: 3) == 0)
    }

    @Test func nextAdvancesByOne() {
        #expect(CandidateCycle.next(from: 0, count: 3) == 1)
        #expect(CandidateCycle.next(from: 1, count: 3) == 2)
    }

    @Test func nextWithZeroCandidatesIsNil() {
        #expect(CandidateCycle.next(from: nil, count: 0) == nil)
        #expect(CandidateCycle.next(from: 0, count: 0) == nil)
    }

    @Test func nextWithOneCandidateAlwaysStaysAtZero() {
        #expect(CandidateCycle.next(from: nil, count: 1) == 0)
        #expect(CandidateCycle.next(from: 0, count: 1) == 0)
    }

    // MARK: - previous

    @Test func previousFromNilIsLast() {
        #expect(CandidateCycle.previous(from: nil, count: 3) == 2)
    }

    @Test func previousWrapsFromFirstToLast() {
        #expect(CandidateCycle.previous(from: 0, count: 3) == 2)
    }

    @Test func previousStepsBackByOne() {
        #expect(CandidateCycle.previous(from: 2, count: 3) == 1)
        #expect(CandidateCycle.previous(from: 1, count: 3) == 0)
    }

    @Test func previousWithZeroCandidatesIsNil() {
        #expect(CandidateCycle.previous(from: nil, count: 0) == nil)
        #expect(CandidateCycle.previous(from: 0, count: 0) == nil)
    }

    @Test func previousWithOneCandidateAlwaysStaysAtZero() {
        #expect(CandidateCycle.previous(from: nil, count: 1) == 0)
        #expect(CandidateCycle.previous(from: 0, count: 1) == 0)
    }
}
