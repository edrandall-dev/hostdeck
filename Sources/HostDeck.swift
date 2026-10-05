// HostDeck: check, wake and connect to the hosts on your network.
// The app sends Wake-on-LAN packets, then checks each host in stages: ping, then the service port.
// For a Windows host, the service is RDP. For a Linux or Other host, the service is SSH,
// and the app tries a real login if an SSH key is set. A macOS host has SSH, Screen Sharing, or both.

import AppKit
import Darwin
import Network
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Model

// other: a device that you reach over SSH and that is not a Linux host, for example a router.
// The raw values are part of the file format (docs/FILE-FORMAT.md). Do not change them.
enum OSType: String, Codable, CaseIterable, Identifiable {
    case linux = "linux", macos = "macos", windows = "windows", other = "other"

    var id: Self { self }
    var label: String {
        switch self {
        case .linux: return "Linux"
        case .macos: return "macOS"
        case .windows: return "Windows"
        case .other: return "Other"
        }
    }
    var usesSSH: Bool { self != .windows }
    var service: String { usesSSH ? "SSH" : "RDP" }
    var defaultPort: Int { usesSSH ? 22 : 3389 }
}

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var mac: String
    var os: OSType = .linux
    // IP address or hostname. The app uses it for ping, the port test and the connection.
    var address: String = ""
    // Empty means the default port for the OS type.
    var port: Int?
    var user: String = ""
    var sshKey: String = ""
    // Linux, macOS and Other hosts can hide Wake-on-LAN. Windows hosts always have it.
    var wakeEnabled = true
    // macOS hosts only. At least one of the two services stays on.
    var sshEnabled = true
    var vncEnabled = true
    // Empty means 5900.
    var vncPort: Int?

    var canWake: Bool { os == .windows || wakeEnabled }
    var macIsValid: Bool { mac.filter(\.isHexDigit).count == 12 }
    // The SSH port, or the RDP port for a Windows host.
    var servicePort: Int { port ?? os.defaultPort }

    // The services that HostDeck tests, in the order that it tests them.
    var services: [Service] {
        switch os {
        case .windows: return [.rdp]
        case .linux, .other: return [.ssh]
        case .macos:
            let list = (sshEnabled ? [Service.ssh] : []) + (vncEnabled ? [.vnc] : [])
            return list.isEmpty ? [.ssh] : list
        }
    }
    func port(_ s: Service) -> Int { s == .vnc ? vncPort ?? Service.vnc.defaultPort : servicePort }
    // The keys in the saved hosts and in the export file. docs/FILE-FORMAT.md defines them, and a Windows
    // version must read the same file. Do not change a raw value: change the format version instead.
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
        case mac = "mac"
        case os = "os"
        case address = "address"
        case port = "port"
        case user = "user"
        case sshKey = "sshKey"
        case wakeEnabled = "wakeEnabled"
        case sshEnabled = "sshEnabled"
        case vncEnabled = "vncEnabled"
        case vncPort = "vncPort"
    }

    // The service that Wake and Connect opens. Only SSH: HostDeck starts the RDP and Screen Sharing apps,
    // but does not connect them.
    var connectService: Service? { services.contains(.ssh) ? .ssh : nil }
    var sshTarget: String { user.isEmpty ? address : "\(user)@\(address)" }
    var sshKeyPath: String { (sshKey as NSString).expandingTildeInPath }
    var sshKeyMissing: Bool { !sshKey.isEmpty && !FileManager.default.fileExists(atPath: sshKeyPath) }
}


extension Host {
    // Hosts saved by version 1 have no OS type. They become Linux hosts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mac = try c.decode(String.self, forKey: .mac)
        // "network" was the first name of the Other type.
        let raw = try c.decodeIfPresent(String.self, forKey: .os)
        os = raw == "network" ? .other : raw.flatMap(OSType.init(rawValue:)) ?? .linux
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        sshKey = try c.decodeIfPresent(String.self, forKey: .sshKey) ?? ""
        wakeEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeEnabled) ?? (os != .other)
        sshEnabled = try c.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
        vncEnabled = try c.decodeIfPresent(Bool.self, forKey: .vncEnabled) ?? true
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort)
    }
}

enum Service: String, Codable, Hashable {
    case ssh, rdp, vnc

    var label: String {
        switch self {
        case .ssh: return "SSH"
        case .rdp: return "RDP"
        case .vnc: return "Screen Sharing"
        }
    }
    // The tag for the log.
    var tag: String { self == .vnc ? "VNC" : label }
    var defaultPort: Int {
        switch self {
        case .ssh: return 22
        case .rdp: return 3389
        case .vnc: return 5900
        }
    }
    // The label of the button that connects to the service.
    var action: String {
        switch self {
        case .ssh: return "Connect"
        case .rdp: return "Open RDP App"
        case .vnc: return "Open Screen Sharing"
        }
    }
}

// The file that Export Hosts writes and Import Hosts reads. Import also accepts a bare array of hosts,
// for example the "hosts" value from `defaults export`.
// docs/FILE-FORMAT.md defines this format. Do not change a key: change the version instead.
struct HostsFile: Codable {
    struct Settings: Codable {
        var broadcast: String?
        var port: Int?
        var timeout: Int?

