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

        var committed = false
        try await RuntimeDataMigration.move(from: source, to: target, commit: { committed = true })
        precondition(committed && !exists(target))

        let state = try setupFixtures(root: root, source: source, target: target)
        try await testConflictAndRollback(source: source, target: target, state: state)
        try await testMoveAndRoundTrip(source: source, target: target, state: state)
        try await testInvalidDestinations(root: root, source: source, outside: state.outside)
        print("Runtime data migration tests passed")
    }

    private struct Fixtures {
        let file: URL
        let id: ino_t
        let ignored: [URL]
        let sourceCache: URL
        let targetCache: URL
        let sourceCacheID: ino_t
        let targetCacheID: ino_t
        let outside: URL
        let link: URL
        let sentinel: URL
        let shared: URL
        let sharedID: ino_t
    }

    private static func setupFixtures(root: URL, source: URL, target: URL) throws -> Fixtures {
        let file = try put("Library/Caches/download.bin", in: source)
        let ignored = try [".guest.lock", ".DS_Store", "tmp/temp", "Library/Keychains/item"].map {
            try put($0, in: source)
        }
        let webCache = "Library/Caches/WebKit/NetworkCache/Version 17/Blobs/fixture"
        let sourceCache = try put(webCache, in: source)
        let targetCache = try put(webCache, in: target)
        let outside = try put("outside/item", in: root)
        let link = source.appendingPathComponent("Movies")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let sentinel = try put("Library/Caches/preexisting", in: target)
        let shared = try put("Library/Caches/download.bin", in: target)
        return Fixtures(
            file: file, id: inode(file), ignored: ignored,
            sourceCache: sourceCache, targetCache: targetCache,
            sourceCacheID: inode(sourceCache), targetCacheID: inode(targetCache),
            outside: outside, link: link, sentinel: sentinel,
            shared: shared, sharedID: inode(shared))
    }

    private static func testConflictAndRollback(source: URL, target: URL, state: Fixtures) async throws {
        var committed = false
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: target, commit: { committed = true })
        }
        precondition(!committed && inode(state.shared) == state.sharedID && inode(state.file) == state.id)
        try FileManager.default.removeItem(at: state.shared)

        let other = try put("Documents/new/folder/settings", in: source)
        let otherID = inode(other)
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: target, commit: {
                precondition(!exists(state.file) && inode(state.shared) == state.id && !exists(other))
                throw POSIXError(.ENOSPC)
            })
        }
        precondition(inode(state.file) == state.id && inode(other) == otherID && !exists(state.shared))
        precondition(!exists(target.appendingPathComponent("Documents")))
    }

    private static func testMoveAndRoundTrip(source: URL, target: URL, state: Fixtures) async throws {
        let other = source.appendingPathComponent("Documents/new/folder/settings")
        let otherID = inode(other)
        var committed = false
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
        precondition(committed && inode(state.shared) == state.id && !exists(state.file))
        precondition(inode(target.appendingPathComponent("Documents/new/folder/settings")) == otherID)
        precondition(state.ignored.allSatisfy(exists) && exists(state.link)
                     && exists(state.outside) && exists(state.sentinel))
        try await RuntimeDataMigration.move(from: target, to: source)
        precondition(inode(state.file) == state.id && inode(other) == otherID && !exists(state.shared))
        precondition(inode(state.sourceCache) == state.sourceCacheID && inode(state.targetCache) == state.targetCacheID)
    }

    private static func testInvalidDestinations(root: URL, source: URL, outside: URL) async throws {
        let redirect = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(
            at: redirect, withDestinationURL: outside.deletingLastPathComponent())
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: redirect.appendingPathComponent("nested"))
        }
        await expectFailure {
            try await RuntimeDataMigration.move(from: source, to: source.appendingPathComponent("nested"))
        }
    }

    private static func put(_ path: String, in home: URL) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: url)
        return url
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func inode(_ url: URL) -> ino_t {
        var metadata = stat()
        precondition(lstat(url.path, &metadata) == 0)
        return metadata.st_ino
    }

    private static func expectFailure(_ action: () async throws -> Void) async {
        do { try await action(); fatalError("Expected migration to fail") } catch { }
    }
}
