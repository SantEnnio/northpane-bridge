import Testing
@testable import NorthpaneProtocol

@Test func capabilityRegistryDropsCapabilitiesWhoseDependenciesAreMissing() {
    #expect(CapabilityRegistry.validated([.terminalControl]) == [])
    #expect(CapabilityRegistry.validated([.observeRuntime, .terminalObserve, .terminalControl]) == [.observeRuntime, .terminalObserve, .terminalControl])
}

@Test func everyProblemCodeIsUniqueAndResolvable() {
    #expect(Set(ProblemCatalog.all.map(\.code)).count == ProblemCatalog.all.count)
    for problem in ProblemCatalog.all { #expect(ProblemCatalog.problem(code: problem.code) == problem) }
}
