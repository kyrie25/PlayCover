import Darwin
import Foundation

@main
struct RuntimeUninstallTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        defer { try? files.removeItem(at: root) }
        let home = root.appendingPathComponent("Data")
        let artifacts = root.appendingPathComponent("IsolatedRuntime")
        let id = "com.example.game"
        func remove(_ clear: Bool = false, id: String = "com.example.game") throws {
            try RuntimeUninstall.remove(bundleID: id, clearData: clear, home: home, artifacts: artifacts)
        }
        func directory(_ url: URL) throws {
            try files.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ info: [String: Any], at url: URL) throws {
            try directory(url.deletingLastPathComponent())
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url)
        }
        func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }
        func fails(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected removal to fail") } catch { }
        }
        try remove(true)
        for reserved in ["../other", "apps.noindex", "Provisioning", ".hidden", "Library", "tmp", "APPS"] {
            fails { try remove(true, id: reserved) }
        }
        let modern = home.appendingPathComponent("apps.noindex/" + id + ".app")
        let legacy = home.appendingPathComponent("apps/" + id + ".app")
        let sibling = home.appendingPathComponent("apps.noindex/com.example.other.app")
        let named = artifacts.appendingPathComponent(id + ".noindex")
        let generated = named.appendingPathComponent("Example.app")
        let data = home.appendingPathComponent(id)
        let lock = data.appendingPathComponent(".guest.lock")
        let log = artifacts.appendingPathComponent(id + "-runtime.log")
        try directory(sibling)
        try directory(data)
        try Data().write(to: lock)
        for app in [modern, legacy] {
            try write(["CFBundleIdentifier": id], at: app.appendingPathComponent("Info.plist"))
            try write(["playCoverWidth": 1920], at: app.appendingPathComponent("RunnerFeatures.plist"))
        }
        try write(["CFBundleExecutable": "Runtime-Catalyst",
                   "CFBundleIdentifier": "team.dev.ohaiibuzzle.BaseiOSApp.RuntimeCatalyst"],
                  at: generated.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: log)
        let descriptor = open(lock.path, O_RDWR)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
        fails { try remove(true) }
        precondition([modern, legacy, named, log, data].allSatisfy(exists))
        close(descriptor)
        try remove()
        precondition(![modern, legacy, named, log].contains(where: exists))
        precondition(exists(sibling) && exists(data))
        // A same-ID standalone installation has no PlayCover marker.
        try write(["CFBundleIdentifier": id], at: legacy.appendingPathComponent("Info.plist"))
        try directory(named.appendingPathComponent("Unrelated.app"))
        try remove(true)
        precondition(exists(legacy) && exists(named) && !exists(data))
        // A game can be uninstalled after moving its data but before its first isolated launch.
        try directory(data)
        try remove(true)
        precondition(!exists(data))
        try files.createSymbolicLink(at: modern, withDestinationURL: sibling)
        fails { try remove(true) }
        precondition(exists(sibling))
        try files.removeItem(at: modern)
        try files.createSymbolicLink(at: data, withDestinationURL: sibling)
        fails { try remove(true) }
        precondition(exists(sibling))
        print("Runtime uninstall tests passed")
    }
}
