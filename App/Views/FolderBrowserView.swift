import HerdrKit
import SwiftUI

/// Files-app-like browser of the server's folders, with "start an agent here" at the bottom.
struct FolderBrowserView: View {
    let serverId: UUID
    let path: String?
    @Environment(AppModel.self) private var model
    @AppStorage("showHiddenFolders") private var showHidden = false
    @State private var listing: DirListing?
    @State private var error: String?
    @State private var launching: String?
    @State private var askNewFolder = false
    @State private var newFolderName = ""
    @State private var openFolder: String?

    private var shown: [DirEntry] { (listing?.entries ?? []).filter { showHidden || !$0.isHidden } }
    private var title: String {
        guard let p = listing?.path else { return path.map { ($0 as NSString).lastPathComponent } ?? "Home" }
        return p == "/" ? "/" : (p as NSString).lastPathComponent
    }

    var body: some View {
        List {
            if let p = listing?.path {
                Section { Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let error { Section { CopyableError(text: error) } }
            Section {
                ForEach(shown) { e in
                    if e.isDirectory {
                        NavigationLink(value: Route.folder(server: serverId, path: e.path)) {
                            Label(e.name, systemImage: "folder.fill").foregroundStyle(e.isHidden ? .secondary : .primary)
                        }
                    } else {
                        Label(e.name, systemImage: "doc").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if let l = listing, shown.isEmpty {
                    Text(l.entries.isEmpty ? "This folder is empty." : "Only hidden items.")
                }
            }
        }
        .overlay { if listing == nil && error == nil { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newFolderName = ""; askNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(listing == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu {
                        ForEach(HerdrClient.agentKinds.filter { $0.kind != "claude" && $0.kind != "codex" }, id: \.kind) { k in
                            Button(k.label) { launch(kind: k.kind) }
                        }
                    } label: { Label("Start Another Agent Here", systemImage: "sparkles.rectangle.stack") }
                    Toggle("Show Hidden Folders", isOn: $showHidden)
                    if let p = listing?.path, let parent = RemoteFiles.parent(of: p) {
                        NavigationLink(value: Route.folder(server: serverId, path: parent)) {
                            Label("Parent Folder", systemImage: "arrow.up.doc")
                        }
                    }
                    NavigationLink(value: Route.folder(server: serverId, path: nil)) { Label("Home", systemImage: "house") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { launchBar }
        .alert("New Folder", isPresented: $askNewFolder) {
            TextField("Name", text: $newFolderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("in \(listing?.path ?? "")")
        }
        .navigationDestination(item: $openFolder) { FolderBrowserView(serverId: serverId, path: $0) }
        .refreshable { await load() }
        .task(id: model.reconnectToken) { await load() }
        .disabled(launching != nil)
    }

    private var launchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { launch(kind: "claude") } label: {
                    Group {
                        if launching == "claude" { ProgressView() } else { Label("Claude Code", systemImage: "sparkles") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { launch(kind: "codex") } label: {
                    Group {
                        if launching == "codex" { ProgressView() } else { Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .lineLimit(1)
            Button { launch(kind: nil) } label: {
                Label("Terminal Only", systemImage: "apple.terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if let launching, launching != "claude", launching != "codex" {
                HStack { ProgressView(); Text("Starting …").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .disabled(listing == nil)
    }

    private func load() async {
        guard let profile = model.server(serverId) else { return }
        do {
            _ = try await model.session(for: profile)
            guard let shell = model.shell(for: serverId) else { return }
            listing = try await RemoteFiles(shell: shell).list(path)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ErrorReport.text(error)
        }
    }

    private func createFolder() {
        guard let dir = listing?.path, let shell = model.shell(for: serverId) else { return }
        let name = newFolderName
        Task {
            do {
                let created = try await RemoteFiles(shell: shell).makeDirectory(in: dir, named: name)
                await load()
                openFolder = created
            } catch {
                self.error = ErrorReport.text(error)
            }
        }
    }

    private func launch(kind: String?) {
        guard let dir = listing?.path else { return }
        launching = kind ?? "terminal"
        Task {
            defer { launching = nil }
            do { try await model.launch(serverId: serverId, folder: dir, kind: kind) }
            catch { self.error = ErrorReport.text(error) }
        }
    }
}
