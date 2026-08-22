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
    // Configuration (View layer is responsible for persistence)
    var channel: Int = 1
    var handleName: String = ""

    // Observable state
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var members: [IPtalkMember] = []
    private(set) var receivedLines: [IPtalkReceivedLine] = []
    var errorMessage: String?

    // Backward-compatible view for IPtalkPanel — concatenates display lines only.
    var receivedText: String {
        receivedLines.filter { $0.kind == .display }.map(\.text).joined()
    }

    private var listeners: [IPtalkPortRole: NWListener] = [:]
    private struct InboundConnection {
        let connection: NWConnection
        var lastActivity: Date
    }

    /// Strong owners for every live `NWConnection`. Network.framework does not retain
    /// connections on our behalf — an untracked one can deallocate (and force-cancel)
    /// before it ever reaches `.ready`, silently dropping the datagram.
    private var inboundConnections: [ObjectIdentifier: InboundConnection] = [:]
    private var outboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private static let maxReceivedLines = 2000
    /// A UDP flow never reports its own end, and a peer that sends every datagram from
    /// a fresh source port — which this app does — mints one listener connection per
    /// line. Keeping the receive armed therefore has to come with reaping.
    static let maxInboundConnections = 64
    static let inboundIdleTimeout: TimeInterval = 60
    private let networkQueue = DispatchQueue(label: "com.summarytalk.iptalk", qos: .userInitiated)
    private var pendingReadyRoles: Set<IPtalkPortRole> = []
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var startupGeneration: UInt64 = 0
    private var startupTimeoutTask: Task<Void, Never>?
    var startupTimeoutNanoseconds: UInt64 = 5_000_000_000

    init() {}

    // MARK: - Lifecycle

    func startListening() async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        errorMessage = nil
        startupGeneration += 1
        let generation = startupGeneration

        var opened: [IPtalkPortRole: NWListener] = [:]
        for role in IPtalkPortRole.allCases {
            let portNum = IPtalkProtocol.port(role: role, channel: channel)
            guard let nwPort = NWEndpoint.Port(rawValue: portNum) else { continue }
            do {
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: nwPort)
                listener.newConnectionHandler = { [weak self] conn in
                    Task { @MainActor in self?.handleIncoming(conn, role: role) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        self?.handleListenerState(state, role: role, portNum: portNum, generation: generation)
                    }
                }
                opened[role] = listener
            } catch {
                opened.values.forEach { $0.cancel() }
                errorMessage = "ポート \(portNum) が使用中です。別のチャンネルを試してください。"
                return
            }
        }
        listeners = opened

        do {
            try await waitUntilListenersReady(roles: Set(opened.keys), generation: generation)
        } catch {
            tearDown()
            if errorMessage == nil {
                errorMessage = "接続に失敗しました: \(error.localizedDescription)"
            }
            return
        }

        isConnected = true
        await refreshMembers()
    }

    func stopListening() {
        tearDown()
    }

    private func waitUntilListenersReady(roles: Set<IPtalkPortRole>, generation: UInt64) async throws {
        startupTimeoutTask?.cancel()

        try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
            pendingReadyRoles = roles
            listeners.values.forEach { $0.start(queue: networkQueue) }
            finishStartupIfPossible()

            startupTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: startupTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                applyStartupTimeout(generation: generation)
            }
        }
    }

    func applyStartupTimeout(generation: UInt64) {
        guard generation == startupGeneration else { return }
        guard let pending = startupContinuation else { return }
        startupContinuation = nil
        errorMessage = "接続がタイムアウトしました"
        pending.resume(throwing: NSError(
            domain: "IPtalkManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "接続がタイムアウトしました"]
        ))
    }

    private func handleListenerState(
        _ state: NWListener.State,
        role: IPtalkPortRole,
        portNum: UInt16,
        generation: UInt64
    ) {
        guard generation == startupGeneration else { return }
        switch state {
        case .ready:
            pendingReadyRoles.remove(role)
            finishStartupIfPossible()
        case .failed(let err):
            errorMessage = "ポート \(portNum) リスナエラー: \(err.localizedDescription)"
            if let pending = startupContinuation {
                startupContinuation = nil
                pending.resume(throwing: err)
            } else if isConnected {
                tearDown()
            }
        default:
            break
        }
    }

    private func finishStartupIfPossible() {
        guard pendingReadyRoles.isEmpty, let pending = startupContinuation else { return }
        startupContinuation = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        pending.resume()
    }

    private func tearDown() {
        startupGeneration += 1
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        if let pending = startupContinuation {
            startupContinuation = nil
            pending.resume(throwing: CancellationError())
        }
        listeners.values.forEach { $0.cancel() }
        listeners.removeAll()
        inboundConnections.values.forEach { $0.connection.cancel() }
        inboundConnections.removeAll()
        outboundConnections.values.forEach { $0.cancel() }
        outboundConnections.removeAll()
        pendingReadyRoles.removeAll()
        isConnected = false
        members.removeAll()
    }

    // MARK: - Receive

    private func handleIncoming(_ connection: NWConnection, role: IPtalkPortRole) {
        // A listener can hand us a connection after tearDown has already run; tracking
        // it then would keep it alive with nothing left to cancel it.
        guard !listeners.isEmpty else {
            connection.cancel()
            return
        }
        trackInbound(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in self?.receive(on: connection, role: role) }
            case .failed, .cancelled:
                Task { @MainActor in self?.releaseInbound(connection) }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    /// Re-arms after every datagram. Cancelling the flow after a single message
    /// loses the lines that arrive while the listener is minting a replacement
    /// connection for the same peer — IPtalk sends a steady stream of them.
    private func receive(on connection: NWConnection, role: IPtalkPortRole) {
        guard inboundConnections[ObjectIdentifier(connection)] != nil else { return }
        connection.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let content, !content.isEmpty {
                    self.touchInbound(connection)
                    self.process(data: content, role: role, sender: self.endpointHost(connection))
                }
                if error != nil {
                    self.releaseInbound(connection)
                } else {
                    self.receive(on: connection, role: role)
                }
            }
        }
    }

    /// Test seam: how many listener-side flows are currently retained.
    var trackedInboundConnectionCount: Int { inboundConnections.count }

    private func trackInbound(_ connection: NWConnection) {
        reapInboundConnections()
        inboundConnections[ObjectIdentifier(connection)] = InboundConnection(
            connection: connection, lastActivity: Date()
        )
    }

    private func touchInbound(_ connection: NWConnection) {
        inboundConnections[ObjectIdentifier(connection)]?.lastActivity = Date()
    }

    private func releaseInbound(_ connection: NWConnection) {
        inboundConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    /// Driven by new arrivals rather than a timer: no traffic means no growth, so
    /// there is nothing to sweep when nothing is happening.
    private func reapInboundConnections() {
        let evicted = Self.inboundEvictionKeys(
            lastActivity: inboundConnections.mapValues(\.lastActivity),
            now: Date(),
            idleTimeout: Self.inboundIdleTimeout,
            limit: Self.maxInboundConnections
        )
        for key in evicted {
            guard let tracked = inboundConnections.removeValue(forKey: key) else { continue }
            tracked.connection.cancel()
        }
    }

    /// Which flows to drop before admitting one more: everything idle past the
    /// timeout, then the least recently used until there is room under `limit`.
    /// Pure so the policy is testable without sockets.
    static func inboundEvictionKeys<Key: Hashable>(
        lastActivity: [Key: Date],
        now: Date,
        idleTimeout: TimeInterval,
        limit: Int
    ) -> Set<Key> {
        let cutoff = now.addingTimeInterval(-idleTimeout)
        var evicted = Set(lastActivity.filter { $0.value < cutoff }.keys)
        let remaining = lastActivity.filter { !evicted.contains($0.key) }
        guard remaining.count >= limit else { return evicted }
        let excess = remaining.count - limit + 1
        evicted.formUnion(remaining.sorted { $0.value < $1.value }.prefix(excess).map(\.key))
        return evicted
    }

    private func trackOutbound(_ connection: NWConnection) {
        outboundConnections[ObjectIdentifier(connection)] = connection
    }

    private func releaseOutbound(_ connection: NWConnection) {
        outboundConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func endpointHost(_ connection: NWConnection) -> String {
        if let endpoint = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return "unknown"
    }

    private func process(data: Data, role: IPtalkPortRole, sender: String) {
        guard let text = IPtalkProtocol.decode(data) else { return }
        switch role {
        case .display:
            appendLine(.display, sender: sender, text: text)
            addOrUpdateMember(ip: sender, name: nil)
        case .monitor:
            appendLine(.monitor, sender: sender, text: text)
        case .correction:
            appendLine(.correction, sender: sender, text: text)
        case .undo:
            appendLine(.undo, sender: sender, text: text)
        case .memberBroadcast:
            // A peer is asking "who's here?" — reply on memberReply (unicast).
            let replyPort = IPtalkProtocol.port(role: .memberReply, channel: channel)
            sendUnicast(IPtalkProtocol.memberDiscoveryReply(handleName: handleName), to: sender, port: replyPort)
            addOrUpdateMember(ip: sender, name: text.trimmingCharacters(in: .newlines))
        case .memberReply:
            addOrUpdateMember(ip: sender, name: text.trimmingCharacters(in: .newlines))
        }
    }

    private func appendLine(_ kind: IPtalkLineKind, sender: String, text: String) {
        receivedLines.append(IPtalkReceivedLine(id: UUID(), kind: kind, sender: sender, text: text, receivedAt: Date()))
        if receivedLines.count > Self.maxReceivedLines {
            receivedLines.removeFirst(receivedLines.count - Self.maxReceivedLines)
        }
    }

    /// Adds a member if new. If `name` is non-nil and non-empty, updates the display
    /// name (so a later member-discovery reply can replace the IP fallback assigned
    /// when we first saw the peer via a display packet).
    private func addOrUpdateMember(ip: String, name: String?) {
        if let idx = members.firstIndex(where: { $0.id == ip }) {
            if let name, !name.isEmpty {
                members[idx] = IPtalkMember(id: ip, name: name, ip: ip)
            }
        } else {
            let resolved = (name?.isEmpty == false) ? name! : ip
            members.append(IPtalkMember(id: ip, name: resolved, ip: ip))
        }
    }

    // MARK: - Send

    func sendDisplayLine(_ text: String) {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: text),
                      port: IPtalkProtocol.port(role: .display, channel: channel))
    }

    func sendCorrection(_ text: String) {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: text),
                      port: IPtalkProtocol.port(role: .correction, channel: channel))
    }

    func sendUndo() {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: ""),
                      port: IPtalkProtocol.port(role: .undo, channel: channel))
    }

    func refreshMembers() async {
        guard isConnected else { return }
        members.removeAll()
        sendBroadcast(IPtalkProtocol.memberDiscoveryRequest(handleName: handleName),
                      port: IPtalkProtocol.port(role: .memberBroadcast, channel: channel))
    }

    func clearReceivedText() {
        receivedLines.removeAll { $0.kind == .display }
    }

    private func sendBroadcast(_ data: Data, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: "255.255.255.255", port: nwPort, using: params)
        send(data, on: conn)
    }

    private func sendUnicast(_ data: Data, to host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        send(data, on: conn)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        trackOutbound(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        if let error {
                            self?.errorMessage = "送信失敗: \(error.localizedDescription)"
                        }
                        self?.releaseOutbound(connection)
                    }
                })
            case .failed(let error):
                Task { @MainActor in
                    self?.errorMessage = "送信失敗: \(error.localizedDescription)"
                    self?.releaseOutbound(connection)
                }
            case .cancelled:
                Task { @MainActor in self?.releaseOutbound(connection) }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
}
