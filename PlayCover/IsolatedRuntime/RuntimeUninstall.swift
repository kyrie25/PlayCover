import Darwin
import Foundation

enum RuntimeUninstall {
    private static let reservedNames: Set<String> = [
        "apps", "apps.noindex", "free_list", "library", "documents", "tmp", "provisioning",
        "applications", "desktop", "downloads", "movies", "music", "pictures", "public", "systemdata"
    ]

    static func remove(bundleID: String, clearData: Bool, home: URL, artifacts: URL) throws {
        try validateBundleID(bundleID)
        let guest = home.appendingPathComponent(bundleID)
        let hasHome = try directory(home.deletingLastPathComponent()) && directory(home)
        let lock = try hasHome ? lockGuest(at: guest, createIfMissing: clearData) : nil
        defer { if let lock { close(lock) } }
        if hasHome { try removePreparedBundles(bundleID: bundleID, home: home) }
        // Keep the log and named runtime available for a retry if deleting data fails.
        if clearData && lock != nil { try removeTree(at: guest, allowProtectedRemainder: true) }
        try removeArtifacts(bundleID: bundleID, artifacts: artifacts)
    }

    static func clearData(bundleID: String, home: URL) throws {
        try validateBundleID(bundleID)
        guard try directory(home.deletingLastPathComponent()) && directory(home) else { return }
        let guest = home.appendingPathComponent(bundleID)
        let lock = try lockGuest(at: guest, createIfMissing: true)
        defer { if let lock { close(lock) } }
        guard lock != nil else { return }
        try removeTree(at: guest, allowProtectedRemainder: true)
    }

    /// Removes `url` without following symlinks. On modern macOS, `containermanagerd`
    /// protects container roots, metadata plists, and WebKit caches with EPERM; when
    /// `allowProtectedRemainder` is true, removable contents are still purged instead
    /// of aborting at the first protected file.
    static func removeTree(at url: URL, allowProtectedRemainder: Bool = false) throws {
        guard let kind = try type(of: url) else { return }
        if kind != S_IFDIR {
            try removeNonDirectory(at: url, allowProtectedRemainder: allowProtectedRemainder)
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            return
        } catch where allowProtectedRemainder && isPermissionError(error) {
            try purgeDirectoryContents(at: url)
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

    private static func removeArtifacts(bundleID: String, artifacts: URL) throws {
        guard try directory(artifacts.deletingLastPathComponent()) && directory(artifacts) else { return }
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

    private static func removeNonDirectory(at url: URL, allowProtectedRemainder: Bool) throws {
        if unlink(url.path) == 0 || errno == ENOENT { return }
        if allowProtectedRemainder && (errno == EPERM || errno == EACCES) { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func purgeDirectoryContents(at url: URL) throws {
        // If the directory itself cannot even be listed, propagate the permission error.
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for child in children {
            do {
                try removeTree(at: child, allowProtectedRemainder: true)
            } catch where isPermissionError(error) {
                continue
            }
        }
        if rmdir(url.path) != 0 && errno != ENOENT && errno != ENOTEMPTY && errno != EPERM && errno != EACCES {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EPERM) || nsError.code == Int(EACCES)
        }
        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    private static func validateBundleID(_ bundleID: String) throws {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("."), !bundleID.contains("/"), !bundleID.contains("\\"),
              !bundleID.contains("\0"), !reservedNames.contains(bundleID.lowercased()) else {
            throw failure("Invalid isolated guest identifier.")
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
