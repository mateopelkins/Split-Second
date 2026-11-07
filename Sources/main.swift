import AppKit

// Two copies would overwrite each other's save file, so a second copy hands over to the first.
if let id = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let first = others.first {
        first.activate(options: [])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
