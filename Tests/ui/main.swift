import AppKit
import Carbon.HIToolbox
import SwiftUI

// Drives the real timer window with simulated clicks and saves snapshots to the folder in argv[1].
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var failures = 0
func check(_ condition: Bool, _ label: String, line: Int = #line) {
    print(condition ? "ok   \(label)" : "FAIL \(label) (line \(line))")
    if !condition { failures += 1 }
}
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func folder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("splits-ui-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func snapshot(_ window: NSWindow, _ name: String) {
    spin(0.25)
    let view = window.contentView!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}

func click(_ panel: NSPanel, _ point: NSPoint) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
    }
    spin(0.45)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
UserDefaults.standard.removeObject(forKey: "compact")
UserDefaults.standard.removeObject(forKey: "showsControls")
UserDefaults.standard.removeObject(forKey: "scale")
UserDefaults.standard.removeObject(forKey: "colorTheme")
UserDefaults.standard.removeObject(forKey: "clockPrecision")
UserDefaults.standard.removeObject(forKey: "panelTopLeft")
let sampleSplits = SplitsConfig(game: "Sample Project", category: "Sample Subtitle", segments: [
    "Gather Sources", "Read and Take Notes", "Pick a Main Argument", "A Long Split Name That Should Still Fit",
    "Plan the Structure", "First Draft", "Second Draft", "Peer Review",
    "Trim Length", "Final Revision", "Proofread", "References", "Layout", "Last Read",
].map { Segment(name: $0) })

/// A model with a realistic 14 split list.
func fullModel(clock: (() -> Double)? = nil) -> AppModel {
    let model = clock.map { AppModel(folder: folder(), clock: $0) } ?? AppModel(folder: folder())
    model.updateConfig(sampleSplits)
    return model
}

let noActions = WindowActions(showEditor: {}, showHistory: {}, showSettings: {})

// Real clock: click the real buttons.
do {
    let model = fullModel()
    let controller = PanelController(model: model, actions: noActions)
    let panel = controller.panel
    spin(0.3)
    check(panel.isVisible && panel.level == .floating, "starts visible and floating")
    check(!panel.canBecomeKey, "never takes keyboard focus")
    snapshot(panel, "1-idle")

    let split = NSPoint(x: 90, y: 79), undo = NSPoint(x: 250, y: 79)
    let pause = NSPoint(x: 90, y: 43), reset = NSPoint(x: 250, y: 43)

    click(panel, split)
    check(model.core.phase == .running, "click Start starts")
    click(panel, split)
    check(model.core.splits.count == 1, "click Split records a split")
    click(panel, undo)
    check(model.core.splits.isEmpty && model.core.phase == .running, "click Undo steps back, clock still running")
    click(panel, pause)
    check(model.core.phase == .paused, "click Pause pauses")
    click(panel, pause)
    check(model.core.phase == .running, "click Resume resumes")
    click(panel, reset)
    check(model.core.phase == .running, "first Reset click only asks")
    snapshot(panel, "2-reset-confirm")
    click(panel, reset)
    check(model.core.phase == .idle, "second Reset click resets")
    check(model.data.runs.count == 1 && model.data.runs[0].status == .reset, "reset run kept")

    let top = panel.frame.maxY
    model.isCompact = true
    spin(0.3)
    check(panel.frame.height == Metrics.compactHeight, "compact shrinks the window")
    check(panel.frame.maxY == top, "top edge stays put")
    snapshot(panel, "3-compact-idle")
    model.isCompact = false
    spin(0.3)
    check(panel.frame.height > 500, "full view comes back")

    // Header icons: pin is the first of six, at the right of the header.
    let pinPoint = NSPoint(x: Metrics.width - 12 - (24 * 6 + 2 * 5) + 12, y: panel.frame.height - 21)
    click(panel, pinPoint)
    check(!model.isFloating && panel.level < .normal, "click pin un-floats")
    click(panel, pinPoint)
    check(model.isFloating && panel.level == .floating, "click pin floats again")

    // The buttons toggle is the third header icon.
    let togglePoint = NSPoint(x: pinPoint.x + 52, y: pinPoint.y)
    let fullHeight = panel.frame.height, fullTop = panel.frame.maxY
    click(panel, togglePoint)
    spin(0.3)
    check(!model.showsControls, "click toggle hides the buttons")
    check(panel.frame.height == fullHeight - Metrics.controlsHeight, "window shrinks by the button area")
    check(panel.frame.maxY == fullTop, "top edge stays put when hiding")
    snapshot(panel, "10-hidden-idle")
    let togglePointHidden = NSPoint(x: togglePoint.x, y: panel.frame.height - 21)
    model.splitOrStart()
    spin(0.4)
    model.splitOrStart()
    check(model.core.splits.count == 1, "hotkey actions still work with buttons hidden")
    model.isCompact = true
    spin(0.3)
    check(panel.frame.height == Metrics.compactHeight, "compact height is unaffected")
    snapshot(panel, "11-hidden-compact")
    model.isCompact = false
    spin(0.3)
    check(panel.frame.height == fullHeight - Metrics.controlsHeight, "still hidden after leaving compact")
    click(panel, togglePointHidden)
    spin(0.3)
    check(model.showsControls && panel.frame.height == fullHeight, "click toggle brings the buttons back")
    check(UserDefaults.standard.bool(forKey: "showsControls"), "choice is remembered")
    panel.orderOut(nil)
}

