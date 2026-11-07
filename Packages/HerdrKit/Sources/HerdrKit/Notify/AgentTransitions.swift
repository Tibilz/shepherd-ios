import Foundation

public struct AgentTransition: Equatable, Sendable {
    public let target: String
    public let name: String
    public let to: AgentStatus
    public init(target: String, name: String, to: AgentStatus) {
        self.target = target
        self.name = name
        self.to = to
    }
}

/// Foreground counterpart of herdr-notify's Tracker: reports changes *to* blocked or done.
public enum AgentTransitions {
    public static func diff(old: HerdrSnapshot?, new: HerdrSnapshot) -> [AgentTransition] {
        guard let old else { return [] }
        let before = Dictionary(old.agents.map { ($0.target, $0.agentStatus) }, uniquingKeysWith: { a, _ in a })
        return new.orderedAgents.compactMap { a in
            guard a.agentStatus == .blocked || a.agentStatus == .done, before[a.target] != a.agentStatus else { return nil }
            return AgentTransition(target: a.target, name: a.displayName, to: a.agentStatus)
        }
    }
}
