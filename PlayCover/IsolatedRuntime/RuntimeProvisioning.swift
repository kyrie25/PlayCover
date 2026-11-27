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
}
