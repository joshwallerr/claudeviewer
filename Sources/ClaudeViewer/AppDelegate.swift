import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = SessionMonitor()
    private let limitsMonitor = LimitsMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var renderTimer: Timer?
    private let renderScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(
            withLength: MenuBarLabel.width(for: 0)
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(monitor: monitor, limits: limitsMonitor)
        )

        monitor.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.statusItem.length = MenuBarLabel.width(for: sessions.count)
                self.renderMenuBar()
            }
            .store(in: &cancellables)

        // Drive the pulse animation by re-rendering the button image.
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderMenuBar()
            }
        }
        RunLoop.main.add(renderTimer!, forMode: .common)

        monitor.start()
        limitsMonitor.start()
        renderMenuBar()
    }

    private func renderMenuBar() {
        let sessions = monitor.sessions
        let needsAnimation = sessions.contains { $0.status == .working }
        let phase = needsAnimation ? DotView.phase(at: Date()) : 1.0

        let label = MenuBarLabel(sessions: sessions, phase: phase)
            .frame(
                width: MenuBarLabel.width(for: sessions.count),
                height: MenuBarLabel.height
            )

        let renderer = ImageRenderer(content: label)
        renderer.scale = renderScale
        renderer.isOpaque = false

        guard let image = renderer.nsImage else { return }
        // Non-template so the orange survives; AppKit still draws the
        // selection pill behind a non-template image.
        image.isTemplate = false
        statusItem.button?.image = image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
            limitsMonitor.refresh()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}
