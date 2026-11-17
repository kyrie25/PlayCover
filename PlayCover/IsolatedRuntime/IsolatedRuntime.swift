import AppKit
import Darwin

@_silgen_name("dylibify")
private func runtimeDylibify(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32

/// Opt-in signed runtime; PlayTools owns display, device and input compatibility.
enum IsolatedRuntime {
    // swiftlint:disable:next function_body_length
    static func launch(_ app: PlayApp) async throws {
        let bundleIdentifier = app.info.bundleIdentifier
        guard !bundleIdentifier.isEmpty, bundleIdentifier != "free_list",
              bundleIdentifier != ".", bundleIdentifier != "..",
              !bundleIdentifier.contains("/"), !bundleIdentifier.contains("\\"),
              !bundleIdentifier.contains("\0") else {
            throw "The app has an invalid bundle identifier."
        }
        guard app.hasPlayTools() else {
            throw "Install this app with PlayTools before enabling the isolated runtime."
        }
        guard !app.settings.settings.playChain else {
            throw "Disable PlayChain when using the isolated runtime; it supplies its own keychain."
        }
        guard let resources = Bundle.main.resourceURL,
              let runtime = Bundle(url: resources.appendingPathComponent("Runtime-Catalyst.app")),
              let runtimeID = runtime.bundleIdentifier,
              let executable = runtime.executableURL else {
            throw "The isolated runtime is missing from this PlayCover build."
        }

        let display = app.settings.settings
        let icon = Cacher.shared.resolveLocalIcon(
            at: app.url, bundleIdentifier: bundleIdentifier,
            bundleVersion: app.info.bundleVersion, primaryIconName: app.info.primaryIconName)
            .flatMap { dockIcon($0).tiffRepresentation }
        let source = app.url
        let executableName = app.info.executableName
        let installName = bundleIdentifier + ".app"
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(runtimeID).appendingPathComponent("Data")
        let guestHome = home.appendingPathComponent(bundleIdentifier)
        let apps = home.appendingPathComponent("apps")
        let target = apps.appendingPathComponent(installName)
        let logs = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")

        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let registry = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BaseiOSApp/keychain_slots.plist")
            let slot = try RuntimeKeychainSlots.ensureSlot(for: bundleIdentifier, registryURL: registry)
            try fileManager.createDirectory(at: guestHome, withIntermediateDirectories: true)
            let lock = open(guestHome.appendingPathComponent(".guest.lock").path, O_RDWR | O_CREAT, 0o600)
            guard lock >= 0 else { throw "Could not open the isolated runtime's launch lock." }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw "This game is already running. Quit it before launching again."
            }
            try fileManager.createDirectory(at: apps, withIntermediateDirectories: true)
            let staging = apps.appendingPathComponent(UUID().uuidString + ".noindex")
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: source, to: staging)
            let guestExec = staging.appendingPathComponent(executableName)
            let converted = staging.appendingPathComponent("converted-executable")
            let result = guestExec.path.withCString { sourcePath in
                converted.path.withCString { runtimeDylibify(sourcePath, $0) }
            }
            guard result == 0 else { throw "Could not prepare this game for the isolated runtime (\(result))." }
            try fileManager.removeItem(at: guestExec)
            try fileManager.moveItem(at: converted, to: guestExec)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guestExec.path)
            // The runner's generic display/device hooks conflict with PlayTools.
            if let icon { try icon.write(to: staging.appendingPathComponent(".playcover-icon.tiff")) }
            let features: [String: Any] = [
                "resolution": false, "deviceSpoof": false, "scene": false,
                "playCoverWidth": display.windowWidth, "playCoverHeight": display.windowHeight,
                "playCoverResizable": display.resolution == 6
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: features, format: .binary, options: 0)
            try data.write(to: staging.appendingPathComponent("RunnerFeatures.plist"), options: .atomic)
            // Conversion and extra resources invalidate the copied bundle seal.
            try Shell.signApp(guestExec)
            // Match IPA installation: only the generated copy loses quarantine.
            _ = try? Shell.run(print: false, "/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", staging.path)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
            try Data().write(to: apps.appendingPathComponent(".metadata_never_index"))
            flock(lock, LOCK_UN)
            try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent(bundleIdentifier + "-runtime.log")
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--launch-app", installName, "--keychain-slot", String(slot)]
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("MTL_") && !$0.key.hasPrefix("METAL_")
            }
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { task in
                if task.terminationStatus != 0 {
                    Log.shared.error("The isolated runtime exited with status \(task.terminationStatus). " +
                                     "See \(logURL.path) and Console's Runtime-Catalyst messages.")
                }
            }
            try process.run()
            Log.shared.log("Launched \(bundleIdentifier) with isolated runtime + PlayTools " +
                           "(PID \(process.processIdentifier)).")
        }.value
    }

    private static func dockIcon(_ source: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let bounds = NSRect(x: 100, y: 100, width: 824, height: 824)
            let mask = NSBezierPath(roundedRect: bounds, xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            shadow.set()
            NSColor.white.setFill()
            mask.fill()
            NSGraphicsContext.restoreGraphicsState()
            mask.addClip()
            source.draw(in: bounds)
            return true
        }
    }
}
