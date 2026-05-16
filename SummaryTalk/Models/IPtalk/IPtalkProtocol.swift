import Foundation

enum IPtalkPortRole: CaseIterable {
    case display
    case monitor
    case correction
    case memberReply
    case memberBroadcast
    case undo
}

enum IPtalkProtocol {
    static func port(role: IPtalkPortRole, channel: Int) -> UInt16 {
        let base: UInt16
        switch role {
        case .display:          base = 6711
        case .monitor:          base = 6712
        case .correction:       base = 6713
        case .memberReply:      base = 6718
        case .memberBroadcast:  base = 6722
        case .undo:             base = 6723
        }
        let clamped = max(1, min(9, channel))
        return base + UInt16(clamped - 1) * 100
    }

    static let encoding: String.Encoding = .shiftJIS

    static func encode(line: String) -> Data {
        let terminated = line.hasSuffix("\n") ? line : line + "\n"
        return terminated.data(using: encoding, allowLossyConversion: true) ?? Data()
    }

    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: encoding)
    }
}
