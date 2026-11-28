import CryptoKit
import Darwin
import Foundation
import Security

/// All personalized runtimes share the signed template's provisioning identity.
enum RuntimeProvisioning {
    private struct Profile {
        let data: Data
        let expiry: Date
        let team: String
        let applicationID: String
        let certificates: [Data]
        let platforms: [String]

        init(_ url: URL) throws {
            data = try Data(contentsOf: url)
            var decoder: CMSDecoder?
            var content: CFData?
            guard !data.isEmpty, CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
                  CMSDecoderUpdateMessage(decoder, CFDataGetBytePtr(data as CFData), data.count) == errSecSuccess,
                  CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
                  CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
                  let fields = try PropertyListSerialization.propertyList(
                    from: content as Data, format: nil) as? [String: Any],
                  let date = fields["ExpirationDate"] as? Date,
                  let entitlements = fields["Entitlements"] as? [String: Any],
                  let teamID = entitlements["com.apple.developer.team-identifier"] as? String,
                  let identifier = entitlements["com.apple.application-identifier"] as? String,
                  let certs = fields["DeveloperCertificates"] as? [Data],
                  let platformList = fields["Platform"] as? [String] else {
                throw "Could not read the isolated runtime provisioning profile."
            }
            expiry = date
            team = teamID
            applicationID = identifier
            certificates = certs
            platforms = platformList
        }
    }

    static func profile(for runtime: URL, cacheDirectory: URL, helper: URL, now: Date = Date()) throws -> Data {
        let embedded = try Profile(runtime.appendingPathComponent("Contents/embedded.provisionprofile"))
        if embedded.expiry > now { return embedded.data }

        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(runtime as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let identifier = signing[kSecCodeInfoIdentifier as String] as? String,
              let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            throw "Could not read the isolated runtime signing identity."
        }
        let certificate = SecCertificateCopyData(leaf) as Data
        func matches(_ profile: Profile) -> Bool {
            profile.expiry > now && profile.team == embedded.team && profile.applicationID == embedded.applicationID
                && profile.platforms.contains("OSX") && profile.certificates.contains(certificate)
        }

        let files = FileManager.default
        try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let lock = open(cacheDirectory.appendingPathComponent("renew.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw "Could not open the runtime provisioning lock." }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw "Could not lock runtime provisioning." }

        let cache = cacheDirectory.appendingPathComponent("embedded.provisionprofile")
        if let cached = try? Profile(cache), matches(cached) { return cached.data }
        let scratch = cacheDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: scratch) }
        do {
            try Shell.run(print: false, "/bin/bash", helper.path, embedded.team, identifier, scratch.path)
            let renewed = try Profile(scratch.appendingPathComponent("embedded.provisionprofile"))
            guard matches(renewed) else { throw "Xcode returned an expired or incompatible provisioning profile." }
            try renewed.data.write(to: cache, options: .atomic)
            return renewed.data
        } catch {
            throw "The isolated runtime profile expired and renewal failed. Check your internet connection " +
                  "and signing account in Xcode Settings, then launch again.\n\(error)"
        }
    }

    static func signingIdentity(for runtime: URL) throws -> String {
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

    static func hasRuntimeSupport(in resources: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: resources.appendingPathComponent("Runtime-Catalyst.app").path)
            || files.fileExists(atPath: resources.appendingPathComponent("IsolatedRuntimeSource").path)
    }

    static func resolveRuntimeBundle(resources: URL, artifactsDirectory: URL, buildIfMissing: Bool) throws -> Bundle? {
        let embedded = resources.appendingPathComponent("Runtime-Catalyst.app")
        if FileManager.default.fileExists(atPath: embedded.path) {
            return Bundle(url: embedded)
        }
        let source = resources.appendingPathComponent("IsolatedRuntimeSource")
        if buildIfMissing && FileManager.default.fileExists(atPath: source.path) {
            return try ensureLocalRuntime(source: source, artifactsDirectory: artifactsDirectory)
        }
        return cachedLocalRuntime(in: artifactsDirectory)
    }

    static func knownRuntimeID(resources: URL?, artifactsDirectory: URL) -> String? {
        if let resources,
           let id = (try? resolveRuntimeBundle(
            resources: resources, artifactsDirectory: artifactsDirectory, buildIfMissing: false
           ))?.bundleIdentifier {
            return id
        }
        guard let team = try? detectDevelopmentTeam() else { return nil }
        return "\(team).dev.ohaiibuzzle.BaseiOSApp.RuntimeCatalyst"
    }

    static func cachedLocalRuntime(in artifactsDirectory: URL) -> Bundle? {
        let template = artifactsDirectory.appendingPathComponent("Template.noindex/Runtime-Catalyst.app")
        guard FileManager.default.fileExists(atPath: template.path) else { return nil }
        return Bundle(url: template)
    }

