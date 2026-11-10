import XCTest

final class SwitchSessionTests: XCTestCase {
    func testSwitchingScenarios() throws {
        for (name, run) in switchScenarios {
            do { try run() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
