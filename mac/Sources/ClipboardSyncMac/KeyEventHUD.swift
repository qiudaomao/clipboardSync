import AppKit

/// Debug overlay listing every key event input sharing sends, receives, and injects, so a
/// keyboard mismatch between devices (stuck modifier, wrong case, missing key) can be read off
/// the screen while it happens. Off by default and never persisted: it displays every keystroke,
/// passwords included. Click-through and non-activating, so it never steals focus or input.
final class KeyEventHUD {
    enum Direction {
        case sent
        case received
        case injected

        var glyph: String {
            switch self {
            case .sent: return "→ SEND"
            case .received: return "← RECV"
            case .injected: return "  ⇢ INJ"
            }
        }

        var color: NSColor {
            switch self {
            case .sent: return .systemOrange
            case .received: return .systemTeal
            case .injected: return .systemGreen
            }
        }
    }

    private static let maxLines = 18
    private static let width: CGFloat = 520
    private static let margin: CGFloat = 16

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var lines: [NSAttributedString] = []
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        label.maximumNumberOfLines = Self.maxLines + 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        panel.contentView = background
        lines = [Self.headerLine()]
        render()
    }

    func show() {
        render()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        lines = [Self.headerLine()]
    }

    /// Main thread only.
    func record(_ direction: Direction, _ detail: String) {
        let line = NSMutableAttributedString(
            string: timeFormatter.string(from: Date()) + "  ",
            attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        line.append(NSAttributedString(
            string: direction.glyph + "  ",
            attributes: [.font: Self.boldFont, .foregroundColor: direction.color]
        ))
        line.append(NSAttributedString(
            string: detail,
            attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor]
        ))
        lines.append(line)
        if lines.count > Self.maxLines + 1 {
            lines.removeSubrange(1..<(lines.count - Self.maxLines))
        }
        if panel.isVisible {
            render()
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    private static func headerLine() -> NSAttributedString {
        NSAttributedString(
            string: AppText.text("hud.keyEvents.title"),
            attributes: [.font: boldFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
    }

    private func render() {
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "\n"))
            }
            text.append(line)
        }
        label.attributedStringValue = text
        let height = ceil(label.intrinsicContentSize.height) + 20
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(
            x: screen.maxX - Self.width - Self.margin,
            y: screen.minY + Self.margin,
            width: Self.width,
            height: height
        ), display: true)
    }
}
