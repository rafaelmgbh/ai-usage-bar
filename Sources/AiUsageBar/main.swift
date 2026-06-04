import AppKit

// App agente (sem ícone no Dock — reforçado por LSUIElement no Info.plist).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