// Size setting: buttons stay clickable and the layout holds at each size.
do {
    let model = fullModel()
    let controller = PanelController(model: model, actions: noActions)
    let panel = controller.panel
    let baseHeight = panel.frame.height
    for scale in [0.5, 0.7, 1.3, 1.5] {
        model.scale = scale
        spin(0.35)
        let label = "\(Int(scale * 100))%"
        check(panel.frame.width == (Metrics.width * scale).rounded(.up), "\(label): width follows")
        check(panel.frame.height == (baseHeight * scale).rounded(.up), "\(label): height follows")
        let visible = panel.screen!.visibleFrame
        check(visible.contains(panel.frame), "\(label): stays fully on screen")
        snapshot(panel, "12-size-\(Int(scale * 100))")

        // Start, split, undo, then reset, all by clicking at scaled positions.
        let split = NSPoint(x: 90 * scale, y: 79 * scale), undo = NSPoint(x: 250 * scale, y: 79 * scale)
        let reset = NSPoint(x: 250 * scale, y: 43 * scale)
        click(panel, split)
        click(panel, split)
        check(model.core.splits.count == 1, "\(label): Split button lands")
        click(panel, undo)
        check(model.core.splits.isEmpty, "\(label): Undo button lands")
        click(panel, reset)
        click(panel, reset)
        check(model.core.phase == .idle, "\(label): Reset button lands")

        model.isCompact = true
        spin(0.3)
        check(panel.frame.height == (Metrics.compactHeight * scale).rounded(.up), "\(label): compact height follows")
        snapshot(panel, "13-compact-\(Int(scale * 100))")
        model.isCompact = false
        spin(0.3)
    }
    model.scale = 2.0
    spin(0.35)
    check(panel.screen!.visibleFrame.contains(panel.frame), "200%: clamps to the screen")
    snapshot(panel, "12-size-200")
    model.scale = 1
    spin(0.3)
    check(panel.frame.height == baseHeight, "back to normal size")
    check(UserDefaults.standard.double(forKey: "scale") == 1, "size is remembered")
    panel.orderOut(nil)
}

