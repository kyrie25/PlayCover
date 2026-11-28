import AppKit
import CoreServices
import Darwin

@_silgen_name("dylibify")
private func runtimeDylibify(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32

/// Opt-in signed runtime; PlayTools owns display, device and input compatibility.
enum IsolatedRuntime {
    private struct GuestSpec {
        let bundleID, executableName, installName, displayName: String
        let source: URL
        let width, height: Int
        let resizable: Bool
        let icon: Data?
        let discordSettings: DiscordActivity
    }

    static func launch(_ app: PlayApp) async throws -> Process {
        let bundleIdentifier = app.info.bundleIdentifier
        try validateBundleID(bundleIdentifier)
        guard app.isolatedProcess?.isRunning != true else {
            throw "This game is already running. Quit it before launching again."
        }
        guard app.hasPlayTools() else {
            throw "Install this app with PlayTools before enabling the isolated runtime."
        }
        guard !app.settings.settings.playChain else {
            throw "Disable PlayChain when using the isolated runtime; it supplies its own keychain."
        }
        guard let resources = Bundle.main.resourceURL, RuntimeProvisioning.hasRuntimeSupport(in: resources) else {
            throw "The isolated runtime is missing from this PlayCover build."
        }

        let display = app.settings.settings
        let icon = Cacher.shared.resolveLocalIcon(
            at: app.url, bundleIdentifier: bundleIdentifier,
            bundleVersion: app.info.bundleVersion, primaryIconName: app.info.primaryIconName)
            .flatMap { dockIcon($0).tiffRepresentation }
        let source = app.url
        let executableName = app.info.executableName
        let displayName = app.name
        let artifacts = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")

        return try await Task.detached(priority: .userInitiated) {
            guard let runtime = try RuntimeProvisioning.resolveRuntimeBundle(
                    resources: resources, artifactsDirectory: artifacts, buildIfMissing: true),
                  runtime.bundleIdentifier != nil,
                  let executable = runtime.executableURL else {
                throw "The isolated runtime is missing from this PlayCover build."
            }
            let spec = GuestSpec(
                bundleID: bundleIdentifier, executableName: executableName,
                installName: bundleIdentifier + ".app", displayName: displayName,
                source: source,
                width: display.windowWidth, height: display.windowHeight,
                resizable: display.resolution == 6, icon: icon, discordSettings: display.discordActivity)
            return try prepareAndLaunch(spec, runtime: runtime, executableName: executable.lastPathComponent,
                                        resources: resources)
        }.value
    }

    private static func prepareAndLaunch(
        _ spec: GuestSpec, runtime: Bundle, executableName: String, resources: URL
    ) throws -> Process {
        let fileManager = FileManager.default
        let logs = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")
        let registry = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BaseiOSApp/keychain_slots.plist")
        let slot = try RuntimeKeychainSlots.ensureSlot(for: spec.bundleID, registryURL: registry)
        let profile = try RuntimeProvisioning.profile(for: runtime.bundleURL,
            cacheDirectory: logs.appendingPathComponent("Provisioning.noindex"),
            helper: resources.appendingPathComponent("RuntimeProvisioning/renew.sh"))
        let incomingID = UUID().uuidString
        let incoming = logs.appendingPathComponent("Incoming.noindex").appendingPathComponent(incomingID + ".noindex")
        var launched = false
        defer { if !launched { try? fileManager.removeItem(at: incoming) } }
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try prepareGuestBundle(spec, at: incoming.appendingPathComponent(spec.installName))
        let namedRuntime = try personalizedRuntime(runtime, profile: profile, name: spec.displayName, icon: spec.icon,
            folder: logs.appendingPathComponent(spec.bundleID + ".noindex"))
        // Game Mode resolves the runtime ID through LaunchServices, which
        // otherwise prefers the generic template nested in /Applications.
        _ = try? Shell.run(print: false, "/System/Library/Frameworks/CoreServices.framework/" +
                           "Frameworks/LaunchServices.framework/Support/lsregister", "-u", runtime.bundleURL.path)
        LSRegisterURL(namedRuntime as CFURL, true)
        let binary = namedRuntime.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        let logURL = logs.appendingPathComponent(spec.bundleID + "-runtime.log")
        let process = try startProcess(executable: binary, spec: spec, slot: slot, logURL: logURL,
                                       incoming: incoming)
        launched = true
        Log.shared.log("Launched \(spec.bundleID) with isolated runtime + PlayTools " +
                       "(PID \(process.processIdentifier)).")
        return process
    }

    private static func prepareGuestBundle(_ spec: GuestSpec, at staging: URL) throws {
        let fileManager = FileManager.default
        // Clone unchanged files on APFS while keeping the original executable for standard mode.
        let copyFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(spec.source.path, staging.path, nil, copyFlags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let guestExec = staging.appendingPathComponent(spec.executableName)
        let converted = staging.appendingPathComponent("converted-executable")
        let result = guestExec.path.withCString { sourcePath in
            converted.path.withCString { runtimeDylibify(sourcePath, $0) }
        }
        guard result == 0 else { throw "Could not prepare this game for the isolated runtime (\(result))." }
        try fileManager.removeItem(at: guestExec)
        try fileManager.moveItem(at: converted, to: guestExec)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guestExec.path)
        // The runner's generic display/device hooks conflict with PlayTools.
        if let icon = spec.icon { try icon.write(to: staging.appendingPathComponent(".playcover-icon.tiff")) }
        let features: [String: Any] = [
            "resolution": false, "deviceSpoof": false, "scene": false,
            "playCoverDisplayName": spec.displayName,
            "playCoverWidth": spec.width, "playCoverHeight": spec.height,
            "playCoverResizable": spec.resizable
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: features, format: .binary, options: 0)
        try data.write(to: staging.appendingPathComponent("RunnerFeatures.plist"), options: .atomic)
        // Conversion and extra resources invalidate the copied bundle seal.
        try Shell.signApp(guestExec)
        // Match IPA installation: only the generated copy loses quarantine.
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", staging.path)
    }

    private static func startProcess(
        executable: URL, spec: GuestSpec, slot: Int, logURL: URL, incoming: URL
    ) throws -> Process {
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--launch-app", spec.installName, "--keychain-slot", String(slot),
                             "--playcover-incoming", incoming.deletingPathExtension().lastPathComponent]
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("MTL_") && !$0.key.hasPrefix("METAL_")
        }
        process.standardOutput = output
        process.standardError = output
        let discord = IsolatedDiscordActivity.connection(enabled: spec.discordSettings.enable)
        process.terminationHandler = { task in
            discord?.cancel()
            try? FileManager.default.removeItem(at: incoming)
            if task.terminationReason == .exit && task.terminationStatus == 2 {
                Log.shared.error("This game is already running. Quit it before launching again.")
            } else if task.terminationStatus != 0 {
                Log.shared.error("The isolated runtime exited with status \(task.terminationStatus). " +
                                 "See \(logURL.path) and Console's Runtime-Catalyst messages.")
            }
        }
        try process.run()
        if let discord {
            Task {
                await IsolatedDiscordActivity.publish(on: discord, process: process, settings: spec.discordSettings,
                                                      name: spec.displayName, bundleID: spec.bundleID)
            }
        }
        return process
    }

    @MainActor private static var switchingGames = Set<String>()

    @MainActor static var isSwitchingRuntime: Bool { !switchingGames.isEmpty }

    @MainActor
    static func isSwitchingRuntime(for bundleID: String) -> Bool {
        switchingGames.contains(bundleID.lowercased())
    }

    @MainActor
    static func setEnabled(_ enabled: Bool, for app: PlayApp,
                           progress: @escaping @Sendable (RuntimeDataMigration.Progress) -> Void) async throws {
        guard enabled != app.settings.settings.useIsolatedRuntime else { return }
        let bundleID = app.info.bundleIdentifier
        try validateBundleID(bundleID)
        guard !isSwitchingRuntime(for: bundleID) else { throw "This game's data is already being moved." }
        guard !app.isStarting, app.isolatedProcess?.isRunning != true,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw "Quit the game before switching runtimes."
        }
        guard let resources = Bundle.main.resourceURL, RuntimeProvisioning.hasRuntimeSupport(in: resources) else {
            throw "The isolated runtime is missing from this PlayCover build."
        }
        let standard = app.container.containerUrl.appendingPathComponent("Data")
        let artifacts = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")
        let moveKey = bundleID.lowercased()
        switchingGames.insert(moveKey)
        defer { switchingGames.remove(moveKey) }

        try await Task.detached(priority: .userInitiated) {
            let resolved = try RuntimeProvisioning.resolveRuntimeBundle(
                resources: resources, artifactsDirectory: artifacts, buildIfMissing: enabled)?.bundleIdentifier
            guard let runtimeID = resolved
                    ?? RuntimeProvisioning.knownRuntimeID(resources: resources, artifactsDirectory: artifacts) else {
                throw "The isolated runtime is missing from this PlayCover build."
            }
            let home = dataHome(for: runtimeID)
            let isolated = home.appendingPathComponent(bundleID)
            let lock = try RuntimeUninstall.lockGuest(at: isolated)
            defer { if let lock { close(lock) } }
            try await RuntimeDataMigration.move(from: enabled ? standard : isolated,
                                                to: enabled ? isolated : standard, progress: progress) {
                if !enabled { try RuntimeUninstall.removePreparedBundles(bundleID: bundleID, home: home) }
                try await MainActor.run { try app.settings.setIsolatedRuntimeEnabled(enabled) }
            }
        }.value
        app.removeAlias()
        app.createAlias()
    }

    private static func knownRuntimeID() -> String? {
        RuntimeProvisioning.knownRuntimeID(
            resources: Bundle.main.resourceURL,
            artifactsDirectory: PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime"))
    }

    private static func dataHome(for runtimeID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(runtimeID).appendingPathComponent("Data")
    }

    private static func validateBundleID(_ bundleIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != "free_list",
              bundleIdentifier != ".", bundleIdentifier != "..",
              !bundleIdentifier.contains("/"), !bundleIdentifier.contains("\\"),
              !bundleIdentifier.contains("\0") else {
            throw "The app has an invalid bundle identifier."
        }
    }
}

