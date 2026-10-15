import AppKit

// Line-buffer stdout, as SillHost does, so the log reads live when it is redirected.
setvbuf(stdout, nil, _IOLBF, 0)

// Sill Client, the Mac Client (docs/adr/0001): a regular app with a Dock icon and windows.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
