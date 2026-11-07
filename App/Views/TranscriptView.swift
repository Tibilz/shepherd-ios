import HerdrKit
import SwiftUI

/// Claude Code output as a chat: your messages as bubbles, answers as readable text,
/// tool calls collapsed, timings small. Unknown parts stay visible verbatim.
struct TranscriptView: View {
    let blocks: [TranscriptBlock]
    /// The agent is working: its live spinner line ("Thinking…") is shown as an activity row.
    var working = false

    /// Stable per content, so a saved scroll position still finds its block after new output arrives.
    static func ids(for blocks: [TranscriptBlock]) -> [String] {
        var seen: [Int: Int] = [:]
        return blocks.map { b in
            let h = b.hashValue
            seen[h, default: 0] += 1
            return "\(h)-\(seen[h]!)"
        }
    }

    var body: some View {
        let ids = Self.ids(for: blocks)
        let activity = working ? blocks.lastIndex(where: \.isActivity).flatMap { $0 >= blocks.count - 3 ? $0 : nil } : nil
        // VStack, not Lazy: exact heights, so "scroll to bottom" lands at the real bottom.
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks.indices, id: \.self) { i in
                Group {
                    if i == activity, case .meta(let text) = blocks[i] {
                        WorkingRow(text: text)
                    } else {
                        TranscriptBlockView(block: blocks[i])
                    }
                }
                .id(ids[i])
            }
            if working && activity == nil { WorkingRow(text: nil) }
        }
        .scrollTargetLayout()
        .textSelection(.enabled)
    }
}

/// The agent is busy: spinner plus Claude's status line ("Thinking… (12s · esc to interrupt)").
struct WorkingRow: View {
    let text: String?
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text ?? "Working…").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    @State private var expanded = false

    var body: some View {
        switch block {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(markdown(text))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(let segments):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .prose(let t):
                        Text(markdown(t)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    case .preformatted(let t):
                        Preformatted(text: t)
                    }
                }
            }
        case .tool(let title, let detail):
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: title.hasPrefix("$ ") ? "apple.terminal" : "wrench.and.screwdriver")
                        Text(title).lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if !detail.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(detail.isEmpty)
                if expanded, !detail.isEmpty { Preformatted(text: detail) }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .meta(let text):
            Text(text).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        case .recap(let text):
            Label { Text(markdown(text)) } icon: { Image(systemName: "list.bullet.clipboard") }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case .other(let text):
            Preformatted(text: text)
        }
    }
}

/// Tables and tool output: never wrapped, scroll sideways instead.
private struct Preformatted: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                .padding(8)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Inline markdown (`code`, **bold**, links); line breaks stay as they are.
private func markdown(_ raw: String) -> AttributedString {
    let s = raw.replacingOccurrences(of: #"(?m)^(\s*)[-*] "#, with: "$1• ", options: .regularExpression)
    return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

// MARK: - Renaming chats and terminals

/// What the rename prompt edits: a pane's free-text label (visible in herdr too).
struct RenameItem: Identifiable, Equatable {
    let paneId: String
    let label: String?
    /// Shown as placeholder: what appears when the label is empty.
    let fallback: String
    let isAgent: Bool
    var id: String { paneId }

    init(_ item: ChatItem) {
        paneId = item.paneId
        label = item.agent?.label ?? item.pane.label
        isAgent = item.agent != nil
        fallback = item.agent.map { $0.chatTitle ?? $0.name ?? $0.kindLabel } ?? item.pane.terminalTitleStripped.flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal"
    }

    init(agent: Agent) {
        paneId = agent.paneId
        label = agent.label
        isAgent = true
        fallback = agent.chatTitle ?? agent.name ?? agent.kindLabel
    }
}

extension View {
    /// Presents a rename prompt while `item` is set.
    func renameChat(_ item: Binding<RenameItem?>, session: LiveSession?) -> some View {
        modifier(RenameChat(item: item, session: session))
    }
}

private struct RenameChat: ViewModifier {
    @Binding var item: RenameItem?
    let session: LiveSession?
    @State private var editing: RenameItem?
    @State private var text = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: item) { _, new in
                if let new { editing = new; text = new.label ?? "" }
            }
            .alert(editing?.isAgent == false ? "Rename Terminal" : "Rename Chat",
                   isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } })) {
                TextField(editing?.fallback ?? "Name", text: $text)
                Button("Save") { save(text) }
                if editing?.label != nil { Button("Remove Name", role: .destructive) { save(nil) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave empty to show “\(editing?.fallback ?? "")”. The name also appears in herdr on your desktop.")
            }
            .alert("Rename failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Copy") { if let error { ErrorReport.copy(error) } }
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    private func save(_ label: String?) {
        guard let pane = editing?.paneId, let session else { return }
        Task {
            do {
                try await session.client.renamePane(pane, label: label)
                await session.refresh()
            } catch {
                self.error = ErrorReport.text(error)
            }
        }
    }
}
