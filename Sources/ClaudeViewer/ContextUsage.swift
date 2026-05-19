import Foundation

struct ContextUsage: Equatable {
    let totalTokens: Int
    let contextWindow: Int

    var percent: Int {
        guard contextWindow > 0 else { return 0 }
        return Int((Double(totalTokens) / Double(contextWindow) * 100).rounded())
    }
}

/// Reads per-session info out of Claude Code's JSONL transcripts at
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
///
/// Two pieces of info are surfaced:
///   - context usage (sum of input + cache_creation + cache_read tokens
///     in the latest assistant turn)
///   - a human-friendly title, picked from (in priority order):
///       customTitle  (set once via `claude -n …`)  → head of file
///       agentName    (subagent sessions)            → head of file
///       aiTitle      (Claude-generated, regenerated periodically) → tail
///
/// To keep I/O bounded regardless of how large the JSONL grows, we read
/// only a 256KB tail (for usage + latest ai-title) and a 64KB head (for
/// custom-title + agent-name, which are written near session start).
final class ContextUsageReader {
    private struct TailEntry {
        let mtime: Date
        let tokens: Int?
        let aiTitle: String?
    }
    private struct HeadEntry {
        let customTitle: String?
        let agentName: String?
    }

    private var tailCache: [String: TailEntry] = [:]
    /// Cached once per session — these fields don't change after creation.
    private var headCache: [String: HeadEntry] = [:]

    private(set) var detectedContextWindow: Int = 200_000
    private let projectsDir: URL

    init() {
        projectsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Scan once on startup to figure out if the user is on the 1M context beta.
    func detectContextWindow() {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for projectDir in projectDirs {
            guard let logs = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            for log in logs where log.pathExtension == "jsonl" {
                if let tokens = readTail(at: log).tokens, tokens > 200_000 {
                    detectedContextWindow = 1_000_000
                    return
                }
            }
        }
    }

    func usage(forSessionId sessionId: String, cwd: String) -> ContextUsage? {
        guard let tokens = tailEntry(forSessionId: sessionId, cwd: cwd).tokens else { return nil }
        if tokens > 200_000 && detectedContextWindow < 1_000_000 {
            detectedContextWindow = 1_000_000
        }
        return ContextUsage(totalTokens: tokens, contextWindow: detectedContextWindow)
    }

    func title(forSessionId sessionId: String, cwd: String) -> String? {
        let head = headEntry(forSessionId: sessionId, cwd: cwd)
        let tail = tailEntry(forSessionId: sessionId, cwd: cwd)
        return head.customTitle ?? head.agentName ?? tail.aiTitle
    }

    // MARK: caching layer

    private func tailEntry(forSessionId sessionId: String, cwd: String) -> TailEntry {
        let url = transcriptURL(for: sessionId, cwd: cwd)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TailEntry(mtime: .distantPast, tokens: nil, aiTitle: nil)
        }
        let mtime: Date = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let m = attrs[.modificationDate] as? Date { return m }
            return Date()
        }()
        if let cached = tailCache[sessionId], cached.mtime == mtime {
            return cached
        }
        let scan = readTail(at: url)
        let entry = TailEntry(mtime: mtime, tokens: scan.tokens, aiTitle: scan.aiTitle)
        tailCache[sessionId] = entry
        return entry
    }

    private func headEntry(forSessionId sessionId: String, cwd: String) -> HeadEntry {
        if let cached = headCache[sessionId] { return cached }
        let url = transcriptURL(for: sessionId, cwd: cwd)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = HeadEntry(customTitle: nil, agentName: nil)
            headCache[sessionId] = empty
            return empty
        }
        let scan = readHead(at: url)
        let entry = HeadEntry(customTitle: scan.customTitle, agentName: scan.agentName)
        headCache[sessionId] = entry
        return entry
    }

    // MARK: low-level scans

    private func transcriptURL(for sessionId: String, cwd: String) -> URL {
        let encoded = "-" + cwd
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        return projectsDir
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func readTail(at url: URL) -> (tokens: Int?, aiTitle: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let endOffset = try? handle.seekToEnd() else { return (nil, nil) }
        let tailSize: UInt64 = 256 * 1024
        let start = endOffset > tailSize ? endOffset - tailSize : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return (nil, nil) }

        var tokens: Int?
        var aiTitle: String?

        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" })
        for line in lines.reversed() {
            if tokens == nil,
               line.contains("\"type\":\"assistant\""),
               line.contains("\"usage\":") {
                if let obj = parseJSONObject(line),
                   let message = obj["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    tokens = input + cc + cr
                }
            }
            if aiTitle == nil, line.contains("\"type\":\"ai-title\"") {
                if let obj = parseJSONObject(line) {
                    aiTitle = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if tokens != nil && aiTitle != nil { break }
        }
        return (tokens, aiTitle)
    }

    private func readHead(at url: URL) -> (customTitle: String?, agentName: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let headSize = 64 * 1024
        guard let data = try? handle.read(upToCount: headSize),
              let text = String(data: data, encoding: .utf8)
        else { return (nil, nil) }

        var customTitle: String?
        var agentName: String?

        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" })
        for line in lines {
            if customTitle == nil, line.contains("\"type\":\"custom-title\""),
               let obj = parseJSONObject(line) {
                customTitle = (obj["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if agentName == nil, line.contains("\"type\":\"agent-name\""),
               let obj = parseJSONObject(line) {
                agentName = (obj["agentName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if customTitle != nil && agentName != nil { break }
        }
        return (customTitle, agentName)
    }

    private func parseJSONObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
