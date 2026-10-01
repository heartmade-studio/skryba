import Testing
@testable import Skryba

@Suite struct UpdateCheckerTests {
    @Test func numericReleaseComparison() {
        let current = UpdateChecker.Version("1.5")!
        #expect(UpdateChecker.Version("v1.6")! > current)
        #expect(UpdateChecker.Version("v1.5.1")! > current)
        #expect(UpdateChecker.Version("v1.5.0")! == current)
        #expect(UpdateChecker.Version("v1.4.9")! < current)
        #expect(UpdateChecker.Version("v1.10")! > UpdateChecker.Version("v1.9")!)
    }

    @Test func rejectInvalidReleaseTags() {
        #expect(UpdateChecker.Version("v1.6-beta") == nil)
        #expect(UpdateChecker.Version("../1.6") == nil)
        #expect(UpdateChecker.Version("v1.+6") == nil)
        #expect(UpdateChecker.Version("v1.6/") == nil)
    }
}