extension IsolatedRuntime {
    static func dataDirectory(for bundleID: String) -> URL? {
        guard let runtimeID = knownRuntimeID() else { return nil }
        return dataHome(for: runtimeID).appendingPathComponent(bundleID)
    }

    @MainActor
    static func clearData(for bundleID: String) throws {
        guard !isSwitchingRuntime(for: bundleID) else { throw "Wait for this game's data to finish moving." }
        guard let runtimeID = knownRuntimeID() else { return }
        let home = dataHome(for: runtimeID)
        guard FileManager.default.fileExists(atPath: home.deletingLastPathComponent().path) else { return }
        try RuntimeUninstall.clearData(bundleID: bundleID, home: home)
    }

    @MainActor
    static func removeInstallation(for bundleID: String, clearData: Bool, checkRuntime: Bool = false) throws {
        guard !isSwitchingRuntime(for: bundleID) else { throw "Wait for this game's data to finish moving." }
        let files = FileManager.default
        let artifacts = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")
        guard let runtimeID = knownRuntimeID() else { return }
        let home = dataHome(for: runtimeID)
        let hasRuntimeContainer = files.fileExists(atPath: home.deletingLastPathComponent().path)
        let hasArtifacts = files.fileExists(atPath: artifacts.appendingPathComponent(bundleID + ".noindex").path)
            || files.fileExists(atPath: artifacts.appendingPathComponent(bundleID + "-runtime.log").path)
        guard checkRuntime || hasArtifacts || (clearData && hasRuntimeContainer) else { return }
        try RuntimeUninstall.remove(bundleID: bundleID, clearData: clearData, home: home,
                                    artifacts: artifacts)
    }
}

