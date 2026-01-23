import AppKit

let app = NSApplication.shared
let delegate = ApplicationDelegate()

app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
