import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The timer window never takes keyboard focus, so clicking it leaves your cursor in the Doc.
final class TimerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Settings, Edit Splits, and Saved Runs. These open without switching apps, because making
/// this app active would pull you out of full-screen Chrome to a desktop. They can still take
/// keyboard focus for typing, and hand it back to Chrome when they close.
final class AttachedPanel: NSPanel {
    init(title: String, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
    }

    /// The menu bar belongs to Chrome while this is open, so the usual shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers == .command) {
        case ("x", true): action = #selector(NSText.cut(_:))
        case ("c", true): action = #selector(NSText.copy(_:))
        case ("v", true): action = #selector(NSText.paste(_:))
        case ("a", true): action = #selector(NSText.selectAll(_:))
        case ("z", true): action = Selector(("undo:"))
        case ("z", false): action = Selector(("redo:"))
        case ("w", true):
            performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Answers the first click, so buttons work while another app is in front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel: TimerPanel
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private static let positionKey = "panelTopLeft"
    private static let compactKey = "compact"
    private static let controlsKey = "showsControls"
    private static let scaleKey = "scale"
    private static let colorThemeKey = "colorTheme"
    private static let clockKey = "clockPrecision"

    init(model: AppModel, actions: WindowActions) {
        self.model = model
        panel = TimerPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 600),
                           styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()

        panel.title = "Split"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Follows you across desktops and over full-screen Chrome.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let host = FirstClickHostingView(rootView: TimerRootView(model: model, actions: actions))
        host.sizingOptions = []
        panel.contentView = host

        model.isCompact = UserDefaults.standard.bool(forKey: Self.compactKey)
        model.showsControls = UserDefaults.standard.object(forKey: Self.controlsKey) as? Bool ?? true
        let savedScale = UserDefaults.standard.object(forKey: Self.scaleKey) as? Double ?? 1
        model.scale = min(max(savedScale, AppModel.scaleRange.lowerBound), AppModel.scaleRange.upperBound)
        model.colorTheme = UserDefaults.standard.string(forKey: Self.colorThemeKey).flatMap(ColorTheme.init) ?? .classic
        model.clockPrecision = UserDefaults.standard.string(forKey: Self.clockKey).flatMap(ClockPrecision.init) ?? .hundredths
        resize()
        placeInitially()
        applyFloating(model.isFloating)
        applyColors()

