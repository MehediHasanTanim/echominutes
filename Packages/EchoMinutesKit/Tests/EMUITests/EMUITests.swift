import Testing
@testable import EMUI

@Suite("EMUI wiring")
struct EMUIWiringTests {
    @Test func moduleName() {
        #expect(EMUIModule.name == "EMUI")
    }
}
