//
//  Uninstaller.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/26/22.
//

import SwiftUI

struct CheckBoxHelper {
    var view: NSView
    var button: NSButton
    var buttonvar: String
}

class Uninstaller {
    private static let libraryUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    private static let pruneURLs: [URL] = [
        PlayTools.playCoverContainer.appendingPathComponent("App Settings"),
        PlayTools.playCoverContainer.appendingPathComponent("Entitlements"),
        PlayTools.playCoverContainer.appendingPathComponent("Keymapping"),
        PlayTools.playCoverContainer.appendingPathComponent("PlayChain")
    ]
    private static let cacheURLs: [URL] = [
        Uninstaller.libraryUrl.appendingPathComponent("Containers"),
        Uninstaller.libraryUrl.appendingPathComponent("Application Scripts"),
        Uninstaller.libraryUrl.appendingPathComponent("Caches"),
        Uninstaller.libraryUrl.appendingPathComponent("HTTPStorages"),
        Uninstaller.libraryUrl.appendingPathComponent("Saved Application State")
    ]

    private static func createButtonView(_ yaxis: CGFloat, _ text: String, _ varname: String) -> CheckBoxHelper {
        let button = NSButton(checkboxWithTitle: text, target: self, action: nil)

        if UninstallPreferences.shared.value(forKey: varname) as? Bool ?? true {
            button.animator().setNextState()
        }

        let view = NSView(frame: NSRect(x: 0, y: yaxis,
                                        width: button.fittingSize.width,
                                        height: button.fittingSize.height))

        view.addSubview(button)

        return CheckBoxHelper(view: view, button: button, buttonvar: varname)
    }

