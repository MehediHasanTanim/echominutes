import Testing
@testable import EMStorage

@Suite("EMStorage wiring")
struct EMStorageWiringTests {
    @Test func moduleName() {
        #expect(EMStorageModule.name == "EMStorage")
    }
}
