import AppKit
import Carbon.HIToolbox

/// Transparent, borderless, click-through window covering one screen.
final class OverlayWindow: NSWindow {
    let canvas: CanvasView
    weak var controller: OverlayController?

    init(screen: NSScreen, controller: OverlayController) {
        canvas = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.controller = controller
        canvas.controller = controller
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        // Swallow keys while drawing (no beeps); pass through otherwise.
        if controller?.handleKey(event) != true, controller?.isDrawing != true {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), controller?.handleKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class OverlayController {
    enum Mode { case off, drawing, pointer }

    /// `.pointer` = "mouse mode": ink and toolbar stay on screen, clicks go to the apps below.
    private(set) var mode: Mode = .off
    var isDrawing: Bool { mode == .drawing }
    private(set) var cursor: NSCursor = .crosshair
    var onModeChanged: ((Mode) -> Void)?

    private var windows: [OverlayWindow] = []
    private lazy var toolbar = ToolbarPanel(controller: self)
    private var fadeWork: DispatchWorkItem?
    /// Last app other than Scrawl that was active, kept up to date by an
    /// NSWorkspace notification (event-driven, no polling).
    private var previousApp: NSRunningApplication? = {
        let front = NSWorkspace.shared.frontmostApplication
        return front == NSRunningApplication.current ? nil : front
    }()
    private var seqCounter = 0
    private var board: Board = .none
    private var scrollAccumulator: CGFloat = 0

    static let fadeDuration: CFTimeInterval = 0.45

    init() {
        rebuildWindows()
        refreshCursor()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        nc.addObserver(forName: .scrawlSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != NSRunningApplication.current else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
        // If the user Cmd-Tabs away while drawing, get out of the way.
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDrawing else { return }
                self.setMode(.off, restoreFocus: false)
            }
        }
    }

    // MARK: Windows

    private func rebuildWindows() {
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen, controller: self)
            w.canvas.onContentChange = { [weak self] in self?.updateVisibility() }
            w.canvas.setBoard(board)
            if isDrawing { w.ignoresMouseEvents = false }
            return w
        }
        updateVisibility()
        if isDrawing { focusWindowUnderMouse() }
    }

    /// Windows are ordered out entirely when there is nothing to show, so an idle
    /// Scrawl costs the window server nothing.
    private func updateVisibility() {
        for w in windows {
            let needed = isDrawing || board != .none || w.canvas.hasContent
            if needed, !w.isVisible { w.orderFrontRegardless() }
            if !needed, w.isVisible { w.orderOut(nil) }
        }
    }

    private func windowUnderMouse() -> OverlayWindow? {
        let p = NSEvent.mouseLocation
        return windows.first { NSMouseInRect(p, $0.frame, false) } ?? windows.first
    }

    private func focusWindowUnderMouse() {
        guard let w = windowUnderMouse() else { return }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.canvas)
    }

    // MARK: Mode

    /// Global shortcut: drawing → off; off or mouse mode → drawing.
    func toggle() { setMode(mode == .drawing ? .off : .drawing) }
    func setDrawing(_ on: Bool) { setMode(on ? .drawing : .off) }
    func togglePointer() { setMode(mode == .pointer ? .drawing : .pointer) }

    func setMode(_ new: Mode, restoreFocus: Bool = true) {
        let old = mode
        guard new != old else { return }
        mode = new

        switch new {
        case .drawing:
            for w in windows {
                w.ignoresMouseEvents = false
                w.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            focusWindowUnderMouse()
            if Settings.shared.showToolbar, let screen = windowUnderMouse()?.screen {
                toolbar.show(on: screen)
            }
            refreshCursor()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isDrawing else { return }
                self.cursor.set()
            }
            // macOS 14+ may decline activation once; retry so Esc and keys work.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.isDrawing, !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.focusWindowUnderMouse()
                self.cursor.set()
            }

        case .pointer, .off:
            for w in windows {
                w.canvas.cancelStroke()
                w.ignoresMouseEvents = true
            }
            setBoard(.none)
            if new == .off {
                toolbar.hide()
                if Settings.shared.clearOnExit { clearAll() }
            } else if Settings.shared.showToolbar, let screen = NSScreen.withMouse {
                toolbar.show(on: screen)
            }
            updateVisibility()
            if old == .drawing { NSCursor.arrow.set() }
            // Hand focus back to the app the user was in (also covers being
            // activated by a scrawl:// URL).
            if restoreFocus, NSApp.isActive {
                if let app = previousApp, !app.isTerminated {
                    app.activate(options: [])
                } else {
                    NSApp.deactivate()
                }
            }
            if new == .pointer { Toast.shared.show("Mouse mode: pick a pen to draw again") }
        }
        toolbar.refresh()
        onModeChanged?(new)
    }

    // MARK: Strokes

    func strokeWillBegin() {
        fadeWork?.cancel()
        fadeWork = nil
    }

    func strokeDidEnd(_ stroke: Stroke) {
        seqCounter += 1
        stroke.seq = seqCounter
        for w in windows { w.canvas.clearRedo() }
        if stroke.fades { scheduleFade() }
    }

    /// Temporary ink fades together a short while after the *last* stroke,
    /// so you can write a whole word before it disappears.
    private func scheduleFade() {
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for w in self.windows { w.canvas.fadeTemporaryStrokes(duration: Self.fadeDuration) }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.fadeDelay, execute: work)
    }

    func undo() {
        let target = windows
            .compactMap { w in w.canvas.lastUndoableSeq.map { (w.canvas, $0) } }
            .max { $0.1 < $1.1 }
        target?.0.undo()
    }

    func redo() {
        let target = windows
            .compactMap { w in w.canvas.redoTopSeq.map { (w.canvas, $0) } }
            .min { $0.1 < $1.1 }
        if let stroke = target?.0.redo(), stroke.fades { scheduleFade() }
    }

    func clearAll() {
        fadeWork?.cancel()
        fadeWork = nil
        for w in windows { w.canvas.clear() }
    }

    // MARK: Board

    func toggleBoard(_ b: Board) {
        let newBoard: Board = board == b ? .none : b
        setBoard(newBoard)
        // Keep the ink visible on the new background.
        let s = Settings.shared
        if newBoard == .whiteboard, s.colorIndex == Palette.whiteIndex { s.colorIndex = Palette.blackIndex }
        if newBoard == .blackboard, s.colorIndex == Palette.blackIndex { s.colorIndex = Palette.whiteIndex }
    }

    private func setBoard(_ b: Board) {
        guard b != board else { return }
        board = b
        for w in windows { w.canvas.setBoard(b) }
        updateVisibility()
    }

    // MARK: Settings / cursor

    private func settingsChanged() {
        refreshCursor()
        toolbar.refresh()
        if mode != .off {
            let wantToolbar = Settings.shared.showToolbar
            if wantToolbar, !toolbar.isVisible, let screen = windowUnderMouse()?.screen {
                toolbar.show(on: screen)
            } else if !wantToolbar {
                toolbar.hide()
            }
        }
    }

    private func refreshCursor() {
        let s = Settings.shared
        cursor = CursorFactory.make(tool: s.tool, color: s.color, width: s.width)
        for w in windows { w.invalidateCursorRects(for: w.canvas) }
        if isDrawing { cursor.set() }
    }

    func changeWidth(by delta: CGFloat) {
        let s = Settings.shared
        s.width = (s.width + delta).rounded()
        Toast.shared.show("Size \(Int(s.width))")
    }

    func handleScroll(_ event: NSEvent) {
        guard isDrawing else { return }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        var steps: CGFloat = 0
        while scrollAccumulator >= 1 { steps += 1; scrollAccumulator -= 1 }
        while scrollAccumulator <= -1 { steps -= 1; scrollAccumulator += 1 }
        if steps != 0 { changeWidth(by: steps) }
    }

    // MARK: Keyboard (only while drawing)

    func handleKey(_ event: NSEvent) -> Bool {
        guard isDrawing else { return false }
        let s = Settings.shared
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)

        if code == kVK_Escape {
            if !windows.contains(where: { $0.canvas.cancelStroke() }) { setDrawing(false) }
            return true
        }
        if flags.contains(.command) {
            if chars == "z" {
                flags.contains(.shift) ? redo() : undo()
                return true
            }
            return false
        }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            clearAll()
            return true
        }
        if code == kVK_ANSI_LeftBracket || code == kVK_ANSI_Minus || chars == "[" || chars == "-" {
            changeWidth(by: s.width > 10 ? -2 : -1)
            return true
        }
        if code == kVK_ANSI_RightBracket || code == kVK_ANSI_Equal || chars == "]" || chars == "=" || chars == "+" {
            changeWidth(by: s.width >= 10 ? 2 : 1)
            return true
        }
        if let n = Int(chars), (1...Palette.colors.count).contains(n) {
            s.colorIndex = n - 1
            Toast.shared.show(Palette.names[n - 1])
            return true
        }
        if let tool = Tool.allCases.first(where: { $0.key == chars }) {
            s.tool = tool
            Toast.shared.show(tool.title)
            return true
        }
        switch chars {
        case "f":
            s.fadeEnabled.toggle()
            Toast.shared.show(s.fadeEnabled ? "Auto-fade on" : "Auto-fade off (ink stays)")
        case "c": clearAll()
        case "z": undo()
        case "w": toggleBoard(.whiteboard)
        case "b": toggleBoard(.blackboard)
        case "t": s.showToolbar.toggle()
        case "m", "v": setMode(.pointer)
        default: break
        }
        return true
    }
}
