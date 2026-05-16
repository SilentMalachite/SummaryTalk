import Foundation
import Network

struct IPtalkMember: Identifiable, Hashable {
    let id: String   // IP string; serves as identity
    let name: String
    let ip: String
}

enum IPtalkLineKind: Hashable {
    case display
    case monitor
    case correction
    case undo
}

struct IPtalkReceivedLine: Identifiable, Hashable {
    let id: UUID
    let kind: IPtalkLineKind
    let sender: String
    let text: String
    let receivedAt: Date
}

@MainActor
@Observable
final class IPtalkManager {
    var isConnected: Bool = false
    var port: UInt16 = 15000
    var connectedPartners: [String] = []
    var errorMessage: String? = nil
    var receivedText: String = ""

    init() {}

    func startListening() async {}
    func stopListening() {}
    func updatePort(_ newPort: UInt16) { port = newPort }
    func sendText(_ text: String) {}
    func clearReceivedText() { receivedText = "" }
}
