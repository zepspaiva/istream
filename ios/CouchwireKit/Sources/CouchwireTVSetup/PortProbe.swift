import Foundation
import Network

/// Whether something answers on a TCP port: how the setup tells, from outside, what the TV has turned on.
/// LG TVs answer on 3000 (their remote API); in Developer Mode on 9922 (SSH), and on 9991 while Key Server is on.
/// Plain unicast TCP: no multicast entitlement needed, only the Local Network permission.
public enum PortProbe {
    public static func isOpen(_ host: String, _ port: UInt16, timeout: Double = 1.5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { continuation in
            func finish(_ open: Bool) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)   // refused or unreachable
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}
