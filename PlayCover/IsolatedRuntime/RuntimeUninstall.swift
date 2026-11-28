import Darwin
import Foundation

enum RuntimeUninstall {
    static func remove(bundleID: String, clearData: Bool, home: URL, artifacts: URL) throws {
        let reserved = ["apps", "apps.noindex", "free_list", "library", "documents", "tmp", "provisioning",
                        "applications", "desktop", "downloads", "movies", "music", "pictures", "public", "systemdata"]
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."), !bundleID.contains("/"), !bundleID.contains("\\"),
              !bundleID.contains("\0"), !reserved.contains(bundleID.lowercased()) else {
            throw failure("Invalid isolated guest identifier.")
        }
        let guest = home.appendingPathComponent(bundleID)
        let hasHome = try directory(home.deletingLastPathComponent()) && directory(home)
        let lock = try hasHome ? lockGuest(at: guest, createIfMissing: clearData) : nil
        defer { if let lock { close(lock) } }
        if hasHome { try removePreparedBundles(bundleID: bundleID, home: home) }
        // Keep the log and named runtime available for a retry if deleting data fails.
        if clearData && lock != nil { try FileManager.default.removeItem(at: guest) }
        if try directory(artifacts.deletingLastPathComponent()) && directory(artifacts) {
            let named = artifacts.appendingPathComponent(bundleID + ".noindex")
            if try directory(named) {
                for app in try FileManager.default.contentsOfDirectory(at: named, includingPropertiesForKeys: nil)
                    where app.pathExtension == "app" {
                    let contents = app.appendingPathComponent("Contents")
                    guard try directory(app), try directory(contents),
                          let info = try plist(contents.appendingPathComponent("Info.plist")),
                          info["CFBundleExecutable"] as? String == "Runtime-Catalyst",
                          let identifier = info["CFBundleIdentifier"] as? String,
                          identifier.lowercased().hasSuffix(".dev.ohaiibuzzle.baseiosapp.runtimecatalyst")
                    else { continue }
                    try FileManager.default.removeItem(at: app)
                }
                if rmdir(named.path) != 0 && errno != ENOTEMPTY {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            let log = artifacts.appendingPathComponent(bundleID + "-runtime.log")
            if try type(of: log) == S_IFREG { try FileManager.default.removeItem(at: log) }
        }
    }

    static func lockGuest(at guest: URL, createIfMissing: Bool = false) throws -> Int32? {
        guard try directory(guest) else { return nil }
        let lockFile = guest.appendingPathComponent(".guest.lock")
        let kind = try type(of: lockFile)
        guard kind != nil || createIfMissing else { return nil }
        guard kind == nil || kind == S_IFREG else {
            throw failure("Unexpected isolated guest lock at \(lockFile.path).")
        }
        let access = createIfMissing ? O_RDWR | O_CREAT : O_RDONLY
        let lock = open(lockFile.path, access | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw failure("Quit the isolated game before changing its files.")
        }
        return lock
    }

    static func removePreparedBundles(bundleID: String, home: URL) throws {
        for folder in ["apps.noindex", "apps"] {
            let apps = home.appendingPathComponent(folder)
            guard try directory(apps) else { continue }
            let bundle = apps.appendingPathComponent(bundleID + ".app")
            guard try directory(bundle),
                  try plist(bundle.appendingPathComponent("RunnerFeatures.plist"))?["playCoverWidth"] != nil,
                  try plist(bundle.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
                    == bundleID else { continue }
            try FileManager.default.removeItem(at: bundle)
        }
    }

    private static func directory(_ url: URL) throws -> Bool {
        guard let kind = try type(of: url) else { return false }
        guard kind == S_IFDIR else { throw failure("Expected an isolated runtime directory at \(url.path).") }
        return true
    }

    private static func type(of url: URL) throws -> mode_t? {
        var data = stat()
        if lstat(url.path, &data) == 0 { return data.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func plist(_ url: URL) throws -> [String: Any]? {
        guard try type(of: url) == S_IFREG else { return nil }
        let data = try Data(contentsOf: url)
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.playcover.PlayCover.RuntimeUninstall", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
