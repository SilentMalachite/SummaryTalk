import Foundation

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