        model.$isFloating.dropFirst().removeDuplicates()
            .sink { [weak self] in self?.applyFloating($0) }
            .store(in: &subscriptions)
        model.$isCompact.dropFirst().removeDuplicates()
            .sink { [weak self] compact in
                UserDefaults.standard.set(compact, forKey: Self.compactKey)
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &subscriptions)
        model.$showsControls.dropFirst().removeDuplicates()
            .sink { [weak self] shows in
                UserDefaults.standard.set(shows, forKey: Self.controlsKey)
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &subscriptions)
        model.$scale.dropFirst().removeDuplicates()
            .sink { [weak self] scale in
                UserDefaults.standard.set(scale, forKey: Self.scaleKey)
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &subscriptions)
        model.$clockPrecision.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0.rawValue, forKey: Self.clockKey) }
            .store(in: &subscriptions)
        model.$colorTheme.dropFirst().removeDuplicates()
            .sink { [weak self] theme in
                UserDefaults.standard.set(theme.rawValue, forKey: Self.colorThemeKey)
                DispatchQueue.main.async { self?.applyColors() }
            }
            .store(in: &subscriptions)
        model.$data.map(\.config.segments.count).removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resize() } }
            .store(in: &subscriptions)
    }

    /// Shows the window from the Dock or app switcher. If it was behind, it becomes an
    /// ordinary window, so clicking back into the Doc covers it again.
    func bringForward() {
        if !model.isFloating { panel.level = .normal }
        panel.orderFrontRegardless()
    }

    /// macOS ignores requests to reorder below another app's windows, so going behind
    /// uses a level under the normal one, which every regular window sits above.
    private func applyFloating(_ floating: Bool) {
        if floating {
            panel.level = .floating
            panel.orderFrontRegardless()
        } else {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        }
    }

    /// Opens a window beside the timer and attaches it, so it moves when the timer moves.
    func present(_ window: NSWindow) {
        if !window.isVisible {
            window.level = .floating
            window.backgroundColor = backgroundColor
            place(window)
        }
        if window.parent !== panel {
            panel.addChildWindow(window, ordered: .above)
        }
        // Attaching copies the timer's level, which is below other apps while it's behind.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
    }

    /// After a size change, moves any attached window that the timer has grown under.
    func clearAttachedWindows() {
        DispatchQueue.main.async { [self] in
            for window in panel.childWindows ?? [] where window.frame.intersects(panel.frame) {
                place(window)
            }
        }
    }

    /// Top edges line up, on whichever side of the timer has room.
    private func place(_ window: NSWindow) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let gap: CGFloat = 8
        let size = window.frame.size
        var origin = NSPoint(x: panel.frame.minX - gap - size.width, y: panel.frame.maxY - size.height)
        if origin.x < visible.minX, panel.frame.maxX + gap + size.width <= visible.maxX {
            origin.x = panel.frame.maxX + gap
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        window.setFrameOrigin(origin)
    }

    private var backgroundColor: NSColor { NSColor(Palette.of(model.colorTheme).background) }

    private func applyColors() {
        NSApp.appearance = NSAppearance(named: Palette.of(model.colorTheme).scheme == .light ? .aqua : .darkAqua)
        panel.backgroundColor = backgroundColor
        panel.childWindows?.forEach { $0.backgroundColor = backgroundColor }
    }

    private func targetSize() -> NSSize {
        let scale = CGFloat(model.scale)
        let height: CGFloat
        if model.isCompact {
            height = Metrics.compactHeight * scale
        } else {
            let chrome = Metrics.fullChrome - (model.showsControls ? 0 : Metrics.controlsHeight)
            let wanted = (chrome + CGFloat(model.segments.count) * Metrics.rowHeight) * scale
            let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? wanted
            height = min(wanted, available)
        }
        return NSSize(width: (Metrics.width * scale).rounded(.up), height: height.rounded(.up))
    }

    /// Changes size while keeping the top-left corner in place, unless that would push
    /// part of the window off the screen.
    private func resize() {
        let size = targetSize()
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size.height))
        }
        // Detached for the resize, so a window in use stays still, such as Settings mid-drag
        // on its size slider.
        let attached = panel.childWindows ?? []
        attached.forEach { panel.removeChildWindow($0) }
        panel.setFrame(frame, display: true)
        for window in attached {
            let level = window.level
            panel.addChildWindow(window, ordered: .above)
            window.level = level
        }
    }

    private func placeInitially() {
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) {
                panel.setFrameTopLeftPoint(point)
                return
            }
        }
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - Metrics.width - 20, y: visible.maxY - 20))
    }

    func windowDidMove(_ notification: Notification) {
        let frame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.positionKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panelController: PanelController?
    private var editorWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        panelController = PanelController(model: model, actions: WindowActions(
            showEditor: { [weak self] in self?.showEditor() },
            showHistory: { [weak self] in self?.showHistory() },
            showSettings: { [weak self] in self?.showSettings() }))
        registerHotkeys()

        // Keeps the clock display updating while the app sits in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Showing a running timer")

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.model.pauseForSleep() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.bringForward()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        panelController?.bringForward()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveForQuit()
    }

    private func registerHotkeys() {
        let model = self.model
        let keys: [(String, Int, () -> Void)] = [
            ("⌃⌥S", kVK_ANSI_S, { model.splitOrStart() }),
            ("⌃⌥P", kVK_ANSI_P, { model.togglePause() }),
            ("⌃⌥Z", kVK_ANSI_Z, { model.undoSplit() }),
            ("⌃⌥R", kVK_ANSI_R, { model.redoSplit() }),
            ("⌃⌥F", kVK_ANSI_F, { model.isFloating.toggle() }),
            ("⌃⌥C", kVK_ANSI_C, { model.isCompact.toggle() }),
        ]
        let refused = keys.filter { !Hotkeys.shared.register(keyCode: $0.1, action: $0.2) }.map(\.0)
        if !refused.isEmpty {
            model.hotkeyProblem = "Hotkey taken: \(refused.joined(separator: " "))"
        }
    }

    @objc private func showEditor() {
        let window = editorWindow ?? AttachedPanel(title: "Edit Splits", size: NSSize(width: 520, height: 560))
        editorWindow = window
        setContent(of: window, SplitsEditorView(model: model, hostWindow: { [weak window] in window }) { [weak window] in window?.close() })
        panelController?.present(window)
    }

    @objc private func showHistory() {
        let window = historyWindow ?? AttachedPanel(title: "Saved Runs", size: NSSize(width: 720, height: 480))
        historyWindow = window
        setContent(of: window, HistoryView(model: model, hostWindow: { [weak window] in window }))
        panelController?.present(window)
    }

    @objc private func showSettings() {
        let window = settingsWindow ?? AttachedPanel(title: "Settings", size: NSSize(width: 340, height: 300))
        settingsWindow = window
        let controller = panelController
        let host = setContent(of: window, SettingsView(model: model, hostWindow: { [weak window] in window }) {
            controller?.clearAttachedWindows()
        })
        window.setContentSize(host.fittingSize)
        panelController?.present(window)
    }

    @discardableResult
    private func setContent<Content: View>(of window: NSWindow, _ content: Content) -> NSView {
        let host = FirstClickHostingView(rootView: ThemedWindowContent(model: model) { content })
        window.contentView = host
        return host
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Split", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Split", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Split", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Edit Splits…", action: #selector(showEditor), keyEquivalent: "e").target = self
        file.addItem(withTitle: "Saved Runs…", action: #selector(showHistory), keyEquivalent: "r").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Text fields need these items for copy and paste to work.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        for submenu in [app, file, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}
