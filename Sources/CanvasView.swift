import AppKit
import QuartzCore

/// Disables every implicit Core Animation action so path updates are instant.
let noActions: [String: CAAction] = [
    "path": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
    "frame": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
    "backgroundColor": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
]

/// One user stroke. Long freehand strokes are split into several CAShapeLayer
/// "chunks" inside `container`, so updating the live path stays O(chunk) instead
/// of O(stroke) on every mouse event.
final class Stroke {
    let container = CALayer()
    let fades: Bool
    let baseOpacity: Float
    var seq = 0
    var isFading = false

    init(fades: Bool, baseOpacity: Float) {
        self.fades = fades
        self.baseOpacity = baseOpacity
        container.actions = noActions
        container.allowsGroupOpacity = true // highlighter chunks don't darken where they overlap
        container.opacity = baseOpacity
    }
}

private final class AnimationDone: NSObject, CAAnimationDelegate {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { block() }
}

/// Layer-hosting view: nothing is ever drawn with drawRect. Strokes are
/// CAShapeLayers rendered by the window server on the GPU, and fading is a
/// Core Animation opacity animation, so the app uses ~0% CPU while ink fades.
final class CanvasView: NSView {
    weak var controller: OverlayController?
    var onContentChange: (() -> Void)?

    private(set) var strokes: [Stroke] = []
    private var redoStack: [Stroke] = []

    private var current: Stroke?
    private var chunk: CAShapeLayer?
    private var path = CGMutablePath()
    private var segmentCount = 0
    private var tool: Tool = .pen
    private var strokeColor = CGColor(gray: 0, alpha: 1)
    private var lineWidth: CGFloat = 5
    private var start = CGPoint.zero
    private var last = CGPoint.zero

    private let boardLayer = CALayer()
    private let inkLayer = CALayer()
    private static let chunkLimit = 256