extension IsolatedRuntime {
    static func createLauncher(for app: PlayApp) throws {
        guard let resources = Bundle.main.resourceURL else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PlayApp.aliasDirectory, withIntermediateDirectories: true)
        let staging = PlayApp.aliasDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        let icons = contents.appendingPathComponent("Resources")
        try fileManager.createDirectory(at: binaries, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: icons, withIntermediateDirectories: true)
        try fileManager.copyItem(at: resources.appendingPathComponent("GameLauncher"),
                                 to: binaries.appendingPathComponent("GameLauncher"))
        var info: [String: Any] = [
            "CFBundleIdentifier": "io.playcover.launcher." + app.info.bundleIdentifier,
            "CFBundleName": app.name, "CFBundleDisplayName": app.name,
            "CFBundleExecutable": "GameLauncher", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSUIElement": true, "LSApplicationCategoryType": "public.app-category.games",
            "PlayCoverGuestIdentifier": app.info.bundleIdentifier,
            "PlayCoverHostPath": Bundle.main.bundleURL.path
        ]
        if let source = Cacher.shared.resolveLocalIcon(
            at: app.url, bundleIdentifier: app.info.bundleIdentifier,
            bundleVersion: app.info.bundleVersion, primaryIconName: app.info.primaryIconName),
           let tiff = dockIcon(source).tiffRepresentation, let icns = iconFile(tiff) {
            try icns.write(to: icons.appendingPathComponent("GameIcon.icns"))
            info["CFBundleIconFile"] = "GameIcon.icns"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Shell.run(print: false, "/usr/bin/codesign", "--force", "--sign", "-", staging.path)
        if fileManager.fileExists(atPath: app.aliasURL.path) {
            _ = try fileManager.replaceItemAt(app.aliasURL, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: app.aliasURL)
        }
        LSRegisterURL(app.aliasURL as CFURL, true)
    }