        enum CodingKeys: String, CodingKey {
            case broadcast = "broadcast"
            case port = "port"
            case timeout = "timeout"
        }
    }
    var app = "HostDeck"
    var version = 1
    var exported = Date()
    var hosts: [Host]
    var settings: Settings?

    enum CodingKeys: String, CodingKey {
        case app = "app"
        case version = "version"
        case exported = "exported"
        case hosts = "hosts"
        case settings = "settings"
    }
}

// down: no ping reply. pingOnly: ping replies, but not all the service ports answer. ready: all the ports are open.
enum Status { case unknown, down, pingOnly, ready }

enum WakeError: LocalizedError {
    case badMAC(String), badAddress(String), socket(Int32)

    var errorDescription: String? {
        switch self {
        case .badMAC(let mac): return "Invalid MAC address: \(mac)"
        case .badAddress(let addr): return "Invalid broadcast address: \(addr)"
        case .socket(let code): return "Network error: \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Network

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum Net {
    static func magicPacket(mac: String) throws -> [UInt8] {
        let hex = Array(mac.filter(\.isHexDigit))
        guard hex.count == 12 else { throw WakeError.badMAC(mac) }
        let macBytes = stride(from: 0, to: 12, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! }
        return [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: macBytes, count: 16).joined())
    }

    // Broadcasts are unacknowledged and Wi-Fi does not retransmit them, so send a few copies.
    static func sendWake(mac: String, broadcast: String, port: UInt16, count: Int = 5) async throws {
        let packet = try magicPacket(mac: mac)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeError.socket(errno) }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, broadcast, &addr.sin_addr) == 1 else { throw WakeError.badAddress(broadcast) }

        for i in 0..<count {
            let sent = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { throw WakeError.socket(errno) }
            if i < count - 1 { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    // One ICMP echo with a one second timeout. True if the host replies.
    static func ping(_ host: String) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "1", "-t", "1", "-q", host]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }

    // Open a TCP connection. With no payload, return empty data when the connection opens.
    // With a payload, send it and return the first reply. With receive and no payload, return the first data
    // that the server sends. Return nil on failure or timeout.
    static func tcp(_ host: String, port: Int, send payload: Data? = nil, receive: Bool = false,
                    timeout: Double = 3) async -> Data? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { cont in
            let once = Once()
            let finish = { (data: Data?) in
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: data)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let read = {
                        conn.receive(minimumIncompleteLength: 4, maximumLength: 1024) { data, _, _, _ in finish(data) }
                    }
                    guard let payload else { return receive ? read() : finish(Data()) }
                    conn.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { return finish(nil) }
                        read()
                    })
                case .failed, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // True if a TCP connection to the port opens. Try again after one second if the first try fails:
    // macOS can block the first connections of the app for a moment after it starts.
    static func portOpen(_ host: String, port: Int) async -> Bool {
        if await tcp(host, port: port) != nil { return true }
        try? await Task.sleep(for: .seconds(1))
        return await tcp(host, port: port) != nil
    }

    // X.224 Connection Request with an RDP negotiation request (TLS and CredSSP).
    private static let rdpRequest = Data([
        0x03, 0x00, 0x00, 0x13,                         // TPKT header, length 19
        0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,       // X.224 Connection Request
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00, // RDP_NEG_REQ
    ])

    // True if the server sends an X.224 Connection Confirm. This proves an RDP service, not only an open port.
    static func rdpHandshake(_ host: String, port: Int) async -> Bool {
        guard let reply = await tcp(host, port: port, send: rdpRequest, timeout: 5) else { return false }
        let bytes = [UInt8](reply)
        return bytes.count >= 6 && bytes[0] == 0x03 && bytes[5] == 0xD0
    }

    // True if the server sends an RFB banner, for example "RFB 003.889". This proves a VNC service.
    static func rfbBanner(_ host: String, port: Int) async -> Bool {
        guard let reply = await tcp(host, port: port, receive: true, timeout: 5) else { return false }
        return reply.starts(with: Data("RFB ".utf8))
    }

    // Log in with the host's SSH key. BatchMode stops ssh from asking for a password.
    // The test passes when ssh reports "Authenticated to", so it does not depend on a remote command:
    // RouterOS has no shell. Linux and macOS hosts run "exit 0". Other hosts get no command, and ssh stops on success.
    static func sshLogin(_ host: Host) async -> (ok: Bool, message: String) {
        var args = ["-v", "-T", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes",
                    "-o", "IdentitiesOnly=yes", "-i", host.sshKeyPath, "-p", String(host.servicePort), host.sshTarget]
        if host.os == .linux || host.os == .macos { args.append("exit 0") }

        return await withCheckedContinuation { cont in
            let p = Process()
            let errors = Pipe()
            let output = SSHOutput()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errors
            errors.fileHandleForReading.readabilityHandler = { handle in
                if output.add(handle.availableData) && p.isRunning { p.terminate() }
            }
            p.terminationHandler = { _ in
                errors.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: output.result())
            }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
            } catch {
                cont.resume(returning: (false, error.localizedDescription))
            }
        }
    }
}

