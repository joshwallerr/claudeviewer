import Foundation
import Combine
import Darwin

enum SessionStatus: Equatable {
    case working
    case idle

    init(raw: String) {
        // `busy` = model is thinking, `shell` = a tool is running on its behalf.
        // From the user's perspective both are "the session is doing something".
        switch raw {
        case "busy", "shell":
            self = .working
        default:
            self = .idle
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Waiting for you"
        }
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    let pid: Int
    let cwd: String
    let status: SessionStatus
    let updatedAt: Date
    let context: ContextUsage?
    let title: String?
    /// True when the session is idle and hasn't ticked in a while —
    /// we dim its dot so still-active sessions stand out.
    let isStaleIdle: Bool
}

private let staleIdleThreshold: TimeInterval = 2 * 60 * 60  // 2 hours

private struct SessionFile: Decodable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let status: String
    let updatedAt: Int64
}

final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let directoryURL: URL
    private var dirFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private let contextReader = ContextUsageReader()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        directoryURL = home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    func start() {
        contextReader.detectContextWindow()
        refresh()
        watchDirectory()
        // Heartbeat status flips don't necessarily fire directory events,
        // so poll every second as a cheap fallback. Reads are tiny JSON files.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    func stop() {
        refreshTimer?.invalidate()
        dirSource?.cancel()
    }

    private func watchDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        source.resume()
        dirSource = source
    }

    private func refresh() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directoryURL.path) else {
            if !sessions.isEmpty { sessions = [] }
            return
        }

        let decoder = JSONDecoder()
        var found: [Session] = []
        for name in names where name.hasSuffix(".json") {
            let url = directoryURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let raw = try? decoder.decode(SessionFile.self, from: data)
            else { continue }
            guard isAlive(pid: pid_t(raw.pid)) else { continue }
            let usage = contextReader.usage(forSessionId: raw.sessionId, cwd: raw.cwd)
            let status = SessionStatus(raw: raw.status)

            // Skip sessions that have never been interacted with. A session
            // has been interacted with iff its JSONL has at least one
            // assistant message (which produces a usage entry). Exception:
            // if it's actively busy, it's processing the user's very first
            // prompt right now — show it immediately.
            if status != .working && usage == nil { continue }

            let title = contextReader.title(forSessionId: raw.sessionId, cwd: raw.cwd)
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(raw.updatedAt) / 1000)
            let isStale = status == .idle
                && Date().timeIntervalSince(updatedAt) > staleIdleThreshold
            found.append(
                Session(
                    id: raw.sessionId,
                    pid: raw.pid,
                    cwd: raw.cwd,
                    status: status,
                    updatedAt: updatedAt,
                    context: usage,
                    title: title,
                    isStaleIdle: isStale
                )
            )
        }

        // Popover order: Working → Waiting (fresh idle) → Inactive (stale idle).
        // Within each group, most recent activity first.
        func rank(_ s: Session) -> Int {
            if s.status == .working { return 0 }
            return s.isStaleIdle ? 2 : 1
        }
        found.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.updatedAt > b.updatedAt
        }

        if found != sessions {
            sessions = found
        }
    }

    private func isAlive(pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
