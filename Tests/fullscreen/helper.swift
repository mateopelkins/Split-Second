import AppKit

// A stand-in for full-screen Chrome: another app with one window in its own full-screen Space.
final class Helper: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!

    func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Full Screen Stand-in"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.window.toggleFullScreen(nil) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { say("FULLSCREEN \(window.windowNumber)") }
    func windowDidBecomeKey(_ notification: Notification) { say("KEY") }
    func windowDidResignKey(_ notification: Notification) { say("RESIGN") }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let helper = Helper()
app.delegate = helper
app.run()