// Collects the stderr of ssh -v from a background queue.
final class SSHOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    // Add output. True the first time the output shows a successful login.
    func add(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = text.contains("Authenticated to")
        text += String(data: data, encoding: .utf8) ?? ""
        return !before && text.contains("Authenticated to")
    }

    // The login result, and the last line that is not debug output.
    func result() -> (ok: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let message = text.split(whereSeparator: \.isNewline).map(String.init)
            .last { !$0.hasPrefix("debug") && !$0.hasPrefix("OpenSSH") && !$0.isEmpty } ?? ""
        return (text.contains("Authenticated to"), message)
    }
}

// Gives an NSMenuItem a closure for its action.
final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var hosts: [Host] { didSet { save() } }
    @AppStorage("broadcast") var broadcast = "255.255.255.255"
    @AppStorage("port") var port = 9
    @AppStorage("timeout") var timeout = 180

    @Published var status: [UUID: Status] = [:]
    // The services whose port answered at the last check.
    @Published var open: [UUID: Set<Service>] = [:]
    @Published var lastChecked: Date?
    @Published var log: [UUID: [String]] = [:]
    // The services that failed in the last Wake or Test run. The next run clears them. The status poll does not.
    @Published var failed: [UUID: Set<Service>] = [:]
    @Published private var runs: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var poller: Task<Void, Never>?

    init() {
        Self.importFromWake()
        if let data = UserDefaults.standard.data(forKey: "hosts"),
           let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
        } else {
            hosts = []
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // The app was called Wake, with the bundle ID uk.edrandall.wake. Copy its hosts and settings one time.
    private static func importFromWake() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: "hosts") == nil,
              let old = UserDefaults(suiteName: "uk.edrandall.wake"),
              let hosts = old.data(forKey: "hosts") else { return }
        defaults.set(hosts, forKey: "hosts")
        for key in ["broadcast", "port", "timeout"] {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: "hosts") }
    }

    func isBusy(_ id: UUID) -> Bool { runs[id] != nil }

    // Ping first. Test the service port only if the ping replies.
    // A host is online if it replies to ping. A wake packet has no use for an online host.
    func isOnline(_ id: UUID) -> Bool { status[id] == .ready || status[id] == .pingOnly }
    // Why the button for a service is not available. Nil if you can connect: the host replies to ping,
    // the service port answers, no run is busy, and the service did not fail in the last run.
    func notReadyReason(_ h: Host, _ s: Service) -> String? {
        if h.address.isEmpty { return "No address set" }
        if isBusy(h.id) { return "Wait for the run to finish" }
        switch status[h.id] {
        case .down: return "Host is down"
        case .pingOnly, .ready:
            if !(open[h.id] ?? []).contains(s) { return "Host is up, but \(s.label) port \(h.port(s)) is not answering" }
            if (failed[h.id] ?? []).contains(s) { return "The last \(s.label) test failed" }
            return nil
        default: return "Checking the host"
        }
    }

    // Ready if all the services answer, pingOnly if some do not.
    private static func status(_ h: Host, open: Set<Service>) -> Status {
        h.services.allSatisfy(open.contains) ? .ready : .pingOnly
    }

    private static func probe(_ h: Host) async -> (Status, Set<Service>) {
        guard await Net.ping(h.address) else { return (.down, []) }
        var open = Set<Service>()
        for s in h.services {
            if await Net.portOpen(h.address, port: h.port(s)) { open.insert(s) }
        }
        return (status(h, open: open), open)
    }

    func refreshStatus() async {
        await withTaskGroup(of: (UUID, Status, Set<Service>).self) { group in
            for h in hosts where !h.address.isEmpty {
                group.addTask {
                    let (s, o) = await Self.probe(h)
                    return (h.id, s, o)
                }
            }
            for await (id, s, o) in group where !isBusy(id) {
                status[id] = s
                open[id] = o
            }
        }
        lastChecked = Date()
    }

    // Check one host now, for example when you select it.
    func check(_ id: UUID) async {
        guard let h = hosts.first(where: { $0.id == id }), !h.address.isEmpty else {
            status[id] = nil
            open[id] = nil
            return
        }
        let (s, o) = await Self.probe(h)
        if !isBusy(id) {
            status[id] = s
            open[id] = o
        }
    }

    private func append(_ id: UUID, _ tag: String, _ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log[id, default: []].append("\(time)  \(tag.padding(toLength: 8, withPad: " ", startingAt: 0))\(text)")
    }

    // Repeat the check once a second until it passes, the deadline passes, or the task is cancelled.
    private func waitUntil(_ deadline: Date, _ check: () async -> Bool) async -> Bool {
        while !Task.isCancelled {
            if await check() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // wake: send the packet, then wait for each stage until the timeout.
    // Without wake, test each stage one time.
    func run(_ host: Host, wake: Bool, connect: Bool) {
        tasks[host.id]?.cancel()
        let run = UUID()
        runs[host.id] = run
        log[host.id] = []
        failed[host.id] = nil

        tasks[host.id] = Task {
            defer {
                if runs[host.id] == run {
                    runs[host.id] = nil
                    tasks[host.id] = nil
                }
            }
            let id = host.id
            let addr = host.address

            if wake {
                append(id, "START", "Sending wake packet to \(host.mac) via \(broadcast):\(port)")
                do {
                    try await Net.sendWake(mac: host.mac, broadcast: broadcast, port: UInt16(clamping: port))
                } catch {
                    append(id, "ERROR", error.localizedDescription)
                    return
                }
            }
            guard !addr.isEmpty else {
                append(id, wake ? "DONE" : "ERROR", "Set an address to test \(host.name).")
                return
            }

            let deadline = Date().addingTimeInterval(wake ? TimeInterval(timeout) : 0)
            let fail = { (stage: String, what: String, services: [Service]) in
                if Task.isCancelled {
                    self.append(id, "CANCEL", "Stopped")
                } else {
                    self.failed[id, default: []].formUnion(services)
                    self.append(id, stage, wake ? "\(what) after \(self.timeout) seconds" : what)
                }
            }

            append(id, "PING", wake ? "Waiting for \(host.name) to respond at \(addr)" : "Testing \(addr)")
            guard await waitUntil(deadline, { await Net.ping(addr) }) else {
                status[id] = .down
                open[id] = []
                return fail("PING", "No reply to ping", host.services)
            }
            status[id] = .pingOnly
            open[id] = []
            append(id, "PING", "\(host.name) responds to ping")

            // Test each service. A failed service does not stop the test of the next one.
            for svc in host.services {
                let p = host.port(svc)
                append(id, svc.tag, "Waiting for \(svc.label) on port \(p)")
                guard await waitUntil(deadline, { await Net.portOpen(addr, port: p) }) else {
                    fail(svc.tag, "Port \(p) is not answering", [svc])
                    if Task.isCancelled { return }
                    continue
                }
                open[id, default: []].insert(svc)
                status[id] = Self.status(host, open: open[id] ?? [])
                append(id, svc.tag, "Port \(p) is open")

                switch svc {
                case .rdp:
                    if await Net.rdpHandshake(addr, port: p) {
                        append(id, "RDP", "The RDP service accepted the connection request")
                    } else {
                        failed[id, default: []].insert(svc)
                        append(id, "RDP", "Port is open, but no RDP handshake reply")
                    }
                case .vnc:
                    if await Net.rfbBanner(addr, port: p) {
                        append(id, "VNC", "The Screen Sharing service sent its RFB banner")
                    } else {
                        failed[id, default: []].insert(svc)
                        append(id, "VNC", "Port is open, but no RFB banner")
                    }
                case .ssh:
                    if host.sshKey.isEmpty {
                        append(id, "LOGIN", "No SSH key set, so no login test")
                    } else if host.sshKeyMissing {
                        failed[id, default: []].insert(svc)
                        append(id, "LOGIN", "Key file not found: \(host.sshKeyPath)")
                    } else {
                        append(id, "LOGIN", "Logging in as \(host.sshTarget) with \(host.sshKey)")
                        let result = await Net.sshLogin(host)
                        if result.ok {
                            append(id, "LOGIN", "Login succeeded")
                        } else {
                            failed[id, default: []].insert(svc)
                            append(id, "LOGIN", "Failed: \(result.message)")
                        }
                    }
                }
                if Task.isCancelled { return append(id, "CANCEL", "Stopped") }
            }

            let bad = failed[id] ?? []
            if bad.isEmpty {
                switch host.os {
                case .windows: append(id, "READY", "\(host.name) is ready for RDP connections on port \(host.servicePort)")
                case .macos: append(id, "READY", "\(host.name) is ready for \(host.services.map(\.label).joined(separator: " and "))")
                case .linux, .other: append(id, "READY", "\(host.name) is ready")
                }
                NSSound(named: "Glass")?.play()
            }
            // Connect if the chosen service passed, even if another service failed.
            if connect, let svc = host.connectService, !bad.contains(svc), (open[id] ?? []).contains(svc) {
                self.connect(host, svc)
            }
        }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func delete(_ id: UUID) {
        cancel(id)
        hosts.removeAll { $0.id == id }
        failed[id] = nil
        open[id] = nil
    }

    // MARK: Export and import

    func exportHosts() {
        let panel = NSSavePanel()
        panel.title = "Export Hosts"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HostDeck hosts \(Date().formatted(.iso8601.year().month().day())).json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let file = HostsFile(hosts: hosts, settings: .init(broadcast: broadcast, port: port, timeout: timeout))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(file).write(to: url, options: .atomic)
            alert("Exported \(hosts.count) hosts", "HostDeck wrote the hosts and settings to \(url.lastPathComponent).")
        } catch {
            alert("Cannot export the hosts", error.localizedDescription)
        }
    }

    // Merge by host ID: a host with a known ID replaces that host, and other hosts are added.
    // Import does not delete hosts. Settings in the file replace the current settings.
    func importHosts() {
        let panel = NSOpenPanel()
        panel.title = "Import Hosts"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: HostsFile
        do {
            let data = try Data(contentsOf: url)
            if let list = try? decoder.decode([Host].self, from: data) {
                file = HostsFile(hosts: list)
            } else {
                file = try decoder.decode(HostsFile.self, from: data)
            }
        } catch {
            return alert("Cannot import the hosts", "\(url.lastPathComponent) is not a HostDeck export.")
        }

        var list = hosts
        var added = 0, replaced = 0
        for h in file.hosts {
            if let i = list.firstIndex(where: { $0.id == h.id }) {
                list[i] = h
                replaced += 1
            } else {
                list.append(h)
                added += 1
            }
        }
        hosts = list
        if let s = file.settings {
            if let v = s.broadcast { broadcast = v }
            if let v = s.port { port = v }
            if let v = s.timeout { timeout = v }
        }
        Task { await refreshStatus() }
        alert("Imported \(file.hosts.count) hosts", "\(added) added, \(replaced) replaced.")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func connect(_ host: Host, _ s: Service) {
        switch s {
        case .ssh: openSSH(host)
        case .rdp: chooseRDPApp(for: host)
        case .vnc: openScreenSharing(host)
        }
    }

    // Start the Screen Sharing app. As for RDP, HostDeck does not give it the host or any credentials.
    func openScreenSharing(_ host: Host) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSharing") else {
            return append(host.id, "ERROR", "Cannot find the Screen Sharing app")
        }
        launchApp(app, for: host)
    }

    // Write a .command file and open it. Terminal runs it. This needs no Automation permission.
    static let terminalFontSize = 16
    static let terminalColumns = 132
    static let terminalRows = 36

    func openSSH(_ host: Host) {
        append(host.id, "CONNECT", "Opening SSH session to \(host.sshTarget)")
        var parts = ["ssh"]
        if host.servicePort != 22 { parts += ["-p", String(host.servicePort)] }
        if !host.sshKey.isEmpty {
            parts += ["-i", quote(host.sshKeyPath)]
        }
        parts.append(quote(host.sshTarget))

        let url = tempFile(host, ext: "command")
        // Before ssh starts, make this Terminal tab larger and its font larger.
        // Only this tab changes. The Terminal profile stays the same.
        let resize = [
            "on run {t}", "tell application \"Terminal\"", "repeat with w in windows", "repeat with b in tabs of w",
            "if tty of b is t then", "set font size of b to \(Self.terminalFontSize)",
            "set number of columns of b to \(Self.terminalColumns)", "set number of rows of b to \(Self.terminalRows)",
            "end if", "end repeat", "end repeat", "end tell", "end run",
        ].map { "-e " + quote($0) }.joined(separator: " ")
        let script = """
            #!/bin/zsh
            rm -f \(quote(url.path))
            osascript \(resize) "$(tty)" >/dev/null 2>&1
            exec \(parts.joined(separator: " "))

            """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            append(host.id, "ERROR", "Cannot open Terminal: \(error.localizedDescription)")
        }
    }

    // Apps that open .rdp files or rdp:// links, for example Windows App. HostDeck uses this to find RDP apps.
    func rdpApps() -> [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "rdp://")!)
        if let type = UTType(filenameExtension: "rdp") {
            apps += NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
        var seen = Set<URL>()
        return apps.filter { seen.insert($0.standardizedFileURL).inserted }
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    func appName(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }

    // Show a menu of RDP apps at the mouse pointer.
    func chooseRDPApp(for host: Host) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Open RDP app", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let apps = rdpApps()
        if apps.isEmpty {
            let none = NSMenuItem(title: "No RDP app is installed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for app in apps {
            let action = MenuAction { [weak self] in self?.launchApp(app, for: host) }
            let item = NSMenuItem(title: appName(app), action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // Start the app. HostDeck does not give it the host or any credentials.
    func launchApp(_ app: URL, for host: Host) {
        append(host.id, "OPEN", "Starting \(appName(app))")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in self.append(host.id, "ERROR", "Cannot start \(self.appName(app)): \(error.localizedDescription)") }
            }
        }
    }

    private func tempFile(_ host: Host, ext: String) -> URL {
        let safeName = host.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return FileManager.default.temporaryDirectory.appendingPathComponent("hostdeck-\(safeName).\(ext)")
    }

    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Views

@main
struct HostDeckApp: App {
    @StateObject private var store = Store()

    init() {
        // Show tooltips after 0.2 seconds, not the macOS default of about 1 second. This applies to HostDeck only.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    }

    var body: some Scene {
        WindowGroup("HostDeck", id: "main") {
            ContentView().environmentObject(store)
                .font(.system(size: UI.body))
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 880, height: 640)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import Hosts…") { store.importHosts() }
                Button("Export Hosts…") { store.exportHosts() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("HostDeck", systemImage: "server.rack") {
            MenuContent().environmentObject(store)
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

// Text sizes, two points larger than the macOS defaults (13 and 10).
enum UI {
    static let body: CGFloat = 15
    static let caption: CGFloat = 12
}

// A filled button that keeps its colour when the window is not active.
// A disabled button fades, so it is clear which buttons you can click.
struct ActionButtonStyle: ButtonStyle {
    var color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: UI.body, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

// A rounded box of rows, in the style of a grouped form.
struct FieldCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// One row of a FieldCard: the label on the left, the control on the right.
struct FieldRow<Control: View>: View {
    let label: String
    var divider = true
    var warning: String?
    @ViewBuilder var control: Control

    init(_ label: String, divider: Bool = true, warning: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.divider = divider
        self.warning = warning
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer(minLength: 24)
                control
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
            }
            if let warning {
                Text(warning).font(.system(size: UI.caption)).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 9)
        if divider { Divider() }
    }
}

// The status of the host in words, next to the buttons.
struct StatusLine: View {
    let host: Host
    let status: Status?
    let open: Set<Service>
    let failed: Set<Service>
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, busy: busy)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var text: String {
        if busy { return "Working" }
        if host.address.isEmpty { return "No address set" }
        let services = host.services
        let names = { (list: [Service]) in list.map(\.label).joined(separator: " and ") }
        switch status {
        case .ready:
            let bad = services.filter(failed.contains)
            return bad.isEmpty ? "Online: ready for \(names(services))" : "Online, but the last \(names(bad)) test failed"
        case .pingOnly:
            let closed = services.filter { !open.contains($0) }
            let ports = closed.map { "\($0.label) port \(host.port($0))" }.joined(separator: " and ")
            return "Online, but \(ports) \(closed.count == 1 ? "is" : "are") not answering"
        case .down: return "Offline"
        default: return "Checking"
        }
    }
}

// A small mark for the OS type: four panes for Windows, a penguin for Linux, an apple for macOS.
struct OSIcon: View {
    let os: OSType

    var body: some View {
        Group {
            switch os {
            case .windows:
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.0, green: 0.47, blue: 0.84))
            case .linux:
                TuxIcon().frame(width: 15, height: 17)
            case .macos:
                Image(systemName: "apple.logo")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            case .other:
                Image(systemName: "wifi.router.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18)
        .accessibilityLabel(os.label)
    }
}

// A flat Tux: black body, white front, orange beak and feet.
struct TuxIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func oval(_ x: CGFloat, _ y: CGFloat, _ ow: CGFloat, _ oh: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x * w, y: y * h, width: ow * w, height: oh * h))
            }
            let orange = Color(red: 0.98, green: 0.69, blue: 0.10)
            let body = oval(0.12, 0.0, 0.76, 0.92)
            ctx.fill(body, with: .color(.black))
            ctx.stroke(body, with: .color(.gray.opacity(0.6)), lineWidth: 0.5)
            ctx.fill(oval(0.24, 0.36, 0.52, 0.52), with: .color(.white))
            ctx.fill(oval(0.30, 0.14, 0.15, 0.17), with: .color(.white))
            ctx.fill(oval(0.55, 0.14, 0.15, 0.17), with: .color(.white))
            ctx.fill(oval(0.35, 0.19, 0.07, 0.08), with: .color(.black))
            ctx.fill(oval(0.58, 0.19, 0.07, 0.08), with: .color(.black))
            ctx.fill(oval(0.36, 0.30, 0.28, 0.12), with: .color(orange))
            ctx.fill(oval(0.06, 0.84, 0.38, 0.16), with: .color(orange))
            ctx.fill(oval(0.56, 0.84, 0.38, 0.16), with: .color(orange))
        }
    }
}

// The bottom of the host list: a key for the status symbols, a summary, and the time of the last check.
struct SidebarFooter: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL

    private let statuses: [(Status?, String)] = [
        (.ready, "Ready"),
        (.pingOnly, "Online, service not answering"),
        (.down, "Offline"),
        (nil, "Not checked"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.bottom, 4)
            Text("HostDeck").font(.system(size: UI.body, weight: .bold))
            ForEach(statuses, id: \.1) { status, text in
                HStack(spacing: 8) {
                    StatusDot(status: status, busy: false)
                    Text(text)
                }
            }
            Divider().padding(.vertical, 4)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary)
                    Text(checked).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openURL(URL(string: "https://www.edrandall.uk/lab-notes/hostdeck/")!)
                } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .help("Open the HostDeck page on edrandall.uk")
            }
        }
        .font(.system(size: UI.caption))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var summary: String {
        let checked = store.hosts.filter { !$0.address.isEmpty }
        let online = checked.filter { store.isOnline($0.id) }.count
        return "\(online) of \(checked.count) online"
    }

    private var checked: String {
        guard let date = store.lastChecked else { return "Not checked yet" }
        return "Checked at \(date.formatted(date: .omitted, time: .standard))"
    }
}

