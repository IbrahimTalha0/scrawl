import AppKit

private final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class SwatchView: NSView {
    let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        color.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
            NSColor.white.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

private final class SizeDotView: NSView {
    let width: CGFloat
    let diameter: CGFloat
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(width: CGFloat, diameter: CGFloat) {
        self.width = width
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let r = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        NSColor.white.withAlphaComponent(isSelected ? 1 : 0.7).setFill()
        NSBezierPath(ovalIn: r).fill()
    }
}

/// Small floating palette shown while drawing. It never becomes key, so the
/// keyboard shortcuts keep going to the canvas.
final class ToolbarPanel: NSPanel {
    private weak var controller: OverlayController?
    private var swatches: [SwatchView] = []
    private var toolButtons: [Tool: NSButton] = [:]
    private var sizeDots: [SizeDotView] = []
    private var fadeButton: NSButton!
    private var pointerButton: NSButton!
    private static let originKey = "toolbarOrigin"

    init(controller: OverlayController) {
        self.controller = controller
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        buildContent()
        refresh()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func buildContent() {
        let effect = DraggableEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, color) in Palette.colors.enumerated() {
            let v = SwatchView(color: color)
            v.toolTip = "\(Palette.names[i]) (\(i + 1))"
            v.onClick = { [weak self] in
                Settings.shared.colorIndex = i
                self?.controller?.setDrawing(true)
            }
            swatches.append(v)
            stack.addArrangedSubview(v)
        }
        stack.addArrangedSubview(separator())

        pointerButton = iconButton("cursorarrow", tip: "Mouse: click through, keep the ink (M)", action: #selector(pointerTapped))
        stack.addArrangedSubview(pointerButton)
        for (i, tool) in Tool.allCases.enumerated() {
            let b = iconButton(tool.symbol, tip: "\(tool.title) (\(tool.key.uppercased()))", action: #selector(toolTapped(_:)))
            b.tag = i
            toolButtons[tool] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(separator())

        for (width, diameter) in [(CGFloat(3), CGFloat(4)), (6, 7), (12, 11)] {
            let v = SizeDotView(width: width, diameter: diameter)
            v.toolTip = "Stroke size ([ and ], or scroll)"
            v.onClick = { [weak self] in
                Settings.shared.width = width
                self?.controller?.setDrawing(true)
            }
            sizeDots.append(v)
            stack.addArrangedSubview(v)
        }
        stack.addArrangedSubview(separator())

        fadeButton = iconButton("hourglass", tip: "Auto-fade ink (F)", action: #selector(fadeTapped))
        stack.addArrangedSubview(fadeButton)
        stack.addArrangedSubview(iconButton("arrow.uturn.backward", tip: "Undo (⌘Z)", action: #selector(undoTapped)))
        stack.addArrangedSubview(iconButton("trash", tip: "Clear all (C / Delete)", action: #selector(clearTapped)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(iconButton("xmark", tip: "Stop drawing (Esc)", action: #selector(closeTapped)))

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        setContentSize(stack.fittingSize)
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 18),
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 9),
            wrap.heightAnchor.constraint(equalToConstant: 28),
            v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.contentTintColor = .white
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 28),
            b.heightAnchor.constraint(equalToConstant: 28),
        ])
        return b
    }

    func refresh() {
        let s = Settings.shared
        for (i, v) in swatches.enumerated() { v.isSelected = i == s.colorIndex }
        let pointer = controller?.mode == .pointer
        func mark(_ b: NSButton, _ selected: Bool) {
            b.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.18).cgColor : nil
            b.contentTintColor = selected ? .white : NSColor.white.withAlphaComponent(0.7)
        }
        mark(pointerButton, pointer)
        for (tool, b) in toolButtons { mark(b, !pointer && tool == s.tool) }
        let nearest = sizeDots.min { abs($0.width - s.width) < abs($1.width - s.width) }
        for v in sizeDots { v.isSelected = v === nearest && abs(v.width - s.width) < 2 }
        fadeButton.layer?.backgroundColor = s.fadeEnabled ? NSColor.systemYellow.withAlphaComponent(0.25).cgColor : nil
        fadeButton.contentTintColor = s.fadeEnabled ? .systemYellow : NSColor.white.withAlphaComponent(0.7)
    }

    func show(on screen: NSScreen) {
        refresh()
        if isVisible { return } // keep wherever the user dragged it
        let size = frame.size
        let vf = screen.visibleFrame
        var origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 10)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            if vf.contains(NSRect(origin: p, size: size)) { origin = p }
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func hide() {
        guard isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
        orderOut(nil)
    }

    @objc private func pointerTapped() { controller?.togglePointer() }
    @objc private func toolTapped(_ sender: NSButton) {
        Settings.shared.tool = Tool.allCases[sender.tag]
        controller?.setDrawing(true)
    }
    @objc private func fadeTapped() { Settings.shared.fadeEnabled.toggle() }
    @objc private func undoTapped() { controller?.undo() }
    @objc private func clearTapped() { controller?.clearAll() }
    @objc private func closeTapped() { controller?.setDrawing(false) }
}

/// Tiny transient HUD message ("Highlighter", "Size 8", ...).
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    func show(_ text: String, duration: TimeInterval = 1.0) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        let size = label.fittingSize
        let w = ceil(size.width) + 32, h = ceil(size.height) + 16
        let vf = (NSScreen.withMouse ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.minY + 64, width: w, height: h), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, gen == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if gen == self.generation { panel.orderOut(nil) }
                }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        p.contentView = effect
        panel = p
        return p
    }
}
