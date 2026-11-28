import Foundation

/// Run with a signed runtime template, an expired profile for that identity, and the bundled renewal helper.
@main
struct RuntimeProvisioningTests {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw "Usage: runtime-provisioning-tests <runtime.app> <expired.provisionprofile> <helper>"
        }
        let inputs = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        let (template, expiredProfile, helper) = (inputs[0], inputs[1], inputs[2])
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }

        let runtime = root.appendingPathComponent(template.lastPathComponent)
        try files.copyItem(at: template, to: runtime)
        let profile = runtime.appendingPathComponent("Contents/embedded.provisionprofile")
        let cache = root.appendingPathComponent("cache")
        let missing = root.appendingPathComponent("missing-helper")
        let current = try Data(contentsOf: profile)
        let selected = try RuntimeProvisioning.profile(for: runtime, cacheDirectory: cache, helper: missing)
        guard current == selected else { throw "A valid embedded profile should work offline." }

        let expired = try Data(contentsOf: expiredProfile)
        try expired.write(to: profile, options: .atomic)
        try expectFailure {
            _ = try RuntimeProvisioning.profile(for: runtime, cacheDirectory: cache, helper: missing)
        }
        let invalid = root.appendingPathComponent("invalid-helper")
        try Data("echo invalid > \"$3/embedded.provisionprofile\"".utf8).write(to: invalid)
        try expectFailure {
            _ = try RuntimeProvisioning.profile(for: runtime, cacheDirectory: cache, helper: invalid)
        }
        let renewed = try RuntimeProvisioning.profile(for: runtime, cacheDirectory: cache, helper: helper)
        guard renewed != expired else { throw "The expired profile was used after renewal." }
        let cached = try RuntimeProvisioning.profile(for: runtime, cacheDirectory: cache, helper: missing)
        guard renewed == cached else { throw "The renewed profile was not available offline." }
        let embedded = try Data(contentsOf: profile)
        guard embedded == expired else { throw "Renewal modified the template." }
        print("Runtime provisioning tests passed")
    }

    static func expectFailure(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw "An expired profile and unsuccessful helper should fail."
    }
}