// The status of a host as a symbol. Each status has its own shape, so the colour is not necessary
// to read it: a tick for ready, "!" for online with the service not answering, an empty circle
// with "x" for offline, and a dashed circle for not checked.
struct StatusDot: View {
    let status: Status?
    let busy: Bool

    var body: some View {
        if busy {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .accessibilityLabel(name)
        }
    }

    private var symbol: String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .pingOnly: return "exclamationmark.circle.fill"
        case .down: return "xmark.circle"
        default: return "circle.dashed"
        }
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .pingOnly: return .orange
        case .down: return .red
        default: return .secondary
        }
    }

    private var name: String {
        switch status {
        case .ready: return "Ready"
        case .pingOnly: return "Online, service not answering"
        case .down: return "Offline"
        default: return "Not checked"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.hosts) { host in
                    HStack {
                        StatusDot(status: store.status[host.id], busy: store.isBusy(host.id))
                        OSIcon(os: host.os)
                        Text(host.name)
                        Spacer()
                        Text(host.os.label).font(.system(size: UI.caption)).foregroundStyle(.secondary)
                    }
                    .tag(host.id)
                    .contextMenu {
                        if host.canWake {
                            Button("Wake") { store.run(host, wake: true, connect: false) }
                                .disabled(!host.macIsValid || store.isOnline(host.id))
                        }
                        Button("Test") { store.run(host, wake: false, connect: false) }
                        Button("Delete", role: .destructive) { delete(host.id) }
                    }
                }
                .onMove { store.hosts.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .toolbar {
                ToolbarItem {
                    Button {
                        let host = Host(name: "new-host", mac: "")
                        store.hosts.append(host)
                        selection = host.id
                    } label: { Label("Add Host", systemImage: "plus") }
                }
            }
            .onDeleteCommand { if let id = selection { delete(id) } }
        } detail: {
            if let id = selection, store.hosts.contains(where: { $0.id == id }) {
                HostDetail(id: id)
            } else {
                Text("Select a host").foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection == nil { selection = store.hosts.first?.id } }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        store.delete(id)
    }
}

