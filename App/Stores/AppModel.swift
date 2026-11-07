import Foundation
import HerdrKit
import HerdrSSH
import Observation
import SwiftUI

struct BannerItem: Identifiable, Equatable {
    let id = UUID()
    let serverId: UUID
    let serverName: String
    let transition: AgentTransition
}

struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let serverName: String
    let host: String
    let fingerprint: String
    let answer: (Bool) -> Void
}

enum ConnectError: Error, LocalizedError, Equatable {
    case missingKey, needsPassphrase, hostKeyChanged(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: "Für diesen Server ist kein SSH-Key hinterlegt."
        case .needsPassphrase: "Bitte gib die Passphrase des SSH-Keys ein."
        case .hostKeyChanged(let host):
            "Achtung: Der Host-Key von \(host) hat sich geändert. Das kann ein Angriff sein. Die Verbindung wurde abgebrochen."
        }
    }
}

/// App-wide state: profiles, key metadata, known hosts, open connections.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [ServerProfile]
    private(set) var keys: [StoredKeyRef]
    private(set) var knownHosts: KnownHosts
    var hostKeyPrompt: HostKeyPrompt?
    /// Bumped whenever connections should be (re)established, e.g. after returning from background.
    private(set) var reconnectToken = 0
    var pendingDeepLink: DeepLink?
    /// Programmatic navigation (replaces the stack), e.g. after starting an agent.
    var pendingPath: [Route]?
    /// In-app banner for agents that just need attention (foreground only).
    var banner: BannerItem?
    /// The agent detail currently on screen; no banner for it.
    var visibleAgent: (server: UUID, target: String)?
    private var bannerTask: Task<Void, Never>?

    let keyStore = KeychainKeyStore()
    let lock: AppLock

    private struct Connection { let shell: CitadelShell; let session: LiveSession }
    private var connections: [UUID: Connection] = [:]
    private var connecting: [UUID: Task<LiveSession, Error>] = [:]
    private var rejectedChange: Set<String> = []

    private let serverStore: JSONFileStore<[ServerProfile]>
    private let keyRefStore: JSONFileStore<[StoredKeyRef]>
    private let knownHostsStore: JSONFileStore<KnownHosts>

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        serverStore = .init(url: dir.appendingPathComponent("servers.json"))
        keyRefStore = .init(url: dir.appendingPathComponent("keys.json"))
        knownHostsStore = .init(url: dir.appendingPathComponent("known_hosts.json"))
        servers = serverStore.load() ?? []
        keys = keyRefStore.load() ?? []
        knownHosts = knownHostsStore.load() ?? KnownHosts()
        lock = AppLock(keyStore: keyStore)
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            lock.didEnterBackground()
            disconnectAll()
        case .active:
            if !lock.didBecomeActive() && !lock.isLocked { reconnectToken += 1 }
        default: break
        }
    }

    func disconnectAll() {
        for (_, c) in connections {
            c.session.stop()
            Task { await c.shell.close() }
        }
        connections.removeAll()
        connecting.values.forEach { $0.cancel() }
        connecting.removeAll()
    }

    // MARK: - Keys

    func key(_ id: UUID) -> StoredKeyRef? { keys.first { $0.id == id } }

    @discardableResult
    func importKey(label: String, pem: String, passphrase: String?, rememberPassphrase: Bool) throws -> (StoredKeyRef, ParsedKey) {
        let parsed = try SSHKeyImport.parse(pem, passphrase: passphrase)
        let ref = StoredKeyRef(id: UUID(), label: label.isEmpty ? "SSH-Key" : label, kind: parsed.kind,
                               publicKeyOpenSSH: parsed.publicKeyOpenSSH, fingerprintSHA256: parsed.fingerprintSHA256,
                               hasPassphrase: parsed.isEncrypted)
        try keyStore.save(pem: pem, passphrase: rememberPassphrase ? passphrase : nil, for: ref.id)
        keys.append(ref)
        try keyRefStore.save(keys)
        return (ref, parsed)
    }

    func deleteKey(_ id: UUID) throws {
        try keyStore.delete(id)
        keys.removeAll { $0.id == id }
        try keyRefStore.save(keys)
    }

    // MARK: - Servers

    func saveServer(_ p: ServerProfile) throws {
        if let i = servers.firstIndex(where: { $0.id == p.id }) {
            servers[i] = p
            disconnect(p.id)
        } else {
            servers.append(p)
        }
        try serverStore.save(servers)
    }

    func deleteServer(_ id: UUID) throws {
        disconnect(id)
        let removed = server(id)
        servers.removeAll { $0.id == id }
        try serverStore.save(servers)
        if let r = removed, !servers.contains(where: { $0.host.lowercased() == r.host.lowercased() && $0.port == r.port }) {
            forgetHostKey(host: r.host, port: r.port)
        }
    }

    /// Deliberate reset after a legitimate host key change (e.g. VPS reinstalled).
    func forgetHostKey(host: String, port: Int) {
        knownHosts.forget(host: host, port: port)
        try? knownHostsStore.save(knownHosts)
    }

    func hasTrustedHostKey(host: String, port: Int) -> Bool {
        knownHosts.check(host: host, port: port, fingerprint: "") != .unknown
    }

    func server(_ id: UUID) -> ServerProfile? { servers.first { $0.id == id } }

    func recordCounts(for id: UUID, snapshot: HerdrSnapshot) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        var counts: [AgentStatus: Int] = [:]
        for a in snapshot.agents { counts[a.agentStatus, default: 0] += 1 }
        guard servers[i].lastKnownCounts != counts else { return }
        servers[i].lastKnownCounts = counts
        try? serverStore.save(servers)
    }

    // MARK: - Connections

    func disconnect(_ id: UUID) {
        if let c = connections.removeValue(forKey: id) {
            c.session.stop()
            Task { await c.shell.close() }
        }
        connecting.removeValue(forKey: id)?.cancel()
    }

    func shell(for id: UUID) -> CitadelShell? { connections[id]?.shell }
    func liveSession(for id: UUID) -> LiveSession? { connections[id]?.session }

    /// Returns a running LiveSession, connecting if needed. `passphrase` is used when it isn't stored.
    func session(for profile: ServerProfile, passphrase: String? = nil) async throws -> LiveSession {
        if let c = connections[profile.id], c.shell.isConnected {
            await c.session.ensureRunning()
            return c.session
        }
        if let c = connections.removeValue(forKey: profile.id) {
            c.session.stop()
            Task { await c.shell.close() }
        }
        if let t = connecting[profile.id] { return try await t.value }
        let task = Task { @MainActor in try await self.openConnection(profile, passphrase: passphrase) }
        connecting[profile.id] = task
        defer { connecting[profile.id] = nil }
        return try await task.value
    }

    private func openConnection(_ profile: ServerProfile, passphrase: String?) async throws -> LiveSession {
        guard let ref = key(profile.keyId) else { throw ConnectError.missingKey }
        let secret = try keyStore.load(ref.id)
        let pass = secret.passphrase ?? passphrase
        if ref.hasPassphrase && (pass ?? "").isEmpty { throw ConnectError.needsPassphrase }
        let host = profile.host, port = profile.port, name = profile.name
        let shell: CitadelShell
        do {
            shell = try await CitadelShell.connect(profile: profile, pem: secret.pem, passphrase: pass, kind: ref.kind) { fp in
                await self.verifyHostKey(name: name, host: host, port: port, fingerprint: fp)
            }
        } catch {
            if rejectedChange.remove("\(host):\(port)") != nil { throw ConnectError.hostKeyChanged(host) }
            throw error
        }
        let session = LiveSession(client: HerdrClient(shell: shell, herdrPath: profile.herdrPath, session: profile.session))
        let serverId = profile.id
        session.onTransitions = { [weak self] transitions in self?.showBanner(serverId: serverId, transitions) }
        connections[profile.id] = Connection(shell: shell, session: session)
        await session.start()
        // After a server reboot, background-mode notifications only come back when the app connects.
        Task { try? await NotifyInstaller(shell: shell).start() }
        if let snap = session.snapshot { recordCounts(for: profile.id, snapshot: snap) }
        return session
    }

    // MARK: - Launch

    /// Opens a new herdr workspace in `folder` and starts `kind` there (nil = plain terminal).
    /// Navigates to the new agent, or to the terminal for a plain shell.
    func launch(serverId: UUID, folder: String, kind: String?) async throws {
        guard let profile = server(serverId) else { return }
        let session = try await session(for: profile)
        let client = session.client
        if let kind { try await client.ensureInstalled(kind: kind) }   // fail fast, before creating a workspace
        let label = folder == "/" ? "/" : (folder as NSString).lastPathComponent
        let ws = try await client.createWorkspace(cwd: folder, label: label, focus: kind == nil)
        guard let kind else {
            await session.refresh()
            pendingPath = [.server(serverId), .terminal(server: serverId, target: .session)]
            return
        }
        let taken = Set((try? await client.agents())?.compactMap(\.name) ?? [])
        let name = HerdrClient.agentName(for: folder, existing: taken)
        try await client.startAgent(name: name, kind: kind, paneId: ws.rootPaneId)
        await session.refresh()
        pendingPath = [.server(serverId), .agent(server: serverId, target: name)]
    }

    // MARK: - Banner

    func showBanner(serverId: UUID, _ transitions: [AgentTransition]) {
        let relevant = transitions.filter { !(visibleAgent?.server == serverId && visibleAgent?.target == $0.target) }
        guard let t = relevant.first(where: { $0.to == .blocked }) ?? relevant.first else { return }
        banner = BannerItem(serverId: serverId, serverName: server(serverId)?.name ?? "", transition: t)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func openBanner(_ item: BannerItem) {
        banner = nil
        pendingDeepLink = .agent(server: item.serverId, target: item.transition.target)
    }

    // MARK: - Notifications

    private(set) var notifyConfigs: [UUID: NotifyConfig] = [:]
    private(set) var notifyStatus: [UUID: NotifyStatus] = [:]

    private func installer(_ serverId: UUID) throws -> NotifyInstaller {
        guard let shell = shell(for: serverId), shell.isConnected else { throw HerdrError.transport("Nicht verbunden") }
        return NotifyInstaller(shell: shell)
    }

    @discardableResult
    func loadNotify(_ serverId: UUID) async throws -> (NotifyStatus, NotifyConfig?) {
        let inst = try installer(serverId)
        let st = try await inst.status()
        notifyStatus[serverId] = st
        let cfg = st.installed ? try await inst.readConfig() : nil   // throws if present but unreadable
        notifyConfigs[serverId] = cfg
        return (st, cfg)
    }

    func installNotify(_ serverId: UUID) async throws -> NotifyMode {
        guard let profile = server(serverId), let session = liveSession(for: serverId),
              let socket = await session.client.status?.socket else { throw HerdrError.transport("Nicht verbunden") }
        // Never silently replace an existing topic: the user's ntfy subscription would go quiet.
        let inst = try installer(serverId)
        let existing = try await inst.readConfig()
        var cfg = existing ?? notifyConfigs[serverId] ?? NotifyConfig(ntfyTopic: NotifyConfig.randomTopic(), socket: socket,
                                                                      serverId: serverId, serverName: profile.name)
        cfg.socket = socket
        cfg.serverName = profile.name
        let mode = try await installer(serverId).install(config: cfg)
        notifyConfigs[serverId] = cfg
        try await loadNotify(serverId)
        return mode
    }

    func updateNotify(_ serverId: UUID, _ change: (inout NotifyConfig) -> Void) async throws {
        guard var cfg = notifyConfigs[serverId] else { return }
        let previous = cfg
        change(&cfg)
        guard cfg != previous else { return }
        notifyConfigs[serverId] = cfg   // optimistic; reverted on failure
        do { try await installer(serverId).writeConfig(cfg) }
        catch { notifyConfigs[serverId] = previous; throw error }
    }

    func uninstallNotify(_ serverId: UUID) async throws {
        try await installer(serverId).uninstall()
        notifyConfigs[serverId] = nil
        try await loadNotify(serverId)
    }

    func sendTestNotification(_ serverId: UUID) async throws {
        guard let cfg = notifyConfigs[serverId] else { return }
        try await installer(serverId).sendTest(config: cfg)
    }

    private func verifyHostKey(name: String, host: String, port: Int, fingerprint: String) async -> Bool {
        switch knownHosts.check(host: host, port: port, fingerprint: fingerprint) {
        case .trusted: return true
        case .changed:
            rejectedChange.insert("\(host):\(port)")
            return false
        case .unknown:
            let accepted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                hostKeyPrompt = HostKeyPrompt(serverName: name, host: host, fingerprint: fingerprint) { cont.resume(returning: $0) }
            }
            hostKeyPrompt = nil
            if accepted {
                knownHosts.trust(host: host, port: port, fingerprint: fingerprint)
                try? knownHostsStore.save(knownHosts)
            }
            return accepted
        }
    }
}
