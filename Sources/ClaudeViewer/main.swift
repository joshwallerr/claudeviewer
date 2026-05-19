import AppKit

@MainActor
func bootstrap() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // Retain the delegate for the lifetime of the app.
    Unmanaged.passRetained(delegate).release()
    app.run()
}

MainActor.assumeIsolated {
    bootstrap()
}
