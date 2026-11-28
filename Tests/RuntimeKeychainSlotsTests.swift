import Foundation

@main
struct RuntimeKeychainSlotsTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = directory.appendingPathComponent("slots.plist")
        func save(_ values: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: registry)
        }
        func slot(_ bundleID: String) throws -> Int {
            try RuntimeKeychainSlots.ensureSlot(for: bundleID, registryURL: registry)
        }
        func expectFailure(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected allocation failure") } catch { }
        }
        // Preserve the upstream standalone assignment; never reuse its keychain.
        try save(["com.nexon.bluearchive": 1])
        let blueArchive = try slot("com.nexon.bluearchive")
        let other = try slot("com.example.other")
        let repeated = try slot("com.example.other")
        precondition(blueArchive == 1 && other == 2 && repeated == 2)
        try save(["com.example.old": 4, "free_list": [2, 3]])
        let reclaimed = try slot("com.example.new")
        let next = try slot("com.example.next")
        precondition(reclaimed == 2 && next == 3)
        try save(["com.example.old": 127])
        expectFailure { _ = try slot("com.example.full") }
        try save(["com.example.old": 1, "free_list": [1]])
        expectFailure { _ = try slot("com.example.collision") }
        try save(["com.example.old": 1, "com.example.duplicate": 1])
        expectFailure { _ = try slot("com.example.collision") }
        try Data("invalid registry".utf8).write(to: registry)
        let before = try Data(contentsOf: registry)
        expectFailure { _ = try slot("com.example.corrupt") }
        let after = try Data(contentsOf: registry)
        precondition(after == before)
        try save([:])
        let failures = AllocationFailures()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                _ = try RuntimeKeychainSlots.ensureSlot(
                    for: "com.example.concurrent.\(index)", registryURL: registry)
            } catch {
                failures.record()
            }
        }
        let data = try Data(contentsOf: registry)
        let allocated = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Int]
        precondition(failures.count == 0 && Set(allocated?.values.map { $0 } ?? []) == Set(1...16))
        print("Runtime keychain slot tests passed")
    }
}

private final class AllocationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
