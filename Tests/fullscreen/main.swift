import AppKit

// Opens each extra window through the real app delegate while another app is in full screen.
// argv[1] is the path to the compiled helper.
var failures = 0
func check(_ condition: Bool, _ label: String, line: Int = #line) {
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    print(condition ? "ok   \(label)" : "FAIL \(label) (line \(line), front app: \(front))")
    if !condition { failures += 1 }
}

let dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent("splits-fs-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
setenv("ESSAY_SPLITS_DATA_DIR", dataFolder.path, 1)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.finishLaunching()

/// Runs the app's event loop for a while, so window and Space changes are delivered.
func spin(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
let log = Log()

let helper = Process()
helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pipe = Pipe()
helper.standardOutput = pipe
pipe.fileHandleForReading.readabilityHandler = { handle in
    let text = String(decoding: handle.availableData, as: UTF8.self)
    text.split(separator: "\n").forEach { log.add(String($0)) }
}
try! helper.run()

var waited = 0.0
while !log.all.contains(where: { $0.hasPrefix("FULLSCREEN") }), waited < 12 { spin(0.25); waited += 0.25 }
guard let line = log.all.first(where: { $0.hasPrefix("FULLSCREEN") }), let helperWindow = Int(line.split(separator: " ")[1]) else {
    print("FAIL helper never reached full screen")
    helper.terminate()
    exit(1)
}
spin(1.5)

func onScreen(_ number: Int) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    return list.contains { $0[kCGWindowNumber as String] as? Int == number }
}
func frontIsHelper() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier }

check(onScreen(helperWindow), "start: the full-screen window is showing")
check(frontIsHelper(), "start: the full-screen app is in front")
let timer = app.windows.first { $0 is TimerPanel }!
check(onScreen(timer.windowNumber), "start: the timer shows over full screen")

for (selector, title) in [("showSettings", "Settings"), ("showEditor", "Edit Splits"), ("showHistory", "Saved Runs")] {
    let keysBefore = log.all.filter { $0 == "KEY" }.count
    app.sendAction(Selector((selector)), to: delegate, from: nil)
    spin(1.6)
    let window = app.windows.first { $0.title == title }
    check(window != nil, "\(title): window exists")
    check(onScreen(helperWindow), "\(title): stays in the full-screen Space")
    check(window.map { onScreen($0.windowNumber) } ?? false, "\(title): shows over full screen")
    check(onScreen(timer.windowNumber), "\(title): timer still showing")
    check(frontIsHelper(), "\(title): the full-screen app stays the front app")
    check(window?.isKeyWindow == true, "\(title): takes keyboard focus for typing")
    check(log.all.last == "RESIGN", "\(title): the full-screen app gave up the keyboard")
    check(window?.parent === timer, "\(title): attached to the timer")
    window?.close()
    spin(1.2)
    check(onScreen(helperWindow), "\(title): still in the full-screen Space after closing")
    check(log.all.filter { $0 == "KEY" }.count > keysBefore || log.all.last == "KEY", "\(title): keyboard goes back to the full-screen app")
}

// Dialogs from Saved Runs open as sheets, so they stay in the full-screen Space too.
app.sendAction(Selector(("showHistory")), to: delegate, from: nil)
spin(1.2)
let history = app.windows.first { $0.title == "Saved Runs" }!
let save = NSSavePanel()
save.beginSheetModal(for: history) { _ in }
spin(2)
check(onScreen(helperWindow), "export dialog: stays in the full-screen Space")
check(history.attachedSheet != nil, "export dialog: opens on Saved Runs")
check(frontIsHelper(), "export dialog: the full-screen app stays in front")
save.cancel(nil)
spin(1)
check(onScreen(helperWindow), "export dialog: still in the full-screen Space after cancelling")

let alert = NSAlert()
alert.messageText = "Delete this run?"
alert.addButton(withTitle: "Delete")
alert.addButton(withTitle: "Cancel")
alert.beginSheetModal(for: history) { _ in }
spin(1.2)
check(onScreen(helperWindow), "delete dialog: stays in the full-screen Space")
check(alert.window.isVisible && onScreen(alert.window.windowNumber), "delete dialog: shows over full screen")
history.endSheet(alert.window)
spin(0.8)
history.close()
spin(1)
check(onScreen(helperWindow), "still in the full-screen Space at the end")

// The image picker in Settings. Clicking inside it makes this the active app, so that's checked too.
app.sendAction(Selector(("showSettings")), to: delegate, from: nil)
spin(1.2)
let settings = app.windows.first { $0.title == "Settings" }!
let picker = NSOpenPanel()
picker.allowedContentTypes = [.image]
picker.beginSheetModal(for: settings) { _ in }
spin(2)
check(onScreen(helperWindow), "image picker: stays in the full-screen Space")
check(settings.attachedSheet != nil, "image picker: opens on Settings")
check(frontIsHelper(), "image picker: the full-screen app stays in front")
app.activate(ignoringOtherApps: true)
spin(1.5)
check(onScreen(helperWindow), "image picker: clicking inside it stays in the full-screen Space")
picker.cancel(nil)
spin(1)
check(onScreen(helperWindow), "image picker: still in the full-screen Space after cancelling")
settings.close()
spin(1)
check(onScreen(helperWindow), "image picker: still in the full-screen Space after closing Settings")

print("helper log:", log.all.joined(separator: " "))
helper.terminate()
spin(1.5)
print(failures == 0 ? "FULLSCREEN PASSED" : "\(failures) FULLSCREEN FAILED")
exit(failures == 0 ? 0 : 1)
