import Foundation
import Network

@MainActor
@Observable
final class IPtalkManager {
    var isConnected: Bool = false
    private var receivedTextSegments: [String] = []
    var receivedText: String {
        receivedTextSegments.joined()
    }
    var errorMessage: String?
    var connectedPartners: [String] = []
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    
    private(set) var port: UInt16
    private let encoding: String.Encoding = .shiftJIS
    
    init(port: UInt16 = 15000) {
        self.port = port
    }
    
    func updatePort(_ port: UInt16) {
        self.port = port
    }
    
    func startListening() async {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                errorMessage = "ポート番号が不正です"
                return
            }
            
            listener = try NWListener(using: parameters, on: nwPort)
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isConnected = true
                        self?.errorMessage = nil
                    case .failed(let error):
                        self?.errorMessage = "接続エラー: \(error.localizedDescription)"
                        self?.isConnected = false
                    case .cancelled:
                        self?.isConnected = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor in
                    self?.handleNewConnection(newConnection)
                }
            }
            
            listener?.start(queue: .main)
            
        } catch {
            errorMessage = "リスナー開始エラー: \(error.localizedDescription)"
        }
    }
    
    func stopListening() {
        listener?.cancel()
        listener = nil
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        isConnected = false
        connectedPartners.removeAll()
    }
    
    func sendText(_ text: String) {
        guard isConnected else { return }
        
        let packet = createIPtalkPacket(text: text)
        sendBroadcast(data: packet)
    }
    
    private func handleNewConnection(_ newConnection: NWConnection) {
        activeConnections.append(newConnection)
        
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    if let endpoint = newConnection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = endpoint {
                        let hostString = "\(host)"
                        if !(self?.connectedPartners.contains(hostString) ?? false) {
                            self?.connectedPartners.append(hostString)
                        }
                    }
                case .failed, .cancelled:
                    if let endpoint = newConnection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = endpoint {
                        self?.connectedPartners.removeAll { $0 == "\(host)" }
                    }
                    self?.activeConnections.removeAll { $0 === newConnection }
                    if case .failed(let error) = state {
                        self?.errorMessage = "接続エラー: \(error.localizedDescription)"
                    }
                default:
                    break
                }
            }
        }
        
        receiveData(from: newConnection)
        newConnection.start(queue: .main)
    }
    
    private func receiveData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor in
                if let data = content {
                    self?.processReceivedData(data)
                }
                
                if let error {
                    if case .posix(let code) = error, code == .ECANCELED {
                        self?.activeConnections.removeAll { $0 === connection }
                        return
                    }
                    self?.errorMessage = "受信エラー: \(error.localizedDescription)"
                    return
                }
                
                self?.receiveData(from: connection)
            }
        }
    }
    
    private func processReceivedData(_ data: Data) {
        guard let packet = parseIPtalkPacket(data: data) else { return }
        
        if !packet.text.isEmpty {
            receivedTextSegments.append(packet.text)
            if !packet.text.hasSuffix("\n") {
                receivedTextSegments.append("\n")
            }
        }
    }
    
    private func sendBroadcast(data: Data) {
        let broadcastHost = NWEndpoint.Host("255.255.255.255")
        guard let broadcastPort = NWEndpoint.Port(rawValue: port) else {
            errorMessage = "ポート番号が不正です"
            return
        }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        let connection = NWConnection(host: broadcastHost, port: broadcastPort, using: parameters)
        
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        
        connection.start(queue: .main)
    }
    
    // IPtalk packet format (simplified)
    // Header: 4 bytes command + 4 bytes length
    // Body: Shift-JIS encoded text
    
    func createIPtalkPacket(text: String) -> Data {
        var packet = Data()
        
        // Command: "TEXT" (simplified)
        let command: [UInt8] = [0x54, 0x45, 0x58, 0x54] // "TEXT"
        packet.append(contentsOf: command)
        
        // Text data in Shift-JIS
        if let textData = text.data(using: encoding) {
            // Length (4 bytes, little-endian)
            var length = UInt32(textData.count).littleEndian
            packet.append(Data(bytes: &length, count: 4))
            
            // Text content
            packet.append(textData)
        } else {
            // Empty length
            var length: UInt32 = 0
            packet.append(Data(bytes: &length, count: 4))
        }
        
        return packet
    }
    
    func parseIPtalkPacket(data: Data) -> IPtalkPacket? {
        guard data.count >= 8 else { return nil }
        
        // Read command (first 4 bytes)
        let commandData = data.prefix(4)
        let command = String(data: commandData, encoding: .ascii) ?? ""
        
        // Read length (next 4 bytes)
        let lengthData = data.subdata(in: 4..<8)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        
        guard data.count >= 8 + Int(length) else { return nil }
        
        // Read text
        let textData = data.subdata(in: 8..<(8 + Int(length)))
        let text = String(data: textData, encoding: encoding) ?? ""
        
        return IPtalkPacket(command: command, text: text)
    }
    
    func clearReceivedText() {
        receivedTextSegments.removeAll()
    }
}

struct IPtalkPacket {
    let command: String
    let text: String
}
