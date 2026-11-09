import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController()
        overlay.onDrawingChanged = { [weak self] _ in self?.updateStatusIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        registerHotKeys()

        if !Settings.shared.hasLaunchedBefore {
            Settings.shared.hasLaunchedBefore = true
            Toast.shared.show("Scrawl is in your menu bar — press \(Settings.shared.shortcut.display) to draw", duration: 4)
        }
    }

    // MARK: URL scheme: scrawl://toggle | start | stop | clear | undo

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "scrawl" {
            switch (url.host ?? "").lowercased() {
            case "toggle": overlay.toggle()
            case "start", "on": overlay.setDrawing(true)
            case "stop", "off": overlay.setDrawing(false)
            case "clear": overlay.clearAll()
            case "undo": overlay.undo()
            default: break
            }
        }
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let preset = Settings.shared.shortcut
        let okToggle = center.register(keyCode: preset.keyCode, modifiers: preset.carbonModifiers) { [weak self] in
            self?.overlay.toggle()
        }
        center.register(keyCode: UInt32(kVK_ANSI_C), modifiers: preset.carbonModifiers) { [weak self] in
            self?.overlay.clearAll()
        }
        if !okToggle {
            Toast.shared.show("\(preset.display) is used by another app — pick another shortcut in the menu", duration: 4)
        }
    }

    // MARK: Status item

    private func updateStatusIcon() {
        let name = overlay.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Scrawl")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Scrawl — \(Settings.shared.shortcut.display) to draw"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared
        let preset = s.shortcut

        let toggle = item(overlay.isDrawing ? "Stop Drawing" : "Start Drawing", #selector(toggleDrawing))
        toggle.keyEquivalent = preset.key
        toggle.keyEquivalentModifierMask = preset.flags
        menu.addItem(toggle)

        let clear = item("Clear Drawings", #selector(clearAll))
        clear.keyEquivalent = "c"
        clear.keyEquivalentModifierMask = preset.flags
        menu.addItem(clear)
        menu.addItem(.separator())

        let toolMenu = NSMenu()
        for (i, tool) in Tool.allCases.enumerated() {
            let t = item(tool.title, #selector(selectTool(_:)))
            t.tag = i
            t.state = tool == s.tool ? .on : .off
            t.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            toolMenu.addItem(t)
        }
        menu.addItem(submenu("Tool", toolMenu))

        let colorMenu = NSMenu()
        for (i, name) in Palette.names.enumerated() {
            let c = item(name, #selector(selectColor(_:)))
            c.tag = i
            c.state = i == s.colorIndex ? .on : .off
            c.image = swatchImage(Palette.colors[i])
            colorMenu.addItem(c)
        }
        menu.addItem(submenu("Color", colorMenu))
        menu.addItem(.separator())

        let fade = item("Auto-Fade Ink", #selector(toggleFade))
        fade.state = s.fadeEnabled ? .on : .off
        menu.addItem(fade)

        let delayMenu = NSMenu()
        for (i, delay) in [0.75, 1.0, 1.5, 2.0, 3.0, 5.0].enumerated() {
            let d = item(String(format: delay < 1 ? "%.2f s" : "%g s", delay), #selector(selectFadeDelay(_:)))
            d.tag = i
            d.representedObject = delay
            d.state = abs(delay - s.fadeDelay) < 0.01 ? .on : .off
            delayMenu.addItem(d)
        }
        menu.addItem(submenu("Fade After", delayMenu))

        let toolbar = item("Show Toolbar While Drawing", #selector(toggleToolbar))
        toolbar.state = s.showToolbar ? .on : .off
        menu.addItem(toolbar)

        let clearOnExit = item("Clear When Drawing Stops", #selector(toggleClearOnExit))
        clearOnExit.state = s.clearOnExit ? .on : .off
        menu.addItem(clearOnExit)
        menu.addItem(.separator())

        let shortcutMenu = NSMenu()
        for (i, p) in ShortcutPreset.all.enumerated() {
            let sc = item("\(p.display)  (clear: \(p.clearDisplay))", #selector(selectShortcut(_:)))
            sc.tag = i
            sc.state = i == s.shortcutIndex ? .on : .off
            shortcutMenu.addItem(sc)
        }
        menu.addItem(submenu("Global Shortcut", shortcutMenu))
        menu.addItem(item("Keyboard Shortcuts…", #selector(showShortcuts)))

        if #available(macOS 13.0, *) {
            let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(item("About Scrawl", #selector(showAbout)))
        let quit = item("Quit Scrawl", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    private func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            p.fill()
            NSColor.gray.withAlphaComponent(0.6).setStroke()
            p.lineWidth = 0.5
            p.stroke()
            return true
        }
    }

    // MARK: Actions

    @objc private func toggleDrawing() {
        // Let the menu finish closing before we take over the screen.
        DispatchQueue.main.async { self.overlay.toggle() }
    }
    @objc private func clearAll() { overlay.clearAll() }
    @objc private func selectTool(_ sender: NSMenuItem) { Settings.shared.tool = Tool.allCases[sender.tag] }
    @objc private func selectColor(_ sender: NSMenuItem) { Settings.shared.colorIndex = sender.tag }
    @objc private func toggleFade() { Settings.shared.fadeEnabled.toggle() }
    @objc private func selectFadeDelay(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? Double { Settings.shared.fadeDelay = d }
    }
    @objc private func toggleToolbar() { Settings.shared.showToolbar.toggle() }
    @objc private func toggleClearOnExit() { Settings.shared.clearOnExit.toggle() }
    @objc private func selectShortcut(_ sender: NSMenuItem) {
        Settings.shared.shortcutIndex = sender.tag
        registerHotKeys()
        updateStatusIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.shared.show("Couldn't change login item: \(error.localizedDescription)", duration: 3)
        }
    }

    @objc private func showShortcuts() {
        let p = Settings.shared.shortcut
        let alert = NSAlert()
        alert.messageText = "Scrawl Shortcuts"
        alert.informativeText = """
        Global
          \(p.display)    Start / stop drawing
          \(p.clearDisplay)    Clear all drawings

        While drawing
          P  H  L  A  R  O    Pen, Highlighter, Line, Arrow, Rectangle, Ellipse
          1 – 8    Red, Orange, Yellow, Green, Blue, Purple, White, Black
          [  ]  or scroll    Thinner / thicker
          Shift + drag    Straight angles, squares, circles
          F    Toggle auto-fade (temporary ink)
          ⌘Z / ⇧⌘Z    Undo / Redo
          C or Delete    Clear all
          W / B    Whiteboard / Blackboard
          T    Show / hide toolbar
          Esc    Stop drawing
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "A tiny, fast screen annotation tool for macOS.\ngithub.com/IbrahimTalha0/scrawl"),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
