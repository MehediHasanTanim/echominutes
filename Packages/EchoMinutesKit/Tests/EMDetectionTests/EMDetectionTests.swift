import Testing
@testable import EMDetection

@Suite("EMDetection wiring")
struct EMDetectionWiringTests {
    @Test func moduleName() {
        #expect(EMDetectionModule.name == "EMDetection")
    }
}
