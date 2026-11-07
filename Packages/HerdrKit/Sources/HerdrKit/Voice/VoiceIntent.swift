import Foundation

/// What a spoken instruction means.
public enum VoiceIntent: Equatable, Sendable {
    case navigateAgent(target: String)
    case navigateBack
    case openTerminal
    case approve(keys: [String])
    /// Message to the agent whose screen is open.
    case prompt(text: String)
    /// Message to a specific agent (from the overview).
    case promptAgent(target: String, text: String)
    case shell(command: String, explanation: String, cwd: String?)
    case summarizeAgent(target: String?)
    case summarizeFile(path: String)
    case unknown(question: String)
}

public struct VoiceContext: Sendable {
    /// Agents in display order (HerdrSnapshot.orderedAgents).
    public var agents: [Agent]
    /// The agent whose screen is open, if any.
    public var currentAgent: Agent?
    /// Working directory for shell commands.
    public var cwd: String?
    public init(agents: [Agent], currentAgent: Agent?, cwd: String?) {
        self.agents = agents
        self.currentAgent = currentAgent
        self.cwd = cwd
    }
}
