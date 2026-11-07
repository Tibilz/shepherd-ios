import SwiftUI
import UIKit

/// Multi-line editor for a private key. Plain UITextView so smart dashes/quotes, autocorrect and
/// capitalization can be switched off (SwiftUI's TextEditor can't turn off smart dashes, which would
/// turn "-----BEGIN" into em dashes). AutoFill from password managers (long-press → AutoFill) still works.
struct KeyTextView: UIViewRepresentable {
    @Binding var text: String
    /// Hides the characters (like a password field); caret and editing keep working.
    var masked = false

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.spellCheckingType = .no
        v.smartDashesType = .no
        v.smartQuotesType = .no
        v.smartInsertDeleteType = .no
        v.keyboardType = .asciiCapable
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        v.accessibilityLabel = "Private Key"
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
        v.textColor = masked ? .clear : .label
        v.tintColor = .tintColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ v: UITextView) { text.wrappedValue = v.text }
    }
}
