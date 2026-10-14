import Testing
@testable import EMJobs

@Suite("EMJobs wiring")
struct EMJobsWiringTests {
    @Test func moduleName() {
        #expect(EMJobsModule.name == "EMJobs")
    }
}
