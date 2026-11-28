import Darwin
import Foundation

enum RuntimeDataMigration {
    enum Progress: Sendable {
        case preparing
        case moving(files: Int, total: Int, filesPerSecond: Int)
        case finishing
        case restoring
    }

    /// The caller holds the per-game lock until the files and launch setting have both moved.
    static func move(from source: URL, to destination: URL,
                     progress: (Progress) -> Void = { _ in },
                     commit: () async throws -> Void = {}) async throws {
        let sourceParts = source.pathComponents.map { $0.lowercased() }
        let destinationParts = destination.pathComponents.map { $0.lowercased() }
        guard !sourceParts.starts(with: destinationParts), !destinationParts.starts(with: sourceParts),
              !sourceParts.contains(".."), !destinationParts.contains("..") else {
            throw failure("The two game data folders overlap or contain an invalid path.")
        }
        var ancestors = [URL]()
        try inspectDirectories(to: source, missing: &ancestors)
        guard ancestors.isEmpty else {
            progress(.finishing)
            try await commit()
            return
        }
        try inspectDirectories(to: destination, missing: &ancestors)
        var plan = ancestors.map { Step.directory($0) }
        try inspect(source: source, destination: destination, relativePath: "", plan: &plan)
        let total = plan.reduce(0) { count, step in count + (step.isFile ? 1 : 0) }
        let started = ProcessInfo.processInfo.systemUptime
        var lastUpdate = started
        var moved = 0
        var applied = 0
        if total > 0 { progress(.moving(files: 0, total: total, filesPerSecond: 0)) }
        do {
            for step in plan {
                try step.apply()
                applied += 1
                guard step.isFile else { continue }
                moved += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 || moved == total {
                    let rate = Int(Double(moved) / max(now - started, 0.001))
                    progress(.moving(files: moved, total: total, filesPerSecond: rate))
                    lastUpdate = now
                }
            }
            progress(.finishing)
            try await commit()
        } catch {
            if applied > 0 { progress(.restoring) }
            let original = error
            var rollbackError: Error?
            for step in plan.prefix(applied).reversed() {
                do { try step.undo() } catch { rollbackError = rollbackError ?? error }
            }
            if let rollbackError {
                throw failure("Game data migration failed: \(original.localizedDescription). " +
                              "Could not fully restore the files: \(rollbackError.localizedDescription)")
            }
            throw original
        }
    }

    private enum Step {
        case directory(URL)
        case file(URL, URL)

        var isFile: Bool {
            if case .file = self { return true }
            return false
        }

        func apply() throws {
            switch self {
            case .directory(let url): try RuntimeDataMigration.changeDirectory(url, create: true)
            case let .file(src, dst): try RuntimeDataMigration.rename(src, dst)
            }
        }

        func undo() throws {
            switch self {
            case .directory(let url): try RuntimeDataMigration.changeDirectory(url, create: false)
            case let .file(src, dst): try RuntimeDataMigration.rename(dst, src)
            }
        }
    }

    private static func inspectDirectories(to url: URL, missing: inout [URL]) throws {
        if url.path == "/" { return }
        try inspectDirectories(to: url.deletingLastPathComponent(), missing: &missing)
        if let kind = try type(of: url) {
            guard kind == S_IFDIR else { throw failure("Expected a game data directory at \(url.path).") }
        } else {
            missing.append(url)
        }
    }

    private static func inspect(source: URL, destination: URL, relativePath: String, plan: inout [Step]) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let name = entry.lastPathComponent
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            // WebKit's network cache is protected by macOS and can be rebuilt in either mode.
            if childPath.lowercased() == "library/caches/webkit" { continue }
            // Keep the lock, local caches of credentials, and OS-managed scaffolding in their original homes.
            if [".guest.lock", ".ds_store", "tmp", "keychains", ".com.apple.containermanagerd.metadata.plist"]
                .contains(name.lowercased()) { continue }
            guard let kind = try type(of: entry), kind == S_IFDIR || kind == S_IFREG else { continue }
            let target = destination.appendingPathComponent(name)
            let existing = try type(of: target)
            if kind == S_IFDIR && (existing == nil || existing == S_IFDIR) {
                if existing == nil { plan.append(.directory(target)) }
                try inspect(source: entry, destination: target, relativePath: childPath, plan: &plan)
            } else if kind == S_IFREG && existing == nil {
                plan.append(.file(entry, target))
            } else {
                throw failure("Game data already exists at \(target.path). Resolve the conflict before switching modes.")
            }
        }
    }

    private static func type(of url: URL) throws -> mode_t? {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return metadata.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw filesystemError(url)
    }

    private static func changeDirectory(_ url: URL, create: Bool) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw filesystemError(url) }
        defer { close(parent) }
        let result = create ? mkdirat(parent, url.lastPathComponent, 0o700)
            : unlinkat(parent, url.lastPathComponent, AT_REMOVEDIR)
        if result != 0 { throw filesystemError(url) }
    }

    private static func rename(_ source: URL, _ destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) != 0 {
            throw filesystemError(source)
        }
    }

    private static func filesystemError(_ url: URL) -> NSError {
        let code = Int(errno)
        let reason = NSError(domain: NSPOSIXErrorDomain, code: code).localizedDescription
        return NSError(domain: NSPOSIXErrorDomain, code: code,
                       userInfo: [NSFilePathErrorKey: url.path,
                                  NSLocalizedDescriptionKey: "Could not migrate game data at \(url.path): \(reason)"])
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.playcover.PlayCover.RuntimeDataMigration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
