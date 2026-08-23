import Foundation
import Network

enum IPtalkPortRole: CaseIterable {
    case display
    case monitor
    case correction
    case memberReply
    case memberBroadcast
    case undo
}

/// One IPv4-capable interface as reported by the system, reduced to what broadcast
/// derivation needs. Kept as plain strings so the selection policy stays pure.
struct IPtalkInterface: Hashable {
    let name: String
    let ipv4: String
    let netmask: String
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

    static func memberDiscoveryRequest(handleName: String) -> Data {
        encode(line: handleName)
    }

    static func memberDiscoveryReply(handleName: String) -> Data {
        encode(line: handleName)
    }

    // MARK: - Sender identity

    /// The member list is keyed by this string, so the same machine has to produce the
    /// same one however it reached us. A dual-stack peer arrives as an IPv4-mapped IPv6
    /// address (`::ffff:192.168.1.5`, or the same bytes spelled `::ffff:c0a8:105`), which
    /// would otherwise register a second entry alongside its plain IPv4 one.
    static func canonicalHost(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return canonicalHostString(address.debugDescription)
        case .ipv6(let address):
            if let mapped = address.asIPv4 {
                return canonicalHostString(mapped.debugDescription)
            }
            return canonicalHostString(address.debugDescription)
        case .name(let name, _):
            return canonicalHostString(name)
        @unknown default:
            return "unknown"
        }
    }

    /// The textual half of the same job: drops the interface zone (`fe80::1%en0`) so a
    /// link-local peer does not split by arrival interface, and folds the dotted-quad
    /// spelling of a mapped address that never went through `IPv6Address`.
    static func canonicalHostString(_ raw: String) -> String {
        var value = raw
        if let zone = value.firstIndex(of: "%") {
            value = String(value[value.startIndex..<zone])
        }
        let mappedPrefix = "::ffff:"
        if value.lowercased().hasPrefix(mappedPrefix) {
            let tail = String(value.dropFirst(mappedPrefix.count))
            if ipv4Octets(tail) != nil { return tail }
        }
        return value
    }

    // MARK: - Broadcast destination

    /// Reaches every host the router will forward to, but some segments drop it.
    static let globalBroadcast = "255.255.255.255"

    /// `ip | ~netmask`. Returns nil for anything that is not a dotted-quad pair, and for
    /// a /32, whose "broadcast" is the host itself — the caller must fall back instead.
    static func broadcastAddress(ip: String, netmask: String) -> String? {
        guard let address = ipv4Octets(ip), let mask = ipv4Octets(netmask) else { return nil }
        guard mask != [255, 255, 255, 255] else { return nil }
        return zip(address, mask).map { String($0 | ~$1) }.joined(separator: ".")
    }

    /// Picks the interface the venue LAN is most likely on: physical and Wi-Fi links
    /// (`en*`) before tunnels and bridges, skipping loopback and self-assigned
    /// addresses. Falls back to the global address when nothing usable is up.
    static func preferredBroadcast(interfaces: [IPtalkInterface]) -> String {
        let usable = interfaces.compactMap { interface -> (name: String, broadcast: String)? in
            guard !interface.ipv4.hasPrefix("127."),
                  !interface.ipv4.hasPrefix("169.254."),
                  let broadcast = broadcastAddress(ip: interface.ipv4, netmask: interface.netmask)
            else { return nil }
            return (interface.name, broadcast)
        }
        if let ethernet = usable.first(where: { $0.name.hasPrefix("en") }) {
            return ethernet.broadcast
        }
        return usable.first?.broadcast ?? globalBroadcast
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            octets.append(octet)
        }
        return octets
    }
}
