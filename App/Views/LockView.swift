import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("herdr").font(.largeTitle.bold())
            Text("Unlock the app to use your SSH keys.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let err = model.lock.lastError {
                CopyableError(text: err)
            }
            Spacer()
            Button {
                Task { await model.lock.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .task { await model.lock.unlock() }
    }
}
