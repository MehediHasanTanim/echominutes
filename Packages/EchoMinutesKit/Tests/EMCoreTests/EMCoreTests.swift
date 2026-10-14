import Testing
@testable import EMCore

@Suite("EMCore wiring")
struct EMCoreWiringTests {
    @Test func moduleName() {
        #expect(EMCoreModule.name == "EMCore")
    }
}

@Suite("Module graph")
struct ModuleGraphTests {
    @Test func allModulesListed() {
        #expect(EchoMinutes.allModules.count == 10)
        #expect(Set(EchoMinutes.allModules).count == 10)
    }
}
