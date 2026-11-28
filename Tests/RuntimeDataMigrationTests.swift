import Darwin
import Foundation

@main
struct RuntimeDataMigrationTests {
    static func main() async throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("standard/Data")
        let target = root.appendingPathComponent("isolated/game")
        func put(_ path: String, in home: URL) throws -> URL {
            let url = home.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
            return url
        }
        func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }
        func inode(_ url: URL) -> ino_t {
            var metadata = stat()
            precondition(lstat(url.path, &metadata) == 0)
            return metadata.st_ino
        }
        func expectFailure(_ action: () async throws -> Void) async {
            do { try await action(); fatalError("Expected migration to fail") } catch { }
        }

        var committed = false
        try await RuntimeDataMigration.move(from: source, to: target, commit: { committed = true })
        precondition(committed && !exists(target))
        let file = try put("Library/Caches/download.bin", in: source)
        let id = inode(file)
        let ignored = try [".guest.lock", ".DS_Store", "tmp/temp", "Library/Keychains/item"].map {
            try put($0, in: source)
        }
        let webCache = "Library/Caches/WebKit/NetworkCache/Version 17/Blobs/fixture"
        let sourceCache = try put(webCache, in: source)
        let targetCache = try put(webCache, in: target)
        let sourceCacheID = inode(sourceCache)
        let targetCacheID = inode(targetCache)
        let outside = try put("outside/item", in: root)
        let link = source.appendingPathComponent("Movies")
        try files.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let sentinel = try put("Library/Caches/preexisting", in: target)
        let shared = try put("Library/Caches/download.bin", in: target)
        let sharedID = inode(shared)
        committed = false
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: target, commit: { committed = true })
        }
        precondition(!committed && inode(shared) == sharedID && inode(file) == id)
        try files.removeItem(at: shared)
        let other = try put("Documents/new/folder/settings", in: source)
        let otherID = inode(other)
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: target, commit: {
                precondition(!exists(file) && inode(shared) == id && !exists(other))
                throw POSIXError(.ENOSPC)
            })
        }
        precondition(inode(file) == id && inode(other) == otherID && !exists(shared))
        precondition(!exists(target.appendingPathComponent("Documents")))
        var fileCounts: [Int] = []
        var finished = false
        try await RuntimeDataMigration.move(from: source, to: target, progress: { progress in
            switch progress {
            case .moving(let count, let total, _):
                precondition(total == 2)
                fileCounts.append(count)
            case .finishing:
                finished = true
            default:
                break
            }
        }, commit: { committed = true })
        precondition(fileCounts.first == 0 && fileCounts.last == 2 && finished)
        precondition(committed && inode(shared) == id && !exists(file))
        precondition(inode(target.appendingPathComponent("Documents/new/folder/settings")) == otherID)
        precondition(ignored.allSatisfy(exists) && exists(link) && exists(outside) && exists(sentinel))
        try await RuntimeDataMigration.move(from: target, to: source)
        precondition(inode(file) == id && inode(other) == otherID && !exists(shared))
        precondition(inode(sourceCache) == sourceCacheID && inode(targetCache) == targetCacheID)
        let redirect = root.appendingPathComponent("redirect")
        try files.createSymbolicLink(at: redirect, withDestinationURL: outside.deletingLastPathComponent())
        await expectFailure { try await RuntimeDataMigration.move(from: source, to: redirect.appendingPathComponent("nested")) }
        await expectFailure { try await RuntimeDataMigration.move(from: source, to: source.appendingPathComponent("nested")) }
        print("Runtime data migration tests passed")
    }
}
