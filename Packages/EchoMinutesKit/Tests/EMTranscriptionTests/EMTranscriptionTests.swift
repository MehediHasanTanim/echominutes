import Testing
@testable import EMTranscription

@Suite("EMTranscription wiring")
struct EMTranscriptionWiringTests {
    @Test func moduleName() {
        #expect(EMTranscriptionModule.name == "EMTranscription")
    }
}
