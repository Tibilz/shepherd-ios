import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case idle, connecting, live, polling, failed(String)
}

/// Keeps a live HerdrSnapshot for one server: event subscription first, polling as fallback.
@MainActor @Observable
public final class LiveSession {
    public let client: HerdrClient
    public private(set) var snapshot: HerdrSnapshot?
    public private(set) var state: ConnectionState = .idle
    /// Called on the main actor with agents that just became blocked or done (never for the first snapshot).
    public var onTransitions: (@MainActor ([AgentTransition]) -> Void)?

    private let pollInterval: Duration
    private let debounce: Duration
    private let liveTimeout: Duration
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    /// Agent panes the current event subscription watches for status changes.
    private var subscribedPanes: Set<String> = []

    public init(client: HerdrClient, pollInterval: Duration = .seconds(3),
                debounce: Duration = .milliseconds(300), liveTimeout: Duration = .seconds(5)) {
        self.client = client
        self.pollInterval = pollInterval
        self.debounce = debounce
        self.liveTimeout = liveTimeout
    }

    public func start() async {
        stop()
        generation += 1
        let gen = generation
        state = .connecting
        do {
            try await client.connect()
            try await loadSnapshot()
        } catch {
            if gen == generation { state = .failed(error.localizedDescription) }
            return
        }
        guard gen == generation else { return }
        startEvents(gen)
    }

    /// Restarts the session if it is stopped or failed; leaves a running one alone.
    public func ensureRunning() async {
        switch state {
        case .idle, .failed: await start()
        case .connecting, .live, .polling: break
        }
    }

    public func stop() {
        generation += 1
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        state = .idle
    }

    public func refresh() async {
        let gen = generation
        do {
            try await loadSnapshot()
            // A transient failure must not leave the banner up once data flows again.
            if gen == generation, case .failed = state {
                state = pollTask != nil ? .polling : (eventTask != nil ? .live : state)
            }
        } catch is CancellationError {
        } catch {
            if gen == generation, state != .idle { state = .failed(error.localizedDescription) }
        }
    }

    private func loadSnapshot() async throws {
        let snap = try await client.snapshot()
        let transitions = AgentTransitions.diff(old: snapshot, new: snap)
        snapshot = snap
        if !transitions.isEmpty { onTransitions?(transitions) }
        // New or vanished agents: resubscribe so their status changes arrive as events.
        if eventTask != nil, pollTask == nil, Set(snap.agents.map(\.paneId)) != subscribedPanes {
            eventTask?.cancel()
            startEvents(generation)
        }
    }

    private func startEvents(_ gen: Int) {
        let panes = Set(snapshot?.agents.map(\.paneId) ?? [])
        subscribedPanes = panes
        let timeout = liveTimeout
        // Falls back to polling if the ack does not arrive in time.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, gen == self.generation, self.state != .live else { return }
            self.startPolling(gen)
        }
        eventTask = Task { [weak self] in
            defer { watchdog.cancel() }
            guard let self else { return }
            do {
                let stream = try await self.client.eventStream(statusPanes: Array(panes))
                for try await ev in stream {
                    guard gen == self.generation else { return }
                    if ev.type == "subscription_started" {
                        if self.state != .polling { self.state = .live }
                    } else {
                        self.scheduleRefresh(gen)
                    }
                }
            } catch {}
            guard !Task.isCancelled, gen == self.generation else { return }
            self.startPolling(gen)
        }
    }

    private func scheduleRefresh(_ gen: Int) {
        guard debounceTask == nil else { return }
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.debounceTask = nil
            await self.refresh()
        }
    }

    private func startPolling(_ gen: Int) {
        guard pollTask == nil, gen == generation else { return }
        eventTask?.cancel(); eventTask = nil
        state = .polling
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, gen == self.generation else { return }
                do {
                    try await self.loadSnapshot()
                    if self.state != .polling { self.state = .polling }
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