// Attached windows: open beside the timer, travel with it, and stay still while it resizes.
do {
    let model = fullModel()
    let controller = PanelController(model: model, actions: noActions)
    let panel = controller.panel
    let visible = panel.screen!.visibleFrame
    spin(0.3)
    let settings = AttachedPanel(title: "Settings", size: NSSize(width: 340, height: 300))
    settings.contentView = FirstClickHostingView(rootView: ThemedWindowContent(model: model) {
        SettingsView(model: model, hostWindow: { [weak settings] in settings })
    })
    settings.setContentSize(settings.contentView!.fittingSize)
    controller.present(settings)
    spin(0.3)
    check(settings.parent === panel && settings.isVisible, "opens attached to the timer")
    check(settings.frame.maxX == panel.frame.minX - 8, "opens just left of the timer")
    check(settings.frame.maxY == panel.frame.maxY, "top edges line up")

    // The real picture buttons, near the bottom of Settings. The test build has no built-in
    // picture, so one is set first to put the buttons where they sit in the app.
    let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let pictureFile = folder().appendingPathComponent("small.png")
    try! picture.representation(using: .png, properties: [:])!.write(to: pictureFile)
    check(model.setPicture(from: pictureFile), "a picture can be set")
    let chosen = model.customPicture
    spin(0.3)
    click(settings, NSPoint(x: 160, y: 107))
    spin(0.8)
    let picker = settings.attachedSheet as? NSOpenPanel
    check(picker != nil, "clicking Change Image opens the picker on Settings")
    picker?.cancel(nil)
    spin(0.6)
    check(settings.attachedSheet == nil && model.customPicture === chosen, "cancelling the picker changes nothing")
    click(settings, NSPoint(x: 145, y: 77))
    check(model.customPicture == nil, "clicking Clear Image leaves no picture")
    spin(0.2)
    snapshot(settings, "15-settings-no-image")
    snapshot(panel, "16-timer-no-image")

    let origin = settings.frame.origin
    panel.setFrameOrigin(NSPoint(x: panel.frame.minX - 30, y: panel.frame.minY - 40))
    spin(0.3)
    check(settings.frame.origin == NSPoint(x: origin.x - 30, y: origin.y - 40), "moves with the timer")

    let held = settings.frame
    model.scale = 1.3
    spin(0.3)
    check(settings.frame == held, "stays still while the timer resizes")
    check(settings.parent === panel, "still attached after a resize")
    check(settings.frame.intersects(panel.frame), "timer has grown under it, as expected on the right edge")
    controller.clearAttachedWindows()
    spin(0.3)
    check(!settings.frame.intersects(panel.frame), "steps clear once the size is chosen")

    model.isFloating = false
    spin(0.3)
    print("attached level with timer behind:", settings.level.rawValue, "timer:", panel.level.rawValue)
    check(settings.isVisible, "stays open when the timer goes behind")
    model.isFloating = true
    spin(0.3)
    check(settings.isVisible && panel.level == .floating, "both float again")

    model.isFloating = false
    spin(0.3)
    settings.close()
    controller.present(settings)
    spin(0.3)
    check(settings.level == .floating, "opens on top even while the timer is behind")
    check(panel.level < .normal, "opening it leaves the timer behind")
    model.scale = 1.1
    spin(0.3)
    check(settings.level == .floating, "stays on top through a resize")
    model.scale = 1.3
    model.isFloating = true
    spin(0.3)

    settings.close()
    spin(0.2)
    check(!settings.isVisible && settings.parent == nil, "closing detaches it")
    model.scale = 1
    spin(0.3)
    check(!settings.isVisible, "a closed window stays closed when the timer resizes")

    panel.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
    spin(0.2)
    controller.present(settings)
    spin(0.3)
    check(settings.frame.minX == panel.frame.maxX + 8, "opens on the right when the timer is at the left edge")
    check(visible.contains(settings.frame), "stays on screen")
    settings.close()

    let typing = AttachedPanel(title: "Typing", size: NSSize(width: 300, height: 100))
    let field = NSTextField(frame: NSRect(x: 20, y: 30, width: 200, height: 24))
    field.stringValue = "hello"
    typing.contentView = NSView()
    typing.contentView!.addSubview(field)
    controller.present(typing)
    spin(0.2)
    typing.makeFirstResponder(field)
    func command(_ key: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: typing.windowNumber,
                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }
    field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
    check(typing.performKeyEquivalent(with: command("a")), "Cmd+A is handled")
    check(field.currentEditor()?.selectedRange.length == 5, "Cmd+A selects the text")
    check(typing.performKeyEquivalent(with: command("w")) && !typing.isVisible, "Cmd+W closes the window")

    model.colorTheme = .rosa
    spin(0.3)
    check(UserDefaults.standard.string(forKey: "colorTheme") == "magnolia", "color choice is saved")
    check(NSApp.appearance?.name == .aqua, "Magnolia uses light window chrome")
    let reopened = AppModel(folder: folder())
    let again = PanelController(model: reopened, actions: noActions)
    check(reopened.colorTheme == .rosa, "color choice is remembered next launch")
    again.panel.orderOut(nil)
    model.colorTheme = .classic
    spin(0.3)
    check(NSApp.appearance?.name == .darkAqua, "Classic uses dark window chrome")
    panel.orderOut(nil)
    UserDefaults.standard.removeObject(forKey: "panelTopLeft")
}

