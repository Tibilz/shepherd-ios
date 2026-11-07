import HerdrKit
import SwiftUI

/// Claude Code output as a chat: your messages as bubbles, answers as readable text,
/// tool calls collapsed, timings small. Unknown parts stay visible verbatim.
struct TranscriptView: View {
    let blocks: [TranscriptBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                TranscriptBlockView(block: block)
            }
        }
        .textSelection(.enabled)
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

// MARK: - Renaming chats

extension View {
    /// Presents a rename prompt while `agent` is set. Saves to the pane label (free text, visible in herdr too).
    func renameChat(_ agent: Binding<Agent?>, session: LiveSession?) -> some View {
        modifier(RenameChat(agent: agent, session: session))
    }
}

private struct RenameChat: ViewModifier {
    @Binding var agent: Agent?
    let session: LiveSession?
    @State private var editing: Agent?
    @State private var text = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: agent?.paneId) { _, _ in
                if let agent { editing = agent; text = agent.label ?? "" }
            }
            .alert("Rename Chat", isPresented: Binding(get: { agent != nil }, set: { if !$0 { agent = nil } })) {
                TextField(editing?.chatTitle ?? editing?.displayName ?? "Name", text: $text)
                Button("Save") { save(text) }
                if editing?.label != nil { Button("Remove Name", role: .destructive) { save(nil) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave empty to show the title from \(editing?.kindLabel ?? "Claude"). The name also appears in herdr on your desktop.")
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
