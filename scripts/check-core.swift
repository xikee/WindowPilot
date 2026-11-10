import Foundation

@main enum CoreCheck {
    static func main() {
        var failures = 0
        for (name, run) in switchScenarios {
            do { try run(); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name): \(error)") }
        }
        print("\(switchScenarios.count - failures)/\(switchScenarios.count) 个场景通过")
        if failures > 0 { exit(1) }
    }
}