    static func ensureLocalRuntime(source: URL, artifactsDirectory: URL) throws -> Bundle {
        let files = FileManager.default
        let templateDir = artifactsDirectory.appendingPathComponent("Template.noindex")
        let template = templateDir.appendingPathComponent("Runtime-Catalyst.app")
        let stampURL = templateDir.appendingPathComponent(".source-sha256")
        let expectedStamp = try sourceFingerprint(at: source)
        if isReusableTemplate(template, stampURL: stampURL, expectedStamp: expectedStamp),
           let bundle = Bundle(url: template) {
            return bundle
        }

        try files.createDirectory(at: templateDir, withIntermediateDirectories: true)
        let lockPath = templateDir.appendingPathComponent("build.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw "Could not open the local runtime build lock." }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw "Could not lock local runtime build." }

        if isReusableTemplate(template, stampURL: stampURL, expectedStamp: expectedStamp),
           let bundle = Bundle(url: template) {
            return bundle
        }

        let team = try detectDevelopmentTeam()
        let builder = source.appendingPathComponent("build-local.sh")
        guard files.fileExists(atPath: builder.path) else {
            throw "The isolated runtime build helper is missing from this PlayCover build."
        }
        let scratch = templateDir.appendingPathComponent(UUID().uuidString + ".noindex")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        do {
            try Shell.run(print: false, "/bin/bash", builder.path, source.path, team, template.path, scratch.path)
            try expectedStamp.write(to: stampURL, atomically: true, encoding: .utf8)
        } catch {
            throw "Could not build the isolated runtime locally with Xcode (team \(team)). " +
                  "Ensure Xcode is installed and signed in under Xcode → Settings → Accounts.\n\(error)"
        }
        guard let bundle = Bundle(url: template) else {
            throw "Built isolated runtime bundle could not be loaded."
        }
        return bundle
    }

    private static func isReusableTemplate(_ template: URL, stampURL: URL, expectedStamp: String) -> Bool {
        guard FileManager.default.fileExists(atPath: template.path),
              let saved = try? String(contentsOf: stampURL, encoding: .utf8),
              saved == expectedStamp else {
            return false
        }
        return (try? Shell.run(print: false, "/usr/bin/codesign", "--verify", "--deep", "--strict", template.path))
            != nil
    }

    private static func sourceFingerprint(at root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            throw "Could not read bundled isolated runtime sources."
        }
        var paths: [String] = []
        let prefix = root.path + "/"
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = file.path.hasPrefix(prefix)
                ? String(file.path.dropFirst(prefix.count))
                : file.lastPathComponent
            paths.append(relative)
        }
        var hasher = SHA256()
        for rel in paths.sorted() {
            hasher.update(data: Data(rel.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: root.appendingPathComponent(rel)))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension RuntimeProvisioning {
    static func detectDevelopmentTeam() throws -> String {
        if let override = UserDefaults.standard.string(forKey: "IsolatedRuntimeDevelopmentTeam"),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let validHashes = try validAppleDevelopmentHashes()
        let teams = teamsForCertificateHashes(validHashes)
        guard !teams.isEmpty else {
            throw "To use the isolated runtime, install Xcode and sign in with an Apple Account in " +
                  "Xcode → Settings → Accounts (an Apple Development certificate is required)."
        }
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        if let existing = teams.first(where: { team in
            let id = "\(team).dev.ohaiibuzzle.BaseiOSApp.RuntimeCatalyst"
            return FileManager.default.fileExists(atPath: containers.appendingPathComponent(id).path)
        }) {
            return existing
        }
        return teams[0]
    }

    private static func validAppleDevelopmentHashes() throws -> [String] {
        let output = try Shell.run(print: false, "/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
        var hashes: [String] = []
        for line in output.split(separator: "\n") where line.contains("\"Apple Development:") {
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            if let hash = tokens.first(where: { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) {
                hashes.append(String(hash).uppercased())
            }
        }
        return hashes
    }

    private static func teamsForCertificateHashes(_ hashes: [String]) -> [String] {
        guard !hashes.isEmpty else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let certs = result as? [SecCertificate] else {
            return []
        }
        var byHash: [String: String] = [:]
        for cert in certs {
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data)
                .map { String(format: "%02X", $0) }.joined()
            if hashes.contains(digest), let team = organizationalUnit(of: cert) {
                byHash[digest] = team
            }
        }
        var ordered: [String] = []
        for hash in hashes {
            if let team = byHash[hash], !ordered.contains(team) { ordered.append(team) }
        }
        return ordered
    }

    private static func organizationalUnit(of certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let items = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return nil
        }
        for item in items where item[kSecPropertyKeyLabel as String] as? String
            == (kSecOIDOrganizationalUnitName as String) {
            if let value = item[kSecPropertyKeyValue as String] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
