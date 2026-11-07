import HerdrKit
import HerdrSSH
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalScreen: View {
    let serverId: UUID
    let target: TerminalTarget
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var takeover = false
    @State private var generation = 0

    private var command: String? {
        guard let p = model.server(serverId) else { return nil }
        let herdr = p.herdrPath + (p.session.map { " --session \(ShellQuote.quoteIfNeeded($0))" } ?? "")
        switch target {
        case .agent(let name):
            return SocketCommand.login("\(herdr) agent attach \(ShellQuote.quote(name))" + (takeover ? " --takeover" : ""))
        case .session:
            return SocketCommand.login(herdr)
        }
    }

    var body: some View {
        Group {
            if let shell = model.shell(for: serverId), let command {
                TerminalHost(shell: shell, command: command, onError: { error = $0 })
                    .id(generation)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ContentUnavailableView("Not connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Open the server overview first to connect."))
            }
        }
        .background(Color.black)
        .task(id: model.reconnectToken) {
            guard let p = model.server(serverId), model.shell(for: serverId)?.isConnected != true else { return }
            do { _ = try await model.session(for: p); generation += 1 } catch is CancellationError {} catch { self.error = ErrorReport.text(error) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .agent = target {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Take over (disconnect other clients)") { takeover = true; generation += 1 }
                        Button("Reconnect") { generation += 1 }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .alert("Terminal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Copy") { if let error { ErrorReport.copy(error) } }
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var title: String {
        switch target {
        case .agent(let n): "Terminal · \(n)"
        case .session: "herdr"
        }
    }
}

/// Bridges SwiftTerm's UIKit TerminalView to an SSH PTY.
struct TerminalHost: UIViewRepresentable {
    let shell: CitadelShell
    let command: String
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell, command: command, onError: onError) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bar = TerminalKeyBar(send: { [weak tv] bytes in tv?.send(bytes) })
        tv.inputAccessoryView = bar
        context.coordinator.keyBar = bar
        context.coordinator.attach(tv)
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) { coordinator.close() }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let shell: CitadelShell
        let command: String
        let onError: (String) -> Void
        private var pty: PTYSession?
        private var readTask: Task<Void, Never>?
        private weak var view: TerminalView?
        weak var keyBar: TerminalKeyBar?
        /// Last size reported by SwiftTerm; applied once the PTY is open.
        private var size = (cols: 80, rows: 24)

        init(shell: CitadelShell, command: String, onError: @escaping (String) -> Void) {
            self.shell = shell
            self.command = command
            self.onError = onError
        }

        func attach(_ tv: TerminalView) {
            view = tv
            readTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let pty = try await shell.openPTY(command: command, cols: self.size.cols, rows: self.size.rows)
                    self.pty = pty
                    try? await pty.resize(cols: self.size.cols, rows: self.size.rows)
                    for try await chunk in pty.output {
                        self.view?.feed(byteArray: ArraySlice([UInt8](chunk)))
                    }
                    self.view?.feed(text: "\r\n[Connection closed]\r\n")
                } catch {
                    if !Task.isCancelled { self.onError(ErrorReport.text(error)) }
                }
            }
        }

        func close() {
            readTask?.cancel()
            let pty = self.pty
            Task { await pty?.close() }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var bytes = Data(data)
            Task { @MainActor in
                // A latched Ctrl from the key bar applies to the next single keyboard character.
                if bytes.count == 1, let bar = self.keyBar { bytes = Data([bar.consumeCtrl(bytes[0])]) }
                try? await self.pty?.write(bytes)
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.size = (newCols, newRows)
                try? await self.pty?.resize(cols: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { Task { @MainActor in UIApplication.shared.open(url) } }
        }
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { Task { @MainActor in UIPasteboard.general.string = s } }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
