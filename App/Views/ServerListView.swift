import HerdrKit
import SwiftUI

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerProfile?
    @State private var creating = false
    @State private var showKeys = false
    @State private var showSettings = false

    var body: some View {
        List {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers Yet", systemImage: "server.rack")
                } description: {
                    Text(model.keys.isEmpty
                         ? "Import an SSH key first, for example from your password manager, then add a server."
                         : "Add your first herdr server.")
                } actions: {
                    if model.keys.isEmpty {
                        Button("Import SSH Key") { showKeys = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Add Server") { creating = true }.buttonStyle(.borderedProminent)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(model.servers) { server in
                NavigationLink(value: Route.server(server.id)) {
                    ServerRow(server: server, connected: model.shell(for: server.id)?.isConnected == true)
                }
                .swipeActions {
                    Button("Edit") { editing = server }.tint(.blue)
                }
            }
        }
        .navigationTitle("Server")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showKeys = true } label: { Label("SSH Keys", systemImage: "key") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Label("Add Server", systemImage: "plus") }
                    .disabled(model.keys.isEmpty)
            }
        }
        .sheet(isPresented: $creating) { ServerEditView(original: nil) }
        .sheet(item: $editing) { ServerEditView(original: $0) }
        .sheet(isPresented: $showKeys) { NavigationStack { KeyListView() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct ServerRow: View {
    let server: ServerProfile
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.name).font(.headline)
                if connected {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                        .accessibilityLabel("connected")
                }
                if server.requiresVPN {
                    Image(systemName: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("requires VPN")
                }
            }
            Text("\(server.user)@\(server.host)").font(.caption).foregroundStyle(.secondary)
            let counts = server.lastKnownCounts
            if !counts.isEmpty {
                HStack(spacing: 6) {
                    ForEach([AgentStatus.blocked, .done, .working, .idle], id: \.self) { s in
                        if let n = counts[s], n > 0 {
                            Label("\(n)", systemImage: s.symbol).font(.caption2).foregroundStyle(s.color)
                        }
                    }
                    Text("last known").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
