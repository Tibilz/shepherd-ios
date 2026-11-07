import SwiftUI
import UIKit

enum ErrorReport {
    /// User-facing message plus the technical description when it adds information.
    static func text(_ error: Error) -> String {
        let msg = error.localizedDescription
        let detail = String(reflecting: error)
        return msg.contains(detail) ? msg : "\(msg)\n\nDetails: \(detail)"
    }

    /// What "Copy" puts on the clipboard: message + app/iOS version + time, for sending to support.
    static func clipboard(_ text: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "\(text)\n\n— Shepherd \(version), iOS \(UIDevice.current.systemVersion), \(stamp)"
    }

    static func copy(_ text: String) { UIPasteboard.general.string = clipboard(text) }
}

/// Red, selectable error text with a copy button.
struct CopyableError: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).foregroundStyle(.red).font(.footnote).textSelection(.enabled)
            Button {
                ErrorReport.copy(text)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy error", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
        }
    }
}