// The newest controls, clicked for real.
do {
    let model = fullModel()
    let controller = PanelController(model: model, actions: noActions)
    let panel = controller.panel
    spin(0.3)
    let split = NSPoint(x: 90, y: 79), undo = NSPoint(x: 250, y: 79), redo = NSPoint(x: 345, y: 79)
    click(panel, split)
    click(panel, split)
    let time = model.core.splits.first
    click(panel, undo)
    check(model.core.splits.isEmpty && model.core.canRedo, "Undo leaves a split to redo")
    click(panel, redo)
    check(model.core.splits.first == time, "clicking Redo brings back the exact time")

    func window<Content: View>(_ title: String, _ size: NSSize, _ content: (AttachedPanel) -> Content) -> AttachedPanel {
        let window = AttachedPanel(title: title, size: size)
        window.contentView = FirstClickHostingView(rootView: ThemedWindowContent(model: model) { content(window) })
        controller.present(window)
        spin(0.4)
        return window
    }

    let runs = window("Saved Runs", NSSize(width: 720, height: 480)) { host in HistoryView(model: model, hostWindow: { [weak host] in host }) }
    let slot = NSPoint(x: 256, y: 24), editTimes = NSPoint(x: 154, y: 24), delete = NSPoint(x: 57, y: 24)
    let id = model.currentRunID!
    click(runs, slot)
    check(model.data.runs[0].status == .setAside && model.core.phase == .idle, "clicking Set Aside frees the timer")
    snapshot(runs, "17-saved-runs-set-aside")
    click(runs, slot)
    check(model.currentRunID == id && model.core.phase == .paused, "clicking Resume Run brings it back paused")
    check(model.core.splits.first == time, "Resume Run keeps the split")
    click(runs, slot)
    check(model.data.runs[0].status == .setAside, "it can be set aside again")
    click(runs, editTimes)
    snapshot(runs, "18-saved-runs-editing")
    click(runs, NSPoint(x: 681, y: 24))
    check(model.data.runs[0].splits.first?.time == time, "saving unchanged times keeps them exact")
    click(runs, delete)
    spin(0.4)
    let confirm = runs.attachedSheet
    check(confirm != nil, "clicking Delete Run asks first")
    if let confirm { runs.endSheet(confirm, returnCode: .alertFirstButtonReturn) }
    spin(0.4)
    check(model.data.runs.isEmpty, "a set aside run can be deleted")
    runs.close()

    let editor = window("Edit Splits", NSSize(width: 520, height: 560)) { host in
        SplitsEditorView(model: model, hostWindow: { [weak host] in host }) {}
    }
    click(editor, NSPoint(x: 190, y: 532))
    check(model.data.presets.count == 2 && model.data.config.game == "Untitled", "clicking New adds a preset and selects it")
    check(model.core.segmentCount == 3, "the timer follows the new preset")
    spin(0.3)
    snapshot(editor, "19-editor-new-preset")
    click(editor, NSPoint(x: 255, y: 532))
    spin(0.4)
    let confirmPreset = editor.attachedSheet
    check(confirmPreset != nil, "clicking Delete asks first")
    if let confirmPreset { editor.endSheet(confirmPreset, returnCode: .alertFirstButtonReturn) }
    spin(0.4)
    check(model.data.presets.count == 1 && model.data.config.game == "Sample Project", "the preset is removed and the first comes back")
    check(model.core.segmentCount == 14, "the timer follows back")
    editor.close()
    panel.orderOut(nil)
}

