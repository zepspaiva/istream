import Foundation
import Network

/// Wake-on-LAN: the "magic packet" (6 × 0xFF, then the MAC 16 times) over UDP to the TV's address, ports 9 and 7.
/// Sent to the address itself, it reaches a TV the network still knows (an asleep LG with "Turn on via Wi-Fi"); the
/// broadcast that always reaches it needs Apple's multicast permission (requested for the App Store version).
enum WakeOnLAN {
    static func send(macs: [String], to host: String) {
        for mac in macs {
            let hex = mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            guard hex.count == 12 else { continue }
            var address: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                if let byte = UInt8(hex[index..<next], radix: 16) { address.append(byte) }
                index = next
            }
            guard address.count == 6 else { continue }
            let packet = Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in address })
            for port: UInt16 in [9, 7] {
                guard let endpointPort = NWEndpoint.Port(rawValue: port) else { continue }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
                connection.start(queue: .global(qos: .userInitiated))
                connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
