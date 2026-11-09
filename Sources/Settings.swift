import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let scrawlSettingsChanged = Notification.Name("ScrawlSettingsChanged")
}

enum Tool: String, CaseIterable {
    case pen, highlighter, line, arrow, rectangle, ellipse

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }

    /// Single-letter shortcut used while drawing.
    var key: String {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        }
    }

    var isFreehand: Bool { self == .pen || self == .highlighter }
}

enum Board: Equatable {
    case none, whiteboard, blackboard
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1), // black
    ]
    static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White", "Black"]
    static let whiteIndex = 6
    static let blackIndex = 7
}

struct ShortcutPreset {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let flags: NSEvent.ModifierFlags
    let key: String
    let symbols: String

    var display: String { symbols + key.uppercased() }
    /// The global "clear" shortcut uses the same modifiers with C.
    var clearDisplay: String { symbols + "C" }

    static let all: [ShortcutPreset] = [
        ShortcutPreset(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | shiftKey),
                       flags: [.control, .shift], key: "d", symbols: "⌃⇧"),
        ShortcutPreset(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey | shiftKey),
                       flags: [.option, .shift], key: "d", symbols: "⌥⇧"),
        ShortcutPreset(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
                       flags: [.control, .option, .command], key: "d", symbols: "⌃⌥⌘"),
        ShortcutPreset(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | shiftKey),
                       flags: [.control, .shift], key: "a", symbols: "⌃⇧"),
    ]
}

/// UserDefaults-backed preferences. Every write broadcasts `.scrawlSettingsChanged`.
@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "colorIndex": 0,
            "tool": Tool.pen.rawValue,
            "width": 5.0,
            "fadeEnabled": true,
            "fadeDelay": 1.5,
            "shortcutIndex": 0,
            "showToolbar": true,
            "clearOnExit": false,
            "hasLaunchedBefore": false,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: .scrawlSettingsChanged, object: nil)
    }

    var colorIndex: Int {
        get { min(max(d.integer(forKey: "colorIndex"), 0), Palette.colors.count - 1) }
        set { d.set(newValue, forKey: "colorIndex"); changed() }
    }

    var color: NSColor { Palette.colors[colorIndex] }

    var tool: Tool {
        get { Tool(rawValue: d.string(forKey: "tool") ?? "") ?? .pen }
        set { d.set(newValue.rawValue, forKey: "tool"); changed() }
    }

    var width: CGFloat {
        get { CGFloat(min(max(d.double(forKey: "width"), 1), 40)) }
        set { d.set(Double(min(max(newValue, 1), 40)), forKey: "width"); changed() }
    }

    var fadeEnabled: Bool {
        get { d.bool(forKey: "fadeEnabled") }
        set { d.set(newValue, forKey: "fadeEnabled"); changed() }
    }

    var fadeDelay: Double {
        get { max(d.double(forKey: "fadeDelay"), 0.3) }
        set { d.set(newValue, forKey: "fadeDelay"); changed() }
    }

    var shortcutIndex: Int {
        get { min(max(d.integer(forKey: "shortcutIndex"), 0), ShortcutPreset.all.count - 1) }
        set { d.set(newValue, forKey: "shortcutIndex"); changed() }
    }

    var shortcut: ShortcutPreset { ShortcutPreset.all[shortcutIndex] }

    var showToolbar: Bool {
        get { d.bool(forKey: "showToolbar") }
        set { d.set(newValue, forKey: "showToolbar"); changed() }
    }

    var clearOnExit: Bool {
        get { d.bool(forKey: "clearOnExit") }
        set { d.set(newValue, forKey: "clearOnExit"); changed() }
    }

    var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "hasLaunchedBefore") }
        set { d.set(newValue, forKey: "hasLaunchedBefore") }
    }
}

extension NSScreen {
    static var withMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}