// Fake clock: a realistic mid-run view against a best run, in each palette.
for theme in ColorTheme.allCases {
    let tag = theme.rawValue + "-"
    var now = 1000.0
    let model = fullModel { now }
    let controller = PanelController(model: model, actions: noActions)
    model.colorTheme = theme
    let picture = NSImage(size: NSSize(width: 400, height: 800), flipped: false) { rect in
        NSGradient(starting: .systemTeal, ending: .systemOrange)!.draw(in: rect, angle: 90)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 150, y: 350, width: 100, height: 100)).fill()
        return true
    }
    let pictureFile = folder().appendingPathComponent("tall.png")
    try! NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: pictureFile)
    check(model.setPicture(from: pictureFile), "\(theme.title): picture accepted")
    spin(0.2)
    snapshot(controller.panel, tag + "0-ready")
    model.splitOrStart()
    for _ in model.segments { now += 900; model.splitOrStart() }
    model.resetRun()

    model.splitOrStart()
    for step in [840.0, 1000, 620, 905, 2000] { now += step; model.splitOrStart() }
    now += 412.5
    model.togglePause()
    model.togglePause()
    now += 10
    model.ticker.now = now
    spin(0.2)
    snapshot(controller.panel, tag + "4-midrun")
    model.togglePause()
    snapshot(controller.panel, tag + "5-paused")
    model.isCompact = true
    spin(0.3)
    snapshot(controller.panel, tag + "6-compact-paused")
    model.isCompact = false
    spin(0.2)
    model.togglePause()
    for _ in 0..<(model.segments.count - model.core.splits.count) { now += 300; model.splitOrStart() }
    snapshot(controller.panel, tag + "7-finished-best")
    controller.panel.orderOut(nil)

    func show<Content: View>(_ title: String, _ size: NSSize, _ name: String, _ content: Content) {
        let window = AttachedPanel(title: title, size: size)
        window.backgroundColor = NSColor(Palette.of(theme).background)
        let host = FirstClickHostingView(rootView: ThemedWindowContent(model: model) { content })
        window.contentView = host
        window.orderFront(nil)
        snapshot(window, tag + name)
        window.orderOut(nil)
    }
    show("Saved Runs", NSSize(width: 720, height: 480), "8-history", HistoryView(model: model))
    show("Edit Splits", NSSize(width: 520, height: 560), "9-editor", SplitsEditorView(model: model) {})
    show("Settings", NSSize(width: 340, height: 300), "14-settings", SettingsView(model: model))
}

UserDefaults.standard.removeObject(forKey: "colorTheme")

// Stacking against whatever other apps have open, as the window server reports it.
do {
    let model = fullModel()
    let controller = PanelController(model: model, actions: noActions)
    let panel = controller.panel
    func stack() -> (panel: Int, firstOther: Int?, lastOther: Int?) {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        // Regular windows only. Desktop widgets sit on a far lower layer, below everything.
        let list = all.filter { (-1...3).contains($0[kCGWindowLayer as String] as? Int ?? 99) }
        let mine = list.firstIndex { $0[kCGWindowNumber as String] as? Int == panel.windowNumber } ?? -1
        let others = list.indices.filter { $0 != mine }
        return (mine, others.first, others.last)
    }
    print("front app:", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
    spin(0.4)
    var order = stack()
    check(order.lastOther != nil, "other apps have windows to compare against")
    check(order.panel < (order.firstOther ?? 0), "floating: above every other window")

    model.isFloating = false
    spin(0.4)
    order = stack()
    check(order.panel > (order.lastOther ?? 0), "unfloated: behind every other window")

    controller.bringForward()
    spin(0.3)
    order = stack()
    check(order.panel < (order.firstOther ?? 0), "Dock or app switch brings it back in front")

    model.isFloating = false
    spin(0.3)
    model.isFloating = true
    spin(0.4)
    order = stack()
    check(order.panel < (order.firstOther ?? 0), "float again from behind: back on top")
    panel.orderOut(nil)
}

// Hotkeys: macOS accepts all five, and a hotkey event reaches its action.
do {
    var fired: [Int] = []
    let codes = [kVK_ANSI_S, kVK_ANSI_P, kVK_ANSI_Z, kVK_ANSI_F, kVK_ANSI_C]
    for code in codes {
        check(Hotkeys.shared.register(keyCode: code) { fired.append(code) }, "hotkey accepted: keycode \(code)")
    }
    for id in 1...UInt32(codes.count) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        var hotkey = EventHotKeyID(signature: 0x4553_504C, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotkey)
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }
    check(fired == codes, "each hotkey runs its own action")
}

print(failures == 0 ? "UI PASSED" : "\(failures) UI FAILED")
exit(failures == 0 ? 0 : 1)
