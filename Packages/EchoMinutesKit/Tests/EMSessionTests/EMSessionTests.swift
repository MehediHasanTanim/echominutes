import Testing
@testable import EMSession

@Suite("EMSession wiring")
struct EMSessionWiringTests {
    @Test func moduleName() {
        #expect(EMSessionModule.name == "EMSession")
    }
}
