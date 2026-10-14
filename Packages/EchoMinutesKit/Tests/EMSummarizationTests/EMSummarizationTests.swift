import Testing
@testable import EMSummarization

@Suite("EMSummarization wiring")
struct EMSummarizationWiringTests {
    @Test func moduleName() {
        #expect(EMSummarizationModule.name == "EMSummarization")
    }
}
