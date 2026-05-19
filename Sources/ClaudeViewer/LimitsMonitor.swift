import Foundation
import Combine
import AppKit

@MainActor
final class LimitsMonitor: ObservableObject {
    enum State: Equatable {
        case notConfigured
        case loading
        case ok(ClaudeLimits)
        case error(String)
    }

    @Published private(set) var state: State = .notConfigured

    private let client = LimitsClient()
    private var timer: Timer?
    private var signInWindow: SignInWindowController?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refresh() {
        guard let key = KeychainStore.load() else {
            state = .notConfigured
            return
        }
        if case .ok = state {
            // keep showing prior value while refreshing
        } else {
            state = .loading
        }
        let orgId = AppPreferences.orgId
        Task { [weak self] in
            guard let self else { return }
            do {
                let (limits, discovered) = try await client.fetch(sessionKey: key, orgId: orgId)
                AppPreferences.orgId = discovered
                self.state = .ok(limits)
            } catch {
                self.state = .error((error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
            }
        }
    }

    /// User-driven save from the settings sheet. Returns nil on success,
    /// an error message on failure.
    func saveAndTest(sessionKey: String) async -> String? {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Session key is empty" }
        do {
            try KeychainStore.save(trimmed)
        } catch {
            return error.localizedDescription
        }
        AppPreferences.orgId = nil
        state = .loading
        do {
            let (limits, discovered) = try await client.fetch(sessionKey: trimmed, orgId: nil)
            AppPreferences.orgId = discovered
            state = .ok(limits)
            return nil
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .error(msg)
            return msg
        }
    }

    func clear() {
        KeychainStore.delete()
        AppPreferences.orgId = nil
        state = .notConfigured
    }

    /// Pulls the saved `sessionKey` straight out of a Chromium-based browser
    /// the user is already signed into. Returns nil on success, an error
    /// message otherwise.
    func importFromBrowser(_ browser: Browser) async -> String? {
        do {
            let importer = BrowserCookieImporter(browser: browser)
            let key = try importer.importSessionKey()
            let err = await saveAndTest(sessionKey: key)
            if err == nil {
                AppPreferences.lastImportBrowser = browser.displayName
            }
            return err
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .error(msg)
            return msg
        }
    }

    /// Opens an embedded claude.ai login window. When the user signs in,
    /// the `sessionKey` cookie is captured and saved automatically.
    func presentSignIn() {
        if let existing = signInWindow {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SignInWindowController { [weak self] capturedKey in
            guard let self else { return }
            self.signInWindow = nil
            Task { _ = await self.saveAndTest(sessionKey: capturedKey) }
        }
        signInWindow = controller
        controller.start()
    }
}