    private static func personalizedRuntime(_ runtime: Bundle, profile: Data, name: String, icon: Data?,
                                            folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".noindex")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let runtimeName = name.replacingOccurrences(of: "/", with: ":")
        let copy = staging.appendingPathComponent(runtimeName).appendingPathExtension("app")
        try fileManager.copyItem(at: runtime.bundleURL, to: copy)
        try profile.write(to: copy.appendingPathComponent("Contents/embedded.provisionprofile"), options: .atomic)
        let infoURL = copy.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil) as? [String: Any] ?? [:]
        // System UI resolves names/icons from bundle metadata, independently of
        // the running application's custom Dock image.
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        // Games' artwork lookup is case-sensitive, unlike LaunchServices.
        info["CFBundleIdentifier"] = runtime.bundleIdentifier?.lowercased()
        if let icon, let icns = iconFile(icon) {
            info["CFBundleIconFile"] = "PlayCoverGame.icns"
            try icns.write(to: copy.appendingPathComponent("Contents/Resources/PlayCoverGame.icns"))
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        // Retain the signed identifier and its sandbox/native-keychain identity.
        let identity = try RuntimeProvisioning.signingIdentity(for: runtime.bundleURL)
        try Shell.run(print: false, "/usr/bin/codesign", "--force", "--sign", identity,
                      "--preserve-metadata=identifier,entitlements,requirements,flags,runtime", copy.path)
        try Shell.run(print: false, "/usr/bin/codesign", "--verify", "--deep", "--strict", copy.path)
        if fileManager.fileExists(atPath: folder.path) {
            _ = try fileManager.replaceItemAt(folder, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: folder)
        }
        return folder.appendingPathComponent(copy.lastPathComponent)
    }

    private static func iconFile(_ image: Data) -> Data? {
        guard let png = NSBitmapImageRep(data: image)?.representation(using: .png, properties: [:]) else { return nil }
        // An ic10 element contains a 1024px PNG; IconServices derives smaller sizes.
        var result = Data("icns".utf8)
        for (tag, length) in [("", png.count + 16), ("ic10", png.count + 8)] {
            result.append(contentsOf: tag.utf8)
            var value = UInt32(length).bigEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        result.append(png)
        return result
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
