import HerdrKit
import SwiftUI

@main
struct HerdrApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.pendingDeepLink = DeepLink(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}

enum Route: Hashable {
    case server(UUID)
    case agent(server: UUID, target: String)
    case terminal(server: UUID, target: TerminalTarget)
    case notifications(server: UUID)
    case folder(server: UUID, path: String?)
}

enum TerminalTarget: Hashable {
    case agent(String)
    case session
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []

    var body: some View {
        Group {
            if model.lock.isLocked {
                LockView()
            } else {
                NavigationStack(path: $path) {
                    ServerListView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .server(let id): ServerOverviewView(serverId: id)
                            case .agent(let id, let target): AgentDetailView(serverId: id, target: target)
                            case .terminal(let id, let target): TerminalScreen(serverId: id, target: target)
                            case .notifications(let id): NotificationsView(serverId: id)
                            case .folder(let id, let p): FolderBrowserView(serverId: id, path: p)
                            }
                        }
                }
            }
        }
        .overlay(alignment: .top) {
            if let item = model.banner, !model.lock.isLocked {
                StatusBanner(item: item, open: { model.openBanner(item) }, dismiss: { model.banner = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
            }
        }
        .animation(.spring(duration: 0.3), value: model.banner)
        .sheet(item: Binding(get: { model.hostKeyPrompt }, set: { _ in })) { prompt in
            HostKeyPromptView(prompt: prompt).interactiveDismissDisabled()
        }
        .onChange(of: model.pendingDeepLink) { _, link in openDeepLink(link) }
        .onChange(of: model.pendingPath) { _, routes in
            guard let routes, !model.lock.isLocked else { return }
            model.pendingPath = nil
            path = routes
        }
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked { path = [] } else { openDeepLink(model.pendingDeepLink) }
        }
    }

    private func openDeepLink(_ link: DeepLink?) {
        guard let link, !model.lock.isLocked else { return }
        model.pendingDeepLink = nil
        switch link {
        case .server(let id):
            guard model.server(id) != nil else { return }
            path = [.server(id)]
        case .agent(let id, let target):
            guard model.server(id) != nil else { return }
            path = [.server(id), .agent(server: id, target: target)]
        }
    }
}
