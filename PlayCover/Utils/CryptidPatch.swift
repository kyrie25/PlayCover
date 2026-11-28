//
//  CryptidPatch.swift
//  PlayCover
//

import Foundation
import injection

enum CryptidPatch {
    private static let dylibName = "CryptidPatch.dylib"
    private static let loadPath = "@executable_path/Frameworks/CryptidPatch.dylib"

    static func sync(for app: PlayApp) throws {
        let enabled = app.settings.settings.cryptidPatch
        let injected = try isInjected(in: app.executable)
        let frameworksDir = app.url.appendingPathComponent("Frameworks")
        let target = frameworksDir.appendingPathComponent(dylibName)
        let files = FileManager.default
        var changed = false

        if enabled {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent(dylibName),
                  files.fileExists(atPath: source.path) else {
                throw "CryptidPatch.dylib is missing from this PlayCover build."
            }
            if !files.fileExists(atPath: target.path) || target.sha256 != source.sha256 {
                try files.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: source, to: target)
                _ = try? Shell.run(print: false, "/usr/bin/xattr", "-d", "com.apple.quarantine", target.path)
                try Shell.signMacho(target)
                changed = true
            }
            if !injected {
                var succeeded = false
                Inject.injectMachO(machoPath: app.executable.path, cmdType: .loadDylib,
                                   backup: false, injectPath: loadPath) { succeeded = $0 }
                guard succeeded else { throw "Could not inject \(dylibName) into \(app.name)." }
                changed = true
            }
        } else {
            if injected {
                var succeeded = false
                Inject.removeMachO(machoPath: app.executable.path, cmdType: .loadDylib,
                                   backup: false, injectPath: loadPath) { succeeded = $0 }
                guard succeeded else { throw "Could not remove \(dylibName) from \(app.name)." }
                changed = true
            }
            if files.fileExists(atPath: target.path) {
                try files.removeItem(at: target)
                changed = true
            }
        }

        if changed {
            app.sign()
        }
    }

    static func isInjected(in executable: URL) throws -> Bool {
        var binary = try Data(contentsOf: executable)
        try Macho.stripBinary(&binary)
        var found = false
        _ = try Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let command = binary.extract(load_command.self, offset: offset,
                                         swap: shouldSwap ? swap_load_command : nil)
            guard command.cmd == UInt32(LC_LOAD_DYLIB) else { return false }
            let dylib = binary.extract(dylib_command.self, offset: offset,
                                       swap: shouldSwap ? swap_dylib_command : nil)
            let name = String(data: binary, offset: offset,
                              commandSize: Int(dylib.cmdsize), loadCommandString: dylib.dylib.name)
            if name == loadPath {
                found = true
                return true
            }
            return false
        }
        return found
    }
}
