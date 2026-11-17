import Foundation
import Darwin

/// Shares the upstream host's registry and lock protocol, preserving existing slots.
enum RuntimeKeychainSlots {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func ensureSlot(for bundleID: String, registryURL: URL) throws -> Int {
        let fileManager = FileManager.default
        let directory = registryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".keychain_slots.lock").path
        let deadline = Date().addingTimeInterval(10)
        var descriptor: Int32 = -1
        while descriptor < 0 {
            descriptor = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if descriptor >= 0 { break }
            guard errno == EEXIST else { throw SlotError.lockUnavailable }
            if let attributes = try? fileManager.attributesOfItem(atPath: lockPath),
               let created = attributes[.creationDate] as? Date,
               Date().timeIntervalSince(created) > 10 {
                unlink(lockPath)
                continue
            }
            guard Date() < deadline else { throw SlotError.lockUnavailable }
            usleep(20_000)
        }
        defer { close(descriptor); unlink(lockPath) }

        var registry: [String: Any] = [:]
        if fileManager.fileExists(atPath: registryURL.path) {
            let data = try Data(contentsOf: registryURL)
            let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let decoded = decoded as? [String: Any] else {
                throw SlotError.invalidRegistry
            }
            registry = decoded
        }
        guard bundleID != "free_list", !bundleID.isEmpty else { throw SlotError.invalidRegistry }
        let assignments = registry.filter { $0.key != "free_list" }
        let assigned = try assignments.values.map { value -> Int in
            guard let number = value as? NSNumber, (0...127).contains(number.intValue),
                  number.doubleValue == Double(number.intValue) else { throw SlotError.invalidRegistry }
            return number.intValue
        }
        guard Set(assigned).count == assigned.count else { throw SlotError.invalidRegistry }
        if let existing = registry[bundleID] as? NSNumber { return existing.intValue }

        let slot: Int
        if let rawFreeList = registry["free_list"] {
            guard let freeList = rawFreeList as? [Int],
                  freeList.allSatisfy({ (1...127).contains($0) && !assigned.contains($0) }),
                  Set(freeList).count == freeList.count else { throw SlotError.invalidRegistry }
            slot = freeList.first ?? ((assigned.max() ?? 0) + 1)
            registry["free_list"] = Array(freeList.dropFirst())
        } else {
            slot = (assigned.max() ?? 0) + 1
        }
        guard slot <= 127 else { throw SlotError.slotsExhausted }
        registry[bundleID] = slot
        let data = try PropertyListSerialization.data(fromPropertyList: registry, format: .binary, options: 0)
        try data.write(to: registryURL, options: .atomic)
        return slot
    }

    enum SlotError: LocalizedError {
        case lockUnavailable, invalidRegistry, slotsExhausted

        var errorDescription: String? {
            switch self {
            case .lockUnavailable: return "Could not lock the isolated runtime's keychain registry."
            case .invalidRegistry: return "The isolated runtime's keychain registry is invalid; no slots were changed."
            case .slotsExhausted: return "All 127 isolated keychain slots are in use."
            }
        }
    }
}
