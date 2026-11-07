import HerdrKit
import SwiftUI

extension AgentStatus {
    var label: String {
        switch self {
        case .idle: "bereit"
        case .working: "arbeitet"
        case .blocked: "wartet auf dich"
        case .done: "fertig"
        case .unknown: "unbekannt"
        }
    }

    var color: Color {
        switch self {
        case .blocked: .red
        case .done: .green
        case .working: .blue
        case .idle, .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "circle.dotted.circle"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct StatusBadge: View {
    let status: AgentStatus
    var compact = false

    var body: some View {
        Label(compact ? "" : status.label, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, compact ? 4 : 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(status.label)
    }
}
