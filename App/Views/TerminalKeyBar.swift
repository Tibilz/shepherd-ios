import UIKit

/// Extra keys above the keyboard: Esc, Tab, sticky Ctrl, arrows, | and ~.
final class TerminalKeyBar: UIInputView {
    private let send: ([UInt8]) -> Void
    private var ctrl = false
    private var ctrlButton: UIButton?

    init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let keys: [(String, [UInt8]?)] = [
            ("Esc", [0x1B]), ("Tab", [0x09]), ("Ctrl", nil),
            ("←", [0x1B, 0x5B, 0x44]), ("↑", [0x1B, 0x5B, 0x41]), ("↓", [0x1B, 0x5B, 0x42]), ("→", [0x1B, 0x5B, 0x43]),
            ("|", [0x7C]), ("~", [0x7E]),
        ]
        for (title, bytes) in keys {
            var cfg = UIButton.Configuration.gray()
            cfg.title = title
            cfg.contentInsets = .init(top: 4, leading: 2, bottom: 4, trailing: 2)
            let b = UIButton(configuration: cfg)
            b.accessibilityLabel = title
            if let bytes {
                b.addAction(UIAction { [weak self] _ in self?.press(bytes) }, for: .touchUpInside)
            } else {
                ctrlButton = b
                b.addAction(UIAction { [weak self] _ in self?.toggleCtrl() }, for: .touchUpInside)
            }
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Ctrl applies to the next printable byte from this bar or the keyboard (via ctrlTransform).
    private func press(_ bytes: [UInt8]) {
        if ctrl, bytes.count == 1 { send([Self.ctrlByte(bytes[0])]); setCtrl(false) } else { send(bytes) }
    }

    private func toggleCtrl() { setCtrl(!ctrl) }

    private func setCtrl(_ on: Bool) {
        ctrl = on
        ctrlButton?.configuration?.baseBackgroundColor = on ? .systemBlue : nil
        ctrlButton?.configuration?.baseForegroundColor = on ? .white : nil
    }

    /// Returns the control-transformed byte if Ctrl is latched (and releases it).
    func consumeCtrl(_ byte: UInt8) -> UInt8 {
        guard ctrl else { return byte }
        setCtrl(false)
        return Self.ctrlByte(byte)
    }

    static func ctrlByte(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x61...0x7A: b - 0x60        // a-z
        case 0x40...0x5F: b - 0x40        // @ A-Z [ \ ] ^ _
        default: b
        }
    }
}
