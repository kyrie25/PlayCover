import Foundation
import Network
import os

enum IsolatedDiscordActivity {
    private static let logger = Logger(subsystem: "io.playcover.PlayCover", category: "DiscordActivity")

    static func connection(enabled: Bool) -> NWConnection? {
        guard enabled else { return nil }
        let directory = FileManager.default.temporaryDirectory
        let socket = (0..<10).lazy.map { directory.appendingPathComponent("discord-ipc-\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return socket.map { NWConnection(to: .unix(path: $0.path), using: .tcp) }
    }

    static func publish(on connection: NWConnection, process: Process, settings: DiscordActivity,
                        name: String, bundleID: String) async {
        let logo = "https://raw.githubusercontent.com/PlayCover/PlaySite/master/src/assets/square-logo.png"
        let image: String?
        if settings.image.isEmpty {
            let lookup = "https://itunes.apple.com/lookup?bundleId=\(bundleID)"
            image = await getITunesData(lookup)?.results.first?.artworkUrl512
        } else {
            image = settings.image
        }

        guard process.isRunning else { return }
        let applicationID = settings.applicationID.isEmpty ? "996108521680678993" : settings.applicationID
        let poweredBy = "Powered by PlayCover"
        let activity: [String: Any] = [
            "details": activityText(settings.details, fallback: "Playing \(name)"),
            "state": activityText(settings.state, fallback: poweredBy),
            "timestamps": ["start": Int(Date().timeIntervalSince1970 * 1000)],
            "assets": image.map { ["large_image": $0, "small_image": logo] } ?? ["large_image": logo],
            "buttons": [["label": "Download PlayCover", "url": "https://github.com/PlayCover/PlayCover/releases"]]
        ]
        let nonce = UUID().uuidString
        guard let handshake = try? JSONSerialization.data(withJSONObject: ["v": 1, "client_id": applicationID]),
              let request = try? JSONSerialization.data(withJSONObject: [
                "cmd": "SET_ACTIVITY", "nonce": nonce, "args": ["pid": process.processIdentifier, "activity": activity]
              ]) else { return }

        connection.start(queue: .global(qos: .utility))
        send(handshake, opcode: 0, on: connection)
        receive(on: connection, activity: request, nonce: nonce)
    }

    private static func activityText(_ text: String, fallback: String) -> String {
        if text.isEmpty { return fallback }
        return text.count == 1 ? text + " " : text
    }

    // Discord IPC frames begin with a little-endian opcode and payload length.
    private static func send(_ payload: Data, opcode: UInt32, on connection: NWConnection) {
        var header = [opcode.littleEndian, UInt32(payload.count).littleEndian]
        let frame = header.withUnsafeMutableBytes { Data($0) } + payload
        connection.send(content: frame, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private static func receive(on connection: NWConnection, activity: Data, nonce: String) {
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { header, _, _, _ in
            guard let header, header.count == 8 else {
                connection.cancel()
                return
            }
            let opcode = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            let length = header.withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            }
            guard opcode != 2, (1...65536).contains(length) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                guard let body, body.count == length else {
                    connection.cancel()
                    return
                }
                if opcode == 3 {
                    send(body, opcode: 4, on: connection)
                } else if opcode == 1,
                          let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                    if reply["evt"] as? String == "READY" {
                        send(activity, opcode: 1, on: connection)
                    } else if reply["nonce"] as? String == nonce, reply["evt"] as? String != "ERROR" {
                        logger.info("Discord accepted isolated game activity.")
                    }
                }
                receive(on: connection, activity: activity, nonce: nonce)
            }
        }
    }
}
