import Testing
@testable import EMAudio

@Suite("EMAudio wiring")
struct EMAudioWiringTests {
    @Test func moduleName() {
        #expect(EMAudioModule.name == "EMAudio")
    }
}