    var hasContent: Bool { !strokes.isEmpty || current != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.actions = noActions
        layer = root          // layer-hosting: we own the layer tree
        wantsLayer = true
        boardLayer.actions = noActions
        inkLayer.actions = noActions
        root.addSublayer(boardLayer)
        root.addSublayer(inkLayer)
        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        boardLayer.frame = bounds
        inkLayer.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Cursor

    override func resetCursorRects() {
        if let cursor = controller?.cursor { addCursorRect(bounds, cursor: cursor) }
    }

    // MARK: Board

    func setBoard(_ board: Board) {
        switch board {
        case .none: boardLayer.backgroundColor = nil
        case .whiteboard: boardLayer.backgroundColor = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        case .blackboard: boardLayer.backgroundColor = CGColor(srgbRed: 0.10, green: 0.12, blue: 0.13, alpha: 1)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        controller?.strokeWillBegin()

        let settings = Settings.shared
        tool = settings.tool
        lineWidth = tool == .highlighter ? settings.width * 3.5 : settings.width
        strokeColor = settings.color.cgColor

        let stroke = Stroke(fades: settings.fadeEnabled,
                            baseOpacity: tool == .highlighter ? 0.38 : 1)
        stroke.container.frame = bounds
        inkLayer.addSublayer(stroke.container)
        current = stroke

        let p = convert(event.locationInWindow, from: nil)
        start = p
        last = p
        startChunk(at: p)
        if tool.isFreehand {
            path.addLine(to: p) // zero-length segment + round cap = a dot for single clicks
            chunk?.path = path.copy()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        let p = convert(event.locationInWindow, from: nil)

        if tool.isFreehand {
            let dx = p.x - last.x, dy = p.y - last.y
            if dx * dx + dy * dy < 0.8 { return }
            // Quadratic smoothing through midpoints: each event only appends a segment.
            let mid = CGPoint(x: (last.x + p.x) * 0.5, y: (last.y + p.y) * 0.5)
            path.addQuadCurve(to: mid, control: last)
            last = p
            segmentCount += 1
            chunk?.path = path.copy()
            if segmentCount >= Self.chunkLimit { startChunk(at: mid) }
        } else {
            last = p
            chunk?.path = ShapeBuilder.path(tool, from: start, to: p, width: lineWidth,
                                            constrain: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = current else { return }
        let p = convert(event.locationInWindow, from: nil)

        if tool.isFreehand {
            path.addLine(to: p)
            chunk?.path = path.copy()
        } else if hypot(last.x - start.x, last.y - start.y) < 3 {
            // Accidental click with a shape tool: drop it.
            stroke.container.removeFromSuperlayer()
            current = nil
            chunk = nil
            onContentChange?()
            return
        }

        current = nil
        chunk = nil
        strokes.append(stroke)
        controller?.strokeDidEnd(stroke)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.handleScroll(event)
    }

    private func startChunk(at p: CGPoint) {
        let l = CAShapeLayer()
        l.actions = noActions
        l.contentsScale = scale
        l.frame = bounds
        l.fillColor = nil
        l.strokeColor = strokeColor
        l.lineWidth = lineWidth
        l.lineCap = .round
        l.lineJoin = .round
        current?.container.addSublayer(l)
        chunk = l
        path = CGMutablePath()
        path.move(to: p)
        segmentCount = 0
    }

    // MARK: Editing

    /// Cancels an in-progress stroke. Returns true if there was one.
    @discardableResult
    func cancelStroke() -> Bool {
        guard let stroke = current else { return false }
        stroke.container.removeFromSuperlayer()
        current = nil
        chunk = nil
        onContentChange?()
        return true
    }

    func fadeTemporaryStrokes(duration: CFTimeInterval) {
        for stroke in strokes where stroke.fades && !stroke.isFading {
            stroke.isFading = true
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = stroke.container.opacity
            anim.toValue = 0
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            anim.delegate = AnimationDone { [weak self, weak stroke] in
                guard let self, let stroke else { return }
                self.remove(stroke)
            }
            stroke.container.opacity = 0
            stroke.container.add(anim, forKey: "fade")
        }
    }

    private func remove(_ stroke: Stroke) {
        stroke.container.removeFromSuperlayer()
        strokes.removeAll { $0 === stroke }
        onContentChange?()
    }

    var lastUndoableSeq: Int? { strokes.last(where: { !$0.isFading })?.seq }
    var redoTopSeq: Int? { redoStack.last?.seq }

    func undo() {
        guard let i = strokes.lastIndex(where: { !$0.isFading }) else { return }
        let stroke = strokes.remove(at: i)
        stroke.container.removeFromSuperlayer()
        redoStack.append(stroke)
        onContentChange?()
    }

    func redo() -> Stroke? {
        guard let stroke = redoStack.popLast() else { return nil }
        stroke.container.opacity = stroke.baseOpacity
        inkLayer.addSublayer(stroke.container)
        strokes.append(stroke)
        onContentChange?()
        return stroke
    }

    func clearRedo() { redoStack.removeAll() }

    func clear() {
        inkLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokes.removeAll()
        redoStack.removeAll()
        current = nil
        chunk = nil
        onContentChange?()
    }
}

enum ShapeBuilder {
    static func path(_ tool: Tool, from a: CGPoint, to target: CGPoint,
                     width: CGFloat, constrain: Bool) -> CGPath {
        var b = target
        let p = CGMutablePath()
        switch tool {
        case .line, .arrow:
            if constrain { b = snap45(from: a, to: b) }
            p.move(to: a)
            p.addLine(to: b)
            if tool == .arrow {
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 1 else { break }
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = min(max(14, width * 3.2), length * 0.6)
                let spread = CGFloat.pi / 7
                p.move(to: CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread)))
                p.addLine(to: b)
                p.addLine(to: CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread)))
            }
        case .rectangle, .ellipse:
            if constrain {
                let side = max(abs(b.x - a.x), abs(b.y - a.y))
                b = CGPoint(x: a.x + copysign(side, b.x - a.x), y: a.y + copysign(side, b.y - a.y))
            }
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            if tool == .rectangle { p.addRect(r) } else { p.addEllipse(in: r) }
        case .pen, .highlighter:
            break
        }
        return p
    }

    private static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
    }
}

enum CursorFactory {
    static func make(tool: Tool, color: NSColor, width: CGFloat) -> NSCursor {
        guard tool.isFreehand else { return .crosshair }
        let diameter = max(tool == .highlighter ? width * 3.5 : width, 6)
        let size = diameter + 4
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inner = rect.insetBy(dx: 2, dy: 2)
            let shape = tool == .highlighter
                ? NSBezierPath(roundedRect: inner, xRadius: 3, yRadius: 3)
                : NSBezierPath(ovalIn: inner)
            color.withAlphaComponent(tool == .highlighter ? 0.5 : 1).setFill()
            shape.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            shape.lineWidth = 1.2
            shape.stroke()
            let outer = tool == .highlighter
                ? NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
                : NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            NSColor.black.withAlphaComponent(0.45).setStroke()
            outer.lineWidth = 1
            outer.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }
}