struct HostDetail: View {
    @EnvironmentObject var store: Store
    let id: UUID

    private var host: Binding<Host> {
        Binding(
            get: { store.hosts.first { $0.id == id } ?? Host(name: "", mac: "") },
            set: { new in
                if let i = store.hosts.firstIndex(where: { $0.id == id }) { store.hosts[i] = new }
            }
        )
    }

    var body: some View {
        let h = host.wrappedValue
        let busy = store.isBusy(id)

        VStack(alignment: .leading, spacing: 16) {
            // The cards take only the height of their fields. The log below uses the rest of the window.
            VStack(alignment: .leading, spacing: 12) {
                FieldCard {
                    FieldRow("Name") { TextField("Name", text: host.name) }
                    FieldRow("OS") {
                        Picker("OS", selection: host.os) {
                            ForEach(OSType.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if h.os != .windows {
                        FieldRow("Wake-on-LAN") {
                            Toggle("Wake-on-LAN", isOn: host.wakeEnabled).toggleStyle(.switch)
                        }
                    }
                    if h.canWake {
                        FieldRow("MAC address", warning: !h.mac.isEmpty && !h.macIsValid ? "A MAC address needs 12 hex digits." : nil) {
                            TextField("MAC address", text: host.mac, prompt: Text("00:11:22:33:44:55"))
                        }
                    }
                    FieldRow("Address", divider: h.os != .macos) {
                        TextField("Address", text: host.address, prompt: Text("IP or hostname"))
                    }
                    if h.os != .macos {
                        FieldRow("\(h.os.service) port", divider: false) {
                            TextField("Port", value: host.port, format: .number.grouping(.never),
                                      prompt: Text(String(h.os.defaultPort)))
                        }
                    }
                }
                if h.os == .macos {
                    // Each service has a switch and a port. You cannot turn off the last service that is on.
                    FieldCard {
                        FieldRow("SSH") {
                            Toggle("SSH", isOn: host.sshEnabled).toggleStyle(.switch)
                                .disabled(h.sshEnabled && !h.vncEnabled)
                        }
                        if h.sshEnabled {
                            FieldRow("SSH port") {
                                TextField("SSH port", value: host.port, format: .number.grouping(.never),
                                          prompt: Text(String(Service.ssh.defaultPort)))
                            }
                        }
                        FieldRow("Screen Sharing", divider: h.vncEnabled) {
                            Toggle("Screen Sharing", isOn: host.vncEnabled).toggleStyle(.switch)
                                .disabled(h.vncEnabled && !h.sshEnabled)
                        }
                        if h.vncEnabled {
                            FieldRow("Screen Sharing port", divider: false) {
                                TextField("Screen Sharing port", value: host.vncPort, format: .number.grouping(.never),
                                          prompt: Text(String(Service.vnc.defaultPort)))
                            }
                        }
                    }
                }
                if h.os.usesSSH {
                    let keyRow = h.services.contains(.ssh)
                    FieldCard {
                        FieldRow("User", divider: keyRow) { TextField("User", text: host.user, prompt: Text("optional")) }
                        if keyRow {
                            FieldRow("SSH key", divider: false, warning: h.sshKeyMissing ? "Key file not found." : nil) {
                                TextField("SSH key", text: host.sshKey, prompt: Text("optional, for example ~/.ssh/id_ed25519"))
                            }
                        }
                    }
                }
            }
            .padding([.horizontal, .top])


            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((store.log[id] ?? []).enumerated()), id: \.offset) { i, line in
                            Text(line).id(i)
                        }
                    }
                    .font(.system(size: UI.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    Button { store.log[id] = [] } label: {
                        Image(systemName: "trash").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(busy || (store.log[id] ?? []).isEmpty)
                    .help("Clear the log (⌘K)")
                    .padding(8)
                }
                .onChange(of: store.log[id]?.count) { _, n in
                    if let n, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .padding(.horizontal)

            // What the buttons below do.
            Text(footer(h.os))
                .font(.system(size: UI.caption)).foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack {
                if busy {
                    Button("Cancel", role: .cancel) { store.cancel(id) }
                        .keyboardShortcut(.escape, modifiers: [])
                        .buttonStyle(ActionButtonStyle(color: .red))
                } else {
                    if h.canWake {
                        Button("Wake") { store.run(h, wake: true, connect: false) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!h.macIsValid || store.isOnline(id))
                            .buttonStyle(ActionButtonStyle(color: .green))
                    }
                    if h.canWake && h.connectService != nil {
                        Button("Wake and Connect") { store.run(h, wake: true, connect: true) }
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                            .disabled(!h.macIsValid || h.address.isEmpty || store.isOnline(id))
                            .buttonStyle(ActionButtonStyle(color: .green))
                    }
                    Button("Test") { store.run(h, wake: false, connect: false) }
                        .keyboardShortcut("t", modifiers: .command)
                        .disabled(h.address.isEmpty)
                        .buttonStyle(ActionButtonStyle(color: .blue))
                }
                StatusLine(host: h, status: store.status[id], open: store.open[id] ?? [],
                           failed: store.failed[id] ?? [], busy: busy)
                    .padding(.leading, 8)
                Spacer()
                ForEach(h.services, id: \.self) { svc in
                    let reason = store.notReadyReason(h, svc)
                    Button(svc.action) { store.connect(h, svc) }
                        .disabled(reason != nil)
                        .buttonStyle(ActionButtonStyle(color: .blue))
                        // macOS shows no tooltip on a disabled button, so a near-clear layer on top of it carries the tooltip.
                        .overlay {
                            if let reason {
                                Color.white.opacity(0.001).help(reason)
                            }
                        }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .navigationTitle("HostDeck")
        .navigationSubtitle(h.name)
        .task(id: "\(id) \(h.address) \(h.services.map { h.port($0) })") { await store.check(id) }
    }

    private func footer(_ os: OSType) -> String {
        switch os {
        case .linux: return "With an SSH key, the test logs in over SSH. HostDeck does not store passwords."
        case .macos: return "With an SSH key, the test logs in over SSH. Open Screen Sharing starts the Screen Sharing app."
        case .windows: return "The test checks for an RDP handshake. Open RDP App starts the RDP app that you choose."
        case .other: return "With an SSH key, the test logs in over SSH. Turn on Wake-on-LAN only if the device supports it."
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.hosts) { host in
            Menu {
                if host.canWake {
                    Button("Wake") { store.run(host, wake: true, connect: false) }
                        .disabled(!host.macIsValid || store.isOnline(host.id))
                }
                if host.canWake && host.connectService != nil {
                    Button("Wake and Connect") { store.run(host, wake: true, connect: true) }
                        .disabled(!host.macIsValid || host.address.isEmpty || store.isOnline(host.id))
                }
                ForEach(host.services, id: \.self) { svc in
                    if svc == .rdp {
                        Menu("Open RDP App") {
                            ForEach(store.rdpApps(), id: \.self) { app in
                                Button(store.appName(app)) { store.launchApp(app, for: host) }
                            }
                        }
                        .disabled(store.notReadyReason(host, svc) != nil)
                    } else {
                        Button(svc.action) { store.connect(host, svc) }
                            .disabled(store.notReadyReason(host, svc) != nil)
                    }
                }
            } label: {
                Text(label(host))
            }
        }
        Divider()
        Button("Open HostDeck") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func label(_ host: Host) -> String {
        if store.isBusy(host.id) { return "◌ \(host.name)" }
        switch store.status[host.id] {
        case .ready: return "● \(host.name)"
        case .pingOnly: return "◐ \(host.name)"
        case .down: return "○ \(host.name)"
        default: return "   \(host.name)"
        }
    }
}

struct SettingsView: View {
    @AppStorage("broadcast") private var broadcast = "255.255.255.255"
    @AppStorage("port") private var port = 9
    @AppStorage("timeout") private var timeout = 180

    var body: some View {
        Form {
            TextField("Broadcast address", text: $broadcast)
            Text("Use the subnet broadcast (for example 192.168.1.255) if 255.255.255.255 does not reach the host.")
                .font(.system(size: UI.caption)).foregroundStyle(.secondary)
            TextField("UDP port", value: $port, format: .number.grouping(.never))
            TextField("Wait timeout (seconds)", value: $timeout, format: .number.grouping(.never))
        }
        .padding(20)
        .frame(width: 440)
    }
}
