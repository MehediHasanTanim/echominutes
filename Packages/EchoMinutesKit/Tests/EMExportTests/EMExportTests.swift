import Testing
@testable import EMExport

@Suite("EMExport wiring")
struct EMExportWiringTests {
    @Test func moduleName() {
        #expect(EMExportModule.name == "EMExport")
    }
}
