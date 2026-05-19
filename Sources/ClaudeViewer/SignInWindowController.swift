import AppKit
import WebKit

@MainActor
final class SignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private let onCapture: @MainActor (String) -> Void
    private var pollTimer: Timer?
    private let statusLabel = NSTextField(labelWithString: "")

    init(onCapture: @escaping @MainActor (String) -> Void) {
        self.onCapture = onCapture

        let config = WKWebViewConfiguration()
        // Persistent store so the user stays signed in between launches and we can
        // silently grab a fresh cookie when the saved one expires.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        // claude.ai blocks unknown UAs; mimic Safari.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to claude.ai"
        window.center()
        window.isReleasedWhenClosed = false

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = "Sign in normally — this window will close once we have your session."

        container.addSubview(webView)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        window.contentView = container

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let url = URL(string: "https://claude.ai/login")!
        webView.load(URLRequest(url: url))

        // Also check immediately in case a fresh cookie is already there.
        checkCookies()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCookies() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func checkCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let match = cookies.first {
                $0.name == "sessionKey"
                && $0.domain.contains("claude.ai")
                && !$0.value.isEmpty
            }
            guard let cookie = match else { return }
            self.captureAndClose(cookie.value)
        }
    }

    private func captureAndClose(_ value: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        statusLabel.stringValue = "Got it — saving…"
        onCapture(value)
        // Slight delay so the status label is visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.close()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { self.checkCookies() }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