    @MainActor
    static func uninstallPopup(_ app: PlayApp) async {
        if UninstallPreferences.shared.showUninstallPopup {
            let boxmakers: [(String, String)] = [
                ("removePlayChain", NSLocalizedString("preferences.toggle.removePlayChain", comment: "")),
                ("removeAppEntitlements", NSLocalizedString("preferences.toggle.removeEntitlements", comment: "")),
                ("removeAppSettings", NSLocalizedString("preferences.toggle.removeSetting", comment: "")),
                ("removeAppKeymap", NSLocalizedString("preferences.toggle.removeKeymap", comment: "")),
                ("clearAppData", NSLocalizedString("preferences.toggle.clearAppData", comment: ""))
            ]

            var checkboxes: [CheckBoxHelper] = []

            var viewY = 0.0

            for (buttonvar, buttontitle) in boxmakers {
                checkboxes.append(createButtonView(viewY, buttontitle, buttonvar))
                viewY += checkboxes[checkboxes.count - 1].view.frame.height
            }

            let viewWidth = checkboxes.max(by: { $0.view.frame.width < $1.view.frame.width })?.view.frame.width

            let settingsView = NSStackView(frame: NSRect(x: 0, y: 0, width: viewWidth ?? 0, height: viewY))

            for checkboxhelper in checkboxes {
                settingsView.addSubview(checkboxhelper.view)
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("playapp.delete", comment: "")
            alert.informativeText = String(format: NSLocalizedString("playapp.deleteMessage",
                                                                     comment: ""),
                                           arguments: [app.name])

            alert.alertStyle = .warning
            alert.accessoryView = settingsView

            let delete = alert.addButton(withTitle: NSLocalizedString("playapp.deleteConfirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "")

            delete.hasDestructiveAction = true

            NSApplication.shared.requestUserAttention(.criticalRequest)
            guard let window = NSApplication.shared.windows.first,
                  await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            for checkboxhelper in checkboxes {
                UninstallPreferences.shared.setValue(checkboxhelper.button.state == .on,
                                                     forKey: checkboxhelper.buttonvar)
            }

            if alert.suppressionButton?.state == .on {
                UninstallPreferences.shared.showUninstallPopup = false
            }

            await uninstall(app)
        } else {
            await uninstall(app)
        }
    }

    @MainActor
    static func uninstall(_ app: PlayApp) async {
        guard !app.isStarting, app.isolatedProcess?.isRunning != true else {
            Log.shared.error("Quit the game before uninstalling it.")
            return
        }
        let clearData = UninstallPreferences.shared.clearAppData
        do {
            try IsolatedRuntime.removeInstallation(for: app.info.bundleIdentifier, clearData: clearData,
                                                   checkRuntime: app.settings.settings.useIsolatedRuntime)
        } catch {
            Log.shared.error(error)
            return
        }
        var uninstallNum = 0

        if clearData {
            await app.clearAllCache()
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppKeymap {
            FileManager.default.delete(at: app.keymapping.baseKeymapURL)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppSettings {
            FileManager.default.delete(at: app.settings.settingsUrl)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppEntitlements {
            FileManager.default.delete(at: app.entitlements)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removePlayChain {
            let url = KeyCover.playChainPath.appendingPathComponent(app.info.bundleIdentifier)
            FileManager.default.delete(at: url)

            // KeyCover encrypted chain
            let keyCoverURL = url.appendingPathExtension("keyCover")
            FileManager.default.delete(at: keyCoverURL)
            uninstallNum += 1
        }

        app.removeAlias()
        app.deleteApp()

        if uninstallNum >= 5 {
            do {
                let apps = (try PlayApp.bundleIDCache).filter({ $0 != app.info.bundleIdentifier })
                    .joined(separator: "\n") + "\n"
                try apps.write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    @MainActor
    static func clearCachePopup(_ app: PlayApp) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.app.delete", comment: "")
        alert.alertStyle = .warning

        let proceed = alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        proceed.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        NSApplication.shared.requestUserAttention(.criticalRequest)
        guard let window = NSApplication.shared.windows.first,
              await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        await clearCache(of: app)
    }

    @MainActor
    static func clearCache(of app: PlayApp) async {
        guard !IsolatedRuntime.isSwitchingRuntime(for: app.info.bundleIdentifier) else {
            Log.shared.error("Wait for this game's data to finish moving.")
            return
        }
        await app.clearAllCache()
    }

    static func clearExternalCache(_ bundleId: String) {
        do {
            for cache in cacheURLs {
                cache.enumerateContents(options: [.skipsSubdirectoryDescendants]) { file, _ in
                    if file.path.contains(bundleId) {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                    }
                }
            }
        }
    }

    @MainActor
    static func pruneFiles() {
        do {
            let files = FileManager.default
            var installed = Set(AppsVM.shared.apps.map { $0.info.bundleIdentifier.lowercased() })
            // The library model can still be refreshing when Preferences is open.
            for app in try files.contentsOfDirectory(at: AppsVM.appDirectory, includingPropertiesForKeys: nil)
                where app.pathExtension.lowercased() == "app" {
                installed.insert(app.deletingPathExtension().lastPathComponent.lowercased())
                if let id = Bundle(url: app)?.bundleIdentifier { installed.insert(id.lowercased()) }
            }
            let cacheExists = files.fileExists(atPath: PlayApp.bundleIDCacheURL.path)
            let cached = cacheExists ? try PlayApp.bundleIDCache : []
            let danglingItems = Set(cached.filter { !installed.contains($0.lowercased()) })
            try pruneIsolatedInstallations(dangling: danglingItems, installed: installed)

            var fullPruneURLs = pruneURLs
            fullPruneURLs.append(contentsOf: cacheURLs)

            var prunedIds = Set<String>()
            for url in fullPruneURLs {
                guard files.fileExists(atPath: url.path) else { continue }
                for file in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let bundleId = file.deletingPathExtension().lastPathComponent
                    if danglingItems.contains(bundleId) {
                        try files.trashItem(at: file, resultingItemURL: nil)
                        prunedIds.insert(bundleId)
                    }
                }
            }

            if !prunedIds.isEmpty {
                try "\(PlayApp.bundleIDCache.filter { !prunedIds.contains($0) }.joined(separator: "\n"))\n"
                    .write(to: PlayApp.bundleIDCacheURL, atomically: true, encoding: .utf8)
            }
        } catch {
            Log.shared.error(error)
        }
    }

    @MainActor
    private static func pruneIsolatedInstallations(dangling: Set<String>, installed: Set<String>) throws {
        let files = FileManager.default
        var candidates = dangling
        let runtime = PlayTools.playCoverContainer.appendingPathComponent("IsolatedRuntime")
        if files.fileExists(atPath: runtime.path) {
            let suffix = "-runtime.log"
            for entry in try files.contentsOfDirectory(at: runtime, includingPropertiesForKeys: [.isRegularFileKey])
                where entry.lastPathComponent.hasSuffix(suffix) {
                let id = String(entry.lastPathComponent.dropLast(suffix.count))
                if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                   !installed.contains(id.lowercased()) {
                    candidates.insert(id)
                }
            }
        }
        for id in candidates {
            try IsolatedRuntime.removeInstallation(for: id, clearData: true)
        }
    }
}
