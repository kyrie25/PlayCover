import AppKit
import CryptoKit
import CoreServices
import Darwin
import Security

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
        let discordSettings = display.discordActivity
        let displayName = app.name
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
        let apps = home.appendingPathComponent("apps.noindex")
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
                "playCoverDisplayName": displayName,
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
            let legacy = home.appendingPathComponent("apps").appendingPathComponent(installName)
            if let features = NSDictionary(contentsOf: legacy.appendingPathComponent("RunnerFeatures.plist")),
               features["playCoverWidth"] != nil {
                _ = try? Shell.run(print: false, "/System/Library/Frameworks/CoreServices.framework/" +
                                   "Frameworks/LaunchServices.framework/Support/lsregister", "-u", legacy.path)
                try fileManager.removeItem(at: legacy)
            }
            try Data().write(to: apps.appendingPathComponent(".metadata_never_index"))
            try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent(bundleIdentifier + "-runtime.log")
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logURL)
            defer { try? output.close() }
            let namedRuntime = try personalizedRuntime(runtime, name: displayName, icon: icon,
                folder: logs.appendingPathComponent(bundleIdentifier + ".noindex"))
            // Game Mode resolves the runtime ID through LaunchServices, which
            // otherwise prefers the generic template nested in /Applications.
            _ = try? Shell.run(print: false, "/System/Library/Frameworks/CoreServices.framework/" +
                               "Frameworks/LaunchServices.framework/Support/lsregister", "-u", runtime.bundleURL.path)
            LSRegisterURL(namedRuntime as CFURL, true)
            let process = Process()
            process.executableURL = namedRuntime
                .appendingPathComponent("Contents/MacOS").appendingPathComponent(executable.lastPathComponent)
            process.arguments = ["--launch-app", installName, "--keychain-slot", String(slot)]
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("MTL_") && !$0.key.hasPrefix("METAL_")
            }
            process.standardOutput = output
            process.standardError = output
            let discord = IsolatedDiscordActivity.connection(enabled: discordSettings.enable)
            process.terminationHandler = { task in
                discord?.cancel()
                if task.terminationStatus != 0 {
                    Log.shared.error("The isolated runtime exited with status \(task.terminationStatus). " +
                                     "See \(logURL.path) and Console's Runtime-Catalyst messages.")
                }
            }
            flock(lock, LOCK_UN)
            try process.run()
            if let discord {
                Task {
                    await IsolatedDiscordActivity.publish(on: discord, process: process, settings: discordSettings,
                                                           name: displayName, bundleID: bundleIdentifier)
                }
            }
            Log.shared.log("Launched \(bundleIdentifier) with isolated runtime + PlayTools " +
                           "(PID \(process.processIdentifier)).")
        }.value
    }

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

    private static func personalizedRuntime(_ runtime: Bundle, name: String, icon: Data?, folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".noindex")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let runtimeName = name.replacingOccurrences(of: "/", with: ":")
        let copy = staging.appendingPathComponent(runtimeName).appendingPathExtension("app")
        try fileManager.copyItem(at: runtime.bundleURL, to: copy)
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
        try Shell.run(print: false, "/usr/bin/codesign", "--force", "--sign", signingIdentity(for: runtime.bundleURL),
                      "--preserve-metadata=identifier,entitlements,requirements,flags,runtime", copy.path)
        try Shell.run(print: false, "/usr/bin/codesign", "--verify", "--deep", "--strict", copy.path)
        if fileManager.fileExists(atPath: folder.path) {
            _ = try fileManager.replaceItemAt(folder, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: folder)
        }
        return folder.appendingPathComponent(copy.lastPathComponent)
    }

    private static func signingIdentity(for runtime: URL) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(runtime as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String]
                as? [SecCertificate],
              let certificate = certificates.first else {
            throw "The isolated runtime needs a development signing identity. Rebuild it with your development team."
        }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
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
