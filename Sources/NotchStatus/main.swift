import AppKit
import CoreServices
import Darwin
import Foundation
import SQLite3
import UserNotifications

private enum ThreadPhase: Equatable {
    case running
    case ready
    case stopped
    case seen
}

private enum AgentKind: Equatable {
    case codex
    case pi
    case opencode

    var label: String {
        switch self {
        case .codex: return "codex"
        case .pi: return "pi"
        case .opencode: return "opencode"
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .opencode: return "opencode"
        }
    }
}

private let activityRetention: TimeInterval = 15 * 60
private let runningInactivityTimeout: TimeInterval = 6 * 60 * 60
private let piRunningInactivityTimeout: TimeInterval = 30 * 60
private let opencodeRunningInactivityTimeout: TimeInterval = 30 * 60

private func shouldRetain(_ phase: ThreadPhase, updatedAt: Date, now: Date = Date()) -> Bool {
    phase == .running || now.timeIntervalSince(updatedAt) < activityRetention
}

private func shouldMarkStopped(
    _ phase: ThreadPhase,
    updatedAt: Date,
    timeout: TimeInterval,
    now: Date = Date()
) -> Bool {
    phase == .running && now.timeIntervalSince(updatedAt) >= timeout
}

private func phaseRank(_ phase: ThreadPhase) -> Int {
    switch phase {
    case .running: return 0
    case .stopped: return 1
    case .ready: return 2
    case .seen: return 3
    }
}

private func visiblePacmanTrack(
    in bounds: NSRect,
    bodyInset: CGFloat,
    physicalNotchWidth: CGFloat
) -> ClosedRange<CGFloat> {
    let bodyRight = bounds.maxX - bodyInset
    let end = bodyRight - 7
    let start = physicalNotchWidth > 0
        ? bounds.midX + physicalNotchWidth / 2 - 7
        : bounds.minX + bodyInset + 44
    return min(start, end)...end
}

private struct ThreadActivity: Equatable {
    let id: String
    let agent: AgentKind
    let parentID: String?
    let nickname: String?
    let title: String
    let detail: String
    let source: String
    let project: String
    let model: String
    let usage: UsageSnapshot?
    var phase: ThreadPhase
    var updatedAt: Date

    var key: String { "\(agent.label):\(id)" }
    var runningTimeout: TimeInterval {
        switch agent {
        case .codex: return runningInactivityTimeout
        case .pi: return piRunningInactivityTimeout
        case .opencode: return opencodeRunningInactivityTimeout
        }
    }
}

private struct SessionMeta {
    let id: String
    let agent: AgentKind
    let parentID: String?
    let nickname: String?
    var source: String
    let project: String

    var key: String { "\(agent.label):\(id)" }
}

private struct RateLimitUsage: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

private struct UsageSnapshot: Equatable {
    let totalTokens: Int
    let contextTokens: Int
    let contextWindow: Int
    let primaryLimit: RateLimitUsage?
    let secondaryLimit: RateLimitUsage?
    let costTotal: Double?
}

private enum TurnEvent: Equatable {
    case started
    case completed
    case cancelled
}

private struct SessionSnapshot {
    let event: TurnEvent
    let response: String?
    let prompt: String?
    let model: String?
    let usage: UsageSnapshot?
    let name: String?
}

private func condensedText(_ message: String) -> String? {
    let condensed = message.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    return condensed.isEmpty ? nil : String(condensed.prefix(240))
}

private let taskNeedle = Data("\"payload\":{\"type\":\"task_".utf8)
private let abortedNeedle = Data("\"payload\":{\"type\":\"turn_aborted\"".utf8)
private let responseNeedle = Data("\"payload\":{\"type\":\"agent_message\"".utf8)
private let promptNeedle = Data("\"payload\":{\"type\":\"user_message\"".utf8)
private let usageNeedle = Data("\"payload\":{\"type\":\"token_count\"".utf8)
private let contextNeedle = Data("\"type\":\"turn_context\"".utf8)

private func parseTurnEvent(_ line: Data) -> TurnEvent? {
    guard line.range(of: taskNeedle) != nil || line.range(of: abortedNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          object["type"] as? String == "event_msg",
          let payload = object["payload"] as? [String: Any],
          let type = payload["type"] as? String else { return nil }

    switch type {
    case "task_started": return .started
    case "task_complete": return .completed
    case "turn_aborted": return .cancelled
    default: return nil
    }
}

private func parseMessage(_ line: Data, needle: Data, type: String) -> String? {
    guard line.range(of: needle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          object["type"] as? String == "event_msg",
          let payload = object["payload"] as? [String: Any],
          payload["type"] as? String == type,
          let message = payload["message"] as? String else { return nil }

    return condensedText(message)
}

private func parseResponse(_ line: Data) -> String? {
    parseMessage(line, needle: responseNeedle, type: "agent_message")
}

private func parsePrompt(_ line: Data) -> String? {
    parseMessage(line, needle: promptNeedle, type: "user_message")
}

private func parseModel(_ line: Data) -> String? {
    guard line.range(of: contextNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          object["type"] as? String == "turn_context",
          let payload = object["payload"] as? [String: Any] else { return nil }

    let model = payload["model"] as? String ?? ""
    let effort = payload["effort"] as? String ?? ""
    return model.isEmpty ? nil : effort.isEmpty ? model : "\(model)/\(effort)"
}

private func parseUsage(_ line: Data) -> UsageSnapshot? {
    guard line.range(of: usageNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          object["type"] as? String == "event_msg",
          let payload = object["payload"] as? [String: Any],
          payload["type"] as? String == "token_count",
          let info = payload["info"] as? [String: Any],
          let total = info["total_token_usage"] as? [String: Any],
          let latest = info["last_token_usage"] as? [String: Any],
          let totalTokens = (total["total_tokens"] as? NSNumber)?.intValue,
          let contextTokens = (latest["total_tokens"] as? NSNumber)?.intValue,
          let contextWindow = (info["model_context_window"] as? NSNumber)?.intValue else { return nil }

    func limit(_ value: Any?) -> RateLimitUsage? {
        guard let value = value as? [String: Any],
              let usedPercent = (value["used_percent"] as? NSNumber)?.doubleValue,
              let windowMinutes = (value["window_minutes"] as? NSNumber)?.intValue else { return nil }
        let resetsAt = (value["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitUsage(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }

    let rateLimits = payload["rate_limits"] as? [String: Any]
    return UsageSnapshot(
        totalTokens: totalTokens,
        contextTokens: contextTokens,
        contextWindow: contextWindow,
        primaryLimit: limit(rateLimits?["primary"]),
        secondaryLimit: limit(rateLimits?["secondary"]),
        costTotal: nil
    )
}

// MARK: - Pi session parsing

private enum PiEvent {
    case userPrompt(String)
    case assistant(text: String?, model: String?, provider: String?, stopReason: String, usage: PiUsage?)
    case modelChange(model: String, provider: String?)
    case thinkingLevel(String)
    case sessionName(String)
}

private struct PiUsage {
    let contextTokens: Int
    let totalTokens: Int
    let cost: Double
}

private struct PiAccumulator {
    var totalTokens = 0
    var cost = 0.0
    var contextTokens = 0
    var isEmpty: Bool { totalTokens == 0 && cost == 0 && contextTokens == 0 }

    mutating func add(_ usage: PiUsage) {
        totalTokens += usage.totalTokens
        cost += usage.cost
        contextTokens = usage.contextTokens
    }

    var snapshot: PiAccumulator { PiAccumulator(totalTokens: totalTokens, cost: cost, contextTokens: contextTokens) }
}

private struct PiSnapshot {
    let event: TurnEvent
    let prompt: String?
    let response: String?
    let baseModel: String?
    let provider: String?
    let thinking: String?
    let name: String?
    let usage: UsageSnapshot?
}

private let piMessageNeedle = Data("\"type\":\"message\"".utf8)
private let piModelChangeNeedle = Data("\"type\":\"model_change\"".utf8)
private let piThinkingNeedle = Data("\"type\":\"thinking_level_change\"".utf8)
private let piSessionInfoNeedle = Data("\"type\":\"session_info\"".utf8)

private func piTextContent(_ content: Any?) -> String? {
    if let string = content as? String { return condensedText(string) }
    guard let blocks = content as? [[String: Any]] else { return nil }
    let text = blocks
        .filter { ($0["type"] as? String) == "text" }
        .compactMap { $0["text"] as? String }
        .joined(separator: " ")
    return condensedText(text)
}

private func parsePiUsage(_ value: Any?) -> PiUsage? {
    guard let value = value as? [String: Any],
          let totalTokens = (value["total_tokens"] as? NSNumber)?.intValue ??
              (value["totalTokens"] as? NSNumber)?.intValue else { return nil }
    let input = (value["input"] as? NSNumber)?.intValue ?? 0
    let cacheRead = (value["cache_read"] as? NSNumber)?.intValue ?? (value["cacheRead"] as? NSNumber)?.intValue ?? 0
    let cacheWrite = (value["cache_write"] as? NSNumber)?.intValue ?? (value["cacheWrite"] as? NSNumber)?.intValue ?? 0
    let cost = ((value["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue ?? 0
    return PiUsage(contextTokens: input + cacheRead + cacheWrite, totalTokens: totalTokens, cost: cost)
}

private func parsePiEvent(_ line: Data) -> PiEvent? {
    let needles = [piMessageNeedle, piModelChangeNeedle, piThinkingNeedle, piSessionInfoNeedle]
    guard needles.contains(where: { line.range(of: $0) != nil }),
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let type = object["type"] as? String else { return nil }

    switch type {
    case "message":
        guard let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else { return nil }
        if role == "user" {
            guard let prompt = piTextContent(message["content"]) else { return nil }
            return .userPrompt(prompt)
        }
        if role == "assistant" {
            let blocks = (message["content"] as? [[String: Any]]) ?? []
            let text = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
            return .assistant(
                text: condensedText(text),
                model: message["model"] as? String,
                provider: message["provider"] as? String,
                stopReason: message["stopReason"] as? String ?? "",
                usage: parsePiUsage(message["usage"])
            )
        }
        return nil
    case "model_change":
        guard let model = object["modelId"] as? String else { return nil }
        return .modelChange(model: model, provider: object["provider"] as? String)
    case "thinking_level_change":
        guard let level = object["thinkingLevel"] as? String else { return nil }
        return .thinkingLevel(level)
    case "session_info":
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        return .sessionName(name)
    default:
        return nil
    }
}

private func piTurnEvent(_ event: PiEvent) -> TurnEvent? {
    switch event {
    case .userPrompt:
        return .started
    case .assistant(_, _, _, let stopReason, _):
        switch stopReason {
        case "stop", "length": return .completed
        case "aborted", "error": return .cancelled
        default: return nil
        }
    case .modelChange, .thinkingLevel, .sessionName:
        return nil
    }
}

// MARK: - opencode session parsing

private struct OpencodeMessageHeader {
    let role: String
    let completed: Bool
    let aborted: Bool
    let modelID: String?
    let variant: String?
    let contextTokens: Int
}

private func parseOpencodeMessageHeader(_ data: Data) -> OpencodeMessageHeader? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let role = object["role"] as? String else { return nil }

    let time = object["time"] as? [String: Any]
    let errorName = ((object["error"] as? [String: Any])?["name"] as? String) ?? ""
    let tokens = object["tokens"] as? [String: Any]
    let cache = tokens?["cache"] as? [String: Any]

    func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    return OpencodeMessageHeader(
        role: role,
        completed: time?["completed"] != nil,
        aborted: errorName.contains("Abort"),
        modelID: object["modelID"] as? String,
        variant: object["variant"] as? String,
        contextTokens: number(tokens?["input"]) + number(tokens?["output"])
            + number(tokens?["reasoning"]) + number(cache?["read"]) + number(cache?["write"])
    )
}

private func opencodeTurnEvent(_ header: OpencodeMessageHeader?) -> TurnEvent? {
    guard let header else { return nil }
    if header.role == "user" { return .started }
    guard header.role == "assistant" else { return nil }
    if !header.completed { return .started }
    return header.aborted ? .cancelled : .completed
}

private func opencodeModelLabel(modelID: String?, variant: String?) -> String? {
    guard let modelID, !modelID.isEmpty else { return nil }
    guard let variant, !variant.isEmpty else { return modelID }
    return "\(modelID)/\(variant)"
}

private func opencodeSessionModel(_ json: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
    return opencodeModelLabel(modelID: object["id"] as? String, variant: object["variant"] as? String)
}

private func opencodeColumnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SessionMonitor {
    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        var meta: SessionMeta
    }

    var onChange: (([ThreadActivity], UsageSnapshot?) -> Void)?
    var onCompletion: ((ThreadActivity) -> Void)?

    private let queue = DispatchQueue(label: "app.notchstatus.sessions", qos: .utility)
    private let codexHome: URL
    private let sessionsRoot: URL
    private let shellSnapshotsRoot: URL
    private let piHome: URL
    private let piSessionsRoot: URL
    private let opencodeDatabaseURL: URL
    private var streams: [FSEventStreamRef] = []
    private var cursors: [String: Cursor] = [:]
    private var activities: [String: ThreadActivity] = [:]
    private var titles: [String: String] = [:]
    private var responses: [String: String] = [:]
    private var prompts: [String: String] = [:]
    private var models: [String: String] = [:]
    private var usages: [String: UsageSnapshot] = [:]
    private var piBaseModels: [String: String] = [:]
    private var piProviders: [String: String] = [:]
    private var thinkingLevels: [String: String] = [:]
    private var piTotals: [String: PiAccumulator] = [:]
    private var piSessionNames: [String: String] = [:]
    private var piContextWindows: [String: Int] = [:]
    private var opencodeLastUpdates: [String: Int64] = [:]
    private var opencodeTitles: [String: String] = [:]
    private var accountUsage: UsageSnapshot?
    private var accountUsageUpdatedAt = Date.distantPast
    private var expiryWorkItem: DispatchWorkItem?
    private var reconciliationTimer: DispatchSourceTimer?

    init() {
        let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        codexHome = environmentHome.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        shellSnapshotsRoot = codexHome.appendingPathComponent("shell_snapshots", isDirectory: true)

        let piEnvironmentHome = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        piHome = piEnvironmentHome.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        piSessionsRoot = piHome.appendingPathComponent("sessions", isDirectory: true)

        let opencodeEnvironmentData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let opencodeDataRoot = opencodeEnvironmentData.map { URL(fileURLWithPath: $0).appendingPathComponent("opencode", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true)
        opencodeDatabaseURL = opencodeDataRoot.appendingPathComponent("opencode.db")
    }

    func start() {
        queue.async { [self] in
            titles = loadTitles()
            piContextWindows = loadPiContextWindows()
            bootstrap()
            _ = reconcileOpencode()
            startEventStreams()
            startReconciliationTimer()
            publish()
        }
    }

    func stop() {
        queue.sync { [self] in
            expiryWorkItem?.cancel()
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            for stream in streams {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            streams.removeAll()
        }
    }

    func acknowledge(codexSources: Set<String>, piSources: Set<String>, opencodeSources: Set<String>) {
        queue.async { [self] in
            var changed = false
            for (key, var activity) in activities where activity.phase == .ready {
                let sources: Set<String>
                switch activity.agent {
                case .pi: sources = piSources
                case .opencode: sources = opencodeSources
                case .codex: sources = codexSources
                }
                guard sources.contains(activity.source) else { continue }
                activity.phase = .seen
                activities[key] = activity
                changed = true
            }
            if changed { publish() }
        }
    }

    private func bootstrap() {
        for path in recentSessionPaths() {
            _ = register(path)
        }
    }

    private func recentSessionPaths() -> [String] {
        var paths: [String] = codexSessionPaths() + piSessionPaths()
        paths.removeAll { cursors[$0] != nil }
        return paths
    }

    private func codexSessionPaths() -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        var paths: [String] = []

        for dayOffset in -1...0 {
            guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            let directory = sessionsRoot.appendingPathComponent(formatter.string(from: date), isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                paths.append(file.path)
            }
        }
        return paths
    }

    private func piSessionPaths() -> [String] {
        let prefixes = recentPiDatePrefixes()
        guard !prefixes.isEmpty,
              let projects = try? FileManager.default.contentsOfDirectory(
                at: piSessionsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var paths: [String] = []
        for project in projects where project.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files
            where file.pathExtension == "jsonl" && prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
                paths.append(file.path)
            }
        }
        return paths
    }

    private func recentPiDatePrefixes() -> Set<String> {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var prefixes = Set<String>()
        for offset in -1...0 {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { continue }
            prefixes.insert(formatter.string(from: date))
            formatter.timeZone = TimeZone(identifier: "UTC")
            prefixes.insert(formatter.string(from: date))
            formatter.timeZone = nil
        }
        return prefixes
    }

    private func startReconciliationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        reconciliationTimer = timer
    }

    private func reconcile() {
        var changed = false
        for path in Set(recentSessionPaths()).union(cursors.keys) {
            changed = (cursors[path] == nil ? register(path) : readAppendedEvents(from: path)) || changed
        }
        changed = reconcileOpencode() || changed
        changed = stopOrphanedTurns() || changed
        if changed { publish() }
    }

    private func stopOrphanedTurns() -> Bool {
        let now = Date()
        var changed = false
        // ponytail: silence-based crash fallbacks; codex allows six hours, pi and
        // opencode thirty minutes because both stream turns as discrete events.
        for (key, var activity) in activities
        where shouldMarkStopped(activity.phase, updatedAt: activity.updatedAt, timeout: activity.runningTimeout, now: now) {
            activity.phase = .stopped
            activity.updatedAt = now
            activities[key] = activity
            changed = true
        }
        return changed
    }

    // MARK: - opencode reconcile

    private struct OpencodeSessionRow {
        let id: String
        let parentID: String?
        let title: String
        let directory: String
        let agentName: String
        let modelJSON: String?
        let cost: Double
        let totalTokens: Int
        let updatedAt: Date
    }

    private func reconcileOpencode() -> Bool {
        guard FileManager.default.fileExists(atPath: opencodeDatabaseURL.path) else { return false }
        return withOpencodeDatabase { database in readOpencodeSessions(database) } ?? false
    }

    private func withOpencodeDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(opencodeDatabaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 300)
        return body(database)
    }

    private func readOpencodeSessions(_ database: OpaquePointer) -> Bool {
        let cutoff = Int64(
            (Date().timeIntervalSince1970 - (opencodeRunningInactivityTimeout + 5 * 60)) * 1000
        )
        let sql = """
        SELECT id, parent_id, title, directory, agent, model, cost,
               tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
               time_updated
        FROM session
        WHERE time_archived IS NULL AND time_updated > ?1
        ORDER BY time_updated DESC
        LIMIT 12
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)

        var changed = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = opencodeColumnString(statement, 0) else { continue }
            let updatedAtMs = sqlite3_column_int64(statement, 12)
            guard opencodeLastUpdates[id] != updatedAtMs else { continue }
            opencodeLastUpdates[id] = updatedAtMs

            let totalTokens = (7...11).reduce(Int(0)) { $0 + Int(sqlite3_column_int64(statement, $1)) }
            let row = OpencodeSessionRow(
                id: id,
                parentID: opencodeColumnString(statement, 1),
                title: opencodeColumnString(statement, 2) ?? "",
                directory: opencodeColumnString(statement, 3) ?? "",
                agentName: opencodeColumnString(statement, 4) ?? "build",
                modelJSON: opencodeColumnString(statement, 5),
                cost: sqlite3_column_double(statement, 6),
                totalTokens: totalTokens,
                updatedAt: Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
            )
            changed = applyOpencodeSession(row, database: database) || changed
        }
        return changed
    }

    private func applyOpencodeSession(_ row: OpencodeSessionRow, database: OpaquePointer) -> Bool {
        let messages = opencodeRecentMessages(database, sessionID: row.id)
        guard let event = opencodeTurnEvent(messages.first?.header) else { return false }

        var prompt: String?
        var response: String?
        var model: String?
        var contextTokens = 0
        if let userIndex = messages.firstIndex(where: { $0.header.role == "user" }) {
            prompt = opencodeTextParts(database, messageID: messages[userIndex].id)
            for message in messages[..<userIndex] {
                if model == nil { model = opencodeModelLabel(modelID: message.header.modelID, variant: message.header.variant) }
                if contextTokens == 0 { contextTokens = message.header.contextTokens }
                if response == nil { response = opencodeTextParts(database, messageID: message.id) }
            }
        }
        if model == nil, let modelJSON = row.modelJSON { model = opencodeSessionModel(modelJSON) }

        let key = "opencode:\(row.id)"
        var phase: ThreadPhase
        switch event {
        case .started: phase = .running
        case .completed: phase = .ready
        case .cancelled: phase = .stopped
        }
        if phase == .running,
           shouldMarkStopped(.running, updatedAt: row.updatedAt, timeout: opencodeRunningInactivityTimeout) {
            phase = .stopped
        }
        let previousPhase = activities[key]?.phase
        if previousPhase == .seen, phase == .ready { phase = .seen }

        let meta = SessionMeta(
            id: row.id,
            agent: .opencode,
            parentID: row.parentID,
            nickname: row.agentName == "build" ? nil : row.agentName,
            source: "cli",
            project: URL(fileURLWithPath: row.directory).lastPathComponent
        )

        if previousPhase == .running, phase == .ready, meta.parentID == nil {
            let completed = activity(for: meta, phase: .ready, at: row.updatedAt)
            DispatchQueue.main.async { [weak self] in self?.onCompletion?(completed) }
        }

        if prompt == nil { prompts.removeValue(forKey: key) } else { prompts[key] = prompt }
        if response == nil { responses.removeValue(forKey: key) } else { responses[key] = response }
        if model == nil { models.removeValue(forKey: key) } else { models[key] = model }
        if row.totalTokens > 0 || row.cost > 0 {
            usages[key] = UsageSnapshot(
                totalTokens: row.totalTokens,
                contextTokens: contextTokens,
                contextWindow: 0,
                primaryLimit: nil,
                secondaryLimit: nil,
                costTotal: row.cost
            )
        } else {
            usages.removeValue(forKey: key)
        }
        if !row.title.isEmpty { opencodeTitles[key] = row.title }

        guard shouldRetain(phase, updatedAt: row.updatedAt) else {
            return activities.removeValue(forKey: key) != nil
        }
        activities[key] = activity(for: meta, phase: phase, at: row.updatedAt)
        return true
    }

    private func opencodeRecentMessages(
        _ database: OpaquePointer,
        sessionID: String
    ) -> [(id: String, header: OpencodeMessageHeader)] {
        let sql = "SELECT id, data FROM message WHERE session_id = ?1 ORDER BY time_created DESC, rowid DESC LIMIT 8"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient)

        var messages: [(String, OpencodeMessageHeader)] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = opencodeColumnString(statement, 0),
              let data = opencodeColumnString(statement, 1),
              let header = parseOpencodeMessageHeader(Data(data.utf8)) {
            messages.append((id, header))
        }
        return messages
    }

    private func opencodeTextParts(_ database: OpaquePointer, messageID: String) -> String? {
        let sql = "SELECT substr(data,1,65536) FROM part WHERE message_id = ?1 ORDER BY rowid"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, messageID, -1, sqliteTransient)

        var fragments: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let data = opencodeColumnString(statement, 0),
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              (object["type"] as? String) == "text",
              let text = object["text"] as? String {
            fragments.append(text)
        }
        return condensedText(fragments.joined(separator: " "))
    }

    private func startEventStreams() {
        for root in [sessionsRoot, piSessionsRoot]
        where FileManager.default.fileExists(atPath: root.path) {
            startEventStream(forRoot: root)
        }
    }

    private func startEventStream(forRoot root: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, pathsPointer, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            monitor.consume(paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streams.append(stream)
    }

    private func consume(_ paths: [String]) {
        var changed = false
        let visibleIDs = Set(activities.keys)
        let pathsToRefresh = Set(paths.filter { $0.hasSuffix(".jsonl") }).union(
            cursors.compactMap { visibleIDs.contains($0.value.meta.key) ? $0.key : nil }
        )

        for path in pathsToRefresh {
            if cursors[path] == nil {
                changed = register(path) || changed
            } else {
                changed = readAppendedEvents(from: path) || changed
            }
        }

        if changed { publish() }
    }

    @discardableResult
    private func register(_ path: String) -> Bool {
        guard var meta = readMeta(at: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let fileSize = values.fileSize else { return false }

        if meta.agent == .codex { meta.source = currentSource(for: meta) }
        cursors[path] = Cursor(offset: UInt64(fileSize), meta: meta)

        let key = meta.key
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let snapshot: SessionSnapshot?

        if meta.agent == .pi {
            guard let piSnapshot = latestPiSnapshot(at: path) else { return false }
            if let base = piSnapshot.baseModel { piBaseModels[key] = base }
            if let provider = piSnapshot.provider { piProviders[key] = provider }
            if let thinking = piSnapshot.thinking { thinkingLevels[key] = thinking }
            let label = piModelLabel(key)
            if !label.isEmpty { models[key] = label }
            if let name = piSnapshot.name { piSessionNames[key] = name }
            if let usage = piSnapshot.usage {
                usages[key] = usage
                piTotals[key] = PiAccumulator(
                    totalTokens: usage.totalTokens,
                    cost: usage.costTotal ?? 0,
                    contextTokens: usage.contextTokens
                )
            }
            snapshot = SessionSnapshot(
                event: piSnapshot.event,
                response: piSnapshot.response,
                prompt: piSnapshot.prompt,
                model: label.isEmpty ? nil : label,
                usage: piSnapshot.usage,
                name: piSnapshot.name
            )
        } else {
            snapshot = latestCodexSnapshot(at: path)
        }

        guard let snapshot else { return false }
        if let response = snapshot.response { responses[key] = response }
        if let prompt = snapshot.prompt { prompts[key] = prompt }
        if let model = snapshot.model { models[key] = model }
        if let usage = snapshot.usage { usages[key] = usage }
        if meta.agent == .codex, let usage = snapshot.usage, modifiedAt > accountUsageUpdatedAt {
            accountUsage = usage
            accountUsageUpdatedAt = modifiedAt
        }
        let phase: ThreadPhase
        switch snapshot.event {
        case .started: phase = .running
        case .completed: phase = .ready
        case .cancelled: phase = .stopped
        }
        guard shouldRetain(phase, updatedAt: modifiedAt) else { return false }

        activities[key] = activity(for: meta, phase: phase, at: modifiedAt)
        return true
    }

    private func readAppendedEvents(from path: String) -> Bool {
        guard var cursor = cursors[path],
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return false }

        if size < cursor.offset {
            cursors.removeValue(forKey: path)
            return register(path)
        }
        guard size > cursor.offset,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }

        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            guard let appended = try handle.readToEnd() else { return false }
            cursor.offset = size
            cursor.remainder.append(appended)

            let endsWithNewline = cursor.remainder.last == 0x0A
            let parts = cursor.remainder.split(separator: 0x0A, omittingEmptySubsequences: false)
            let completeCount = endsWithNewline ? parts.count : max(0, parts.count - 1)
            var changed = false

            for part in parts.prefix(completeCount) {
                let line = Data(part)
                if cursor.meta.agent == .pi {
                    changed = applyPiEvent(parsePiEvent(line), for: cursor.meta) || changed
                    continue
                }
                if let prompt = parsePrompt(line) {
                    prompts[cursor.meta.key] = prompt
                    changed = refreshActivity(for: cursor.meta) || changed
                    continue
                }
                if let response = parseResponse(line) {
                    responses[cursor.meta.key] = response
                    changed = refreshActivity(for: cursor.meta) || changed
                    continue
                }
                if let model = parseModel(line) {
                    models[cursor.meta.key] = model
                    changed = refreshActivity(for: cursor.meta) || changed
                    continue
                }
                if let usage = parseUsage(line) {
                    usages[cursor.meta.key] = usage
                    accountUsage = usage
                    accountUsageUpdatedAt = Date()
                    _ = refreshActivity(for: cursor.meta)
                    changed = true
                    continue
                }
                guard let event = parseTurnEvent(line) else { continue }
                titles = loadTitles()
                switch event {
                case .started:
                    cursor.meta.source = currentSource(for: cursor.meta)
                    responses.removeValue(forKey: cursor.meta.key)
                    prompts.removeValue(forKey: cursor.meta.key)
                    models.removeValue(forKey: cursor.meta.key)
                    usages.removeValue(forKey: cursor.meta.key)
                    activities[cursor.meta.key] = activity(for: cursor.meta, phase: .running, at: Date())
                case .completed:
                    let completed = activity(for: cursor.meta, phase: .ready, at: Date())
                    if activities[cursor.meta.key]?.phase == .running, cursor.meta.parentID == nil {
                        DispatchQueue.main.async { [weak self] in self?.onCompletion?(completed) }
                    }
                    activities[cursor.meta.key] = completed
                case .cancelled:
                    activities[cursor.meta.key] = activity(for: cursor.meta, phase: .stopped, at: Date())
                }
                changed = true
            }

            cursor.remainder = endsWithNewline ? Data() : Data(parts.last ?? Data.SubSequence())
            cursors[path] = cursor
            return changed
        } catch {
            return false
        }
    }

    @discardableResult
    private func applyPiEvent(_ event: PiEvent?, for meta: SessionMeta) -> Bool {
        guard let event else { return false }
        let key = meta.key

        switch event {
        case .userPrompt(let prompt):
            titles = loadTitles()
            piContextWindows = loadPiContextWindows()
            prompts[key] = prompt
            responses.removeValue(forKey: key)
            activities[key] = activity(for: meta, phase: .running, at: Date())
        case .assistant(let text, let model, let provider, let stopReason, let usage):
            if let text { responses[key] = text }
            if let model {
                piBaseModels[key] = model
                if let provider { piProviders[key] = provider }
                models[key] = piModelLabel(key)
            }
            if let usage {
                var accumulator = piTotals[key] ?? PiAccumulator()
                accumulator.add(usage)
                piTotals[key] = accumulator
                usages[key] = buildPiUsage(key)
            }
            switch stopReason {
            case "stop", "length":
                let completed = activity(for: meta, phase: .ready, at: Date())
                if activities[key]?.phase == .running {
                    DispatchQueue.main.async { [weak self] in self?.onCompletion?(completed) }
                }
                activities[key] = completed
            case "aborted", "error":
                activities[key] = activity(for: meta, phase: .stopped, at: Date())
            default:
                _ = refreshActivity(for: meta)
            }
        case .modelChange(let model, let provider):
            piBaseModels[key] = model
            if let provider { piProviders[key] = provider }
            models[key] = piModelLabel(key)
            _ = refreshActivity(for: meta)
        case .thinkingLevel(let level):
            thinkingLevels[key] = level
            models[key] = piModelLabel(key)
            _ = refreshActivity(for: meta)
        case .sessionName(let name):
            piSessionNames[key] = name
            _ = refreshActivity(for: meta)
        }
        return true
    }

    private func piModelLabel(_ key: String) -> String {
        let base = piBaseModels[key] ?? ""
        guard let level = thinkingLevels[key], !level.isEmpty, level != "off" else { return base }
        return base.isEmpty ? level : "\(base)/\(level)"
    }

    private func buildPiUsage(_ key: String) -> UsageSnapshot {
        let accumulator = piTotals[key] ?? PiAccumulator()
        let base = piBaseModels[key] ?? ""
        let provider = piProviders[key].map { "\($0)/\(base)" } ?? base
        return UsageSnapshot(
            totalTokens: accumulator.totalTokens,
            contextTokens: accumulator.contextTokens,
            contextWindow: piContextWindows[provider] ?? piContextWindows[base] ?? 0,
            primaryLimit: nil,
            secondaryLimit: nil,
            costTotal: accumulator.cost
        )
    }

    private func refreshActivity(for meta: SessionMeta) -> Bool {
        guard let current = activities[meta.key] else { return false }
        activities[meta.key] = activity(for: meta, phase: current.phase, at: Date())
        return true
    }

    private func latestCodexSnapshot(at path: String) -> SessionSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        var position = size
        var carry = Data()
        var latestEvent: TurnEvent?
        var response: String?
        var prompt: String?
        var model: String?
        var usage: UsageSnapshot?

        while position > 0 {
            let count = min(chunkSize, position)
            position -= count

            do {
                try handle.seek(toOffset: position)
                var buffer = try handle.read(upToCount: Int(count)) ?? Data()
                buffer.append(carry)
                let parts = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
                let firstComplete = position == 0 ? 0 : min(1, parts.count)

                for part in parts.dropFirst(firstComplete).reversed() {
                    let line = Data(part)
                    if response == nil { response = parseResponse(line) }
                    if prompt == nil { prompt = parsePrompt(line) }
                    if model == nil { model = parseModel(line) }
                    if usage == nil { usage = parseUsage(line) }
                    if let event = parseTurnEvent(line) {
                        if latestEvent == nil { latestEvent = event }
                        if event == .started, let latestEvent {
                            return SessionSnapshot(
                                event: latestEvent,
                                response: response,
                                prompt: prompt,
                                model: model,
                                usage: usage,
                                name: nil
                            )
                        }
                    }
                }
                carry = parts.first.map { Data($0) } ?? Data()
            } catch {
                return nil
            }
        }
        return latestEvent.map {
            SessionSnapshot(event: $0, response: response, prompt: prompt, model: model, usage: usage, name: nil)
        }
    }

    private func latestPiSnapshot(at path: String) -> PiSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let cap: UInt64 = 32 * 1024 * 1024
        guard size > 0,
              (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.read(upToCount: Int(min(size, cap))) else { return nil }

        var event: TurnEvent?
        var prompt: String?
        var response: String?
        var baseModel: String?
        var provider: String?
        var thinking: String?
        var name: String?
        var accumulator = PiAccumulator()

        for chunk in data.split(separator: 0x0A) {
            guard let entry = parsePiEvent(Data(chunk)) else { continue }
            switch entry {
            case .userPrompt(let text):
                prompt = text
                event = .started
            case .assistant(let text, let model, let entryProvider, _, let usage):
                if let text { response = text }
                if let model { baseModel = model }
                if let entryProvider { provider = entryProvider }
                if let usage { accumulator.add(usage) }
                if let turnEvent = piTurnEvent(entry) { event = turnEvent }
            case .modelChange(let model, let entryProvider):
                baseModel = model
                if let entryProvider { provider = entryProvider }
            case .thinkingLevel(let level):
                thinking = level
            case .sessionName(let sessionName):
                name = sessionName
            }
        }

        guard event != nil || prompt != nil else { return nil }
        let usage = accumulator.isEmpty ? nil : UsageSnapshot(
            totalTokens: accumulator.totalTokens,
            contextTokens: accumulator.contextTokens,
            contextWindow: piContextWindows[provider.map { "\($0)/\(baseModel ?? "")" } ?? ""]
                ?? piContextWindows[baseModel ?? ""] ?? 0,
            primaryLimit: nil,
            secondaryLimit: nil,
            costTotal: accumulator.cost
        )
        return PiSnapshot(
            event: event ?? .started,
            prompt: prompt,
            response: response,
            baseModel: baseModel,
            provider: provider,
            thinking: thinking,
            name: name,
            usage: usage
        )
    }

    private func readMeta(at path: String) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: 1_048_576),
              let firstLine = prefix.split(separator: 0x0A, maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        if type == "session" {
            guard let id = object["id"] as? String else { return nil }
            let cwd = object["cwd"] as? String ?? ""
            return SessionMeta(
                id: id,
                agent: .pi,
                parentID: nil,
                nickname: nil,
                source: "cli",
                project: URL(fileURLWithPath: cwd).lastPathComponent
            )
        }

        guard type == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }

        let cwd = payload["cwd"] as? String ?? ""
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let originator = payload["originator"] as? String ?? ""
        let sourceObject = payload["source"] as? [String: Any]
        let subagent = sourceObject?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let source = payload["source"] as? String ?? payload["thread_source"] as? String ?? "cli"
        return SessionMeta(
            id: id,
            agent: .codex,
            parentID: payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String,
            nickname: spawn?["agent_nickname"] as? String ?? subagent?["other"] as? String,
            source: sourceLabel(source, originator: originator),
            project: project
        )
    }

    private func currentSource(for meta: SessionMeta) -> String {
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: shellSnapshotsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ),
        let latest = snapshots
            .filter({ $0.lastPathComponent.hasPrefix("\(meta.id).") && $0.pathExtension == "sh" })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
        let data = try? Data(contentsOf: latest) else { return meta.source }

        let snapshot = String(decoding: data, as: UTF8.self).lowercased()
        if snapshot.contains("codex_internal_originator_override=codex_vscode")
            || snapshot.contains("__cfbundleidentifier=com.microsoft.vscode") { return "extension" }
        if snapshot.contains("codex_internal_originator_override='codex desktop'")
            || snapshot.contains("__cfbundleidentifier=com.openai.codex") { return "codex" }
        return "cli"
    }

    private func loadTitles() -> [String: String] {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: index) else { return [:] }

        var result: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !title.isEmpty else { continue }
            result[id] = title
        }
        return result
    }

    private func loadPiContextWindows() -> [String: Int] {
        let store = piHome.appendingPathComponent("models-store.json")
        guard let data = try? Data(contentsOf: store),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var result: [String: Int] = [:]
        for (provider, value) in object {
            guard let models = (value as? [String: Any])?["models"] as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String,
                      let window = (model["contextWindow"] as? NSNumber)?.intValue else { continue }
                result["\(provider)/\(id)"] = window
                result[id] = window
            }
        }
        return result
    }

    private func activity(for meta: SessionMeta, phase: ThreadPhase, at date: Date) -> ThreadActivity {
        ThreadActivity(
            id: meta.id,
            agent: meta.agent,
            parentID: meta.parentID,
            nickname: meta.nickname,
            title: (meta.agent == .opencode
                ? opencodeTitles[meta.key] ?? prompts[meta.key]
                : prompts[meta.key]
                    ?? (meta.agent == .pi ? piSessionNames[meta.key] : titles[meta.key]))
                ?? (meta.project.isEmpty ? "\(meta.agent.displayName) thread" : meta.project),
            detail: responses[meta.key] ?? "",
            source: meta.source,
            project: meta.project,
            model: models[meta.key] ?? "",
            usage: usages[meta.key],
            phase: phase,
            updatedAt: date
        )
    }

    private func sourceLabel(_ source: String, originator: String) -> String {
        let origin = originator.lowercased()
        if origin.contains("desktop") { return "codex" }
        if origin.contains("vscode") { return "extension" }
        if origin.contains("tui") || origin.contains("cli") { return "cli" }

        switch source {
        case "vscode": return "extension"
        case "cli": return "cli"
        case "app", "desktop": return "codex"
        default: return "codex"
        }
    }

    private func publish() {
        let now = Date()
        activities = activities.filter { shouldRetain($0.value.phase, updatedAt: $0.value.updatedAt, now: now) }
        scheduleExpiry()
        let snapshot = activities.values.sorted {
            if phaseRank($0.phase) != phaseRank($1.phase) {
                return phaseRank($0.phase) < phaseRank($1.phase)
            }
            return $0.updatedAt > $1.updatedAt
        }
        let usage = accountUsage
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot, usage) }
    }

    private func scheduleExpiry() {
        expiryWorkItem?.cancel()
        guard let nextExpiry = activities.values
            .filter({ $0.phase != .running })
            .map({ $0.updatedAt.addingTimeInterval(activityRetention) })
            .min() else { return }

        let work = DispatchWorkItem { [weak self] in self?.publish() }
        expiryWorkItem = work
        queue.asyncAfter(deadline: .now() + max(0.1, nextExpiry.timeIntervalSinceNow), execute: work)
    }
}

private struct ActivityGroup {
    let root: ThreadActivity
    let children: [ThreadActivity]
    let phase: ThreadPhase
    let updatedAt: Date
}

private struct ActivityRow {
    let activity: ThreadActivity
    let phase: ThreadPhase
    let depth: Int
    let childCount: Int
}

private func groupActivities(_ activities: [ThreadActivity]) -> [ActivityGroup] {
    let byID = Dictionary(uniqueKeysWithValues: activities.map { ($0.key, $0) })

    func rootID(for activity: ThreadActivity) -> String {
        var current = activity
        var hops = 0
        while let parentID = current.parentID, hops < 10 {
            let parentKey = "\(current.agent.label):\(parentID)"
            guard let parent = byID[parentKey] else { return parentKey }
            current = parent
            hops += 1
        }
        return current.key
    }

    let grouped = Dictionary(grouping: activities, by: rootID)
    return grouped.map { key, members in
        let root = byID[key] ?? members.max(by: { $0.updatedAt < $1.updatedAt })!
        let children = members.filter { $0.id != root.id }.sorted { $0.updatedAt > $1.updatedAt }
        return ActivityGroup(
            root: root,
            children: children,
            phase: members.min(by: { phaseRank($0.phase) < phaseRank($1.phase) })?.phase ?? root.phase,
            updatedAt: members.map(\.updatedAt).max() ?? root.updatedAt
        )
    }.sorted {
        phaseRank($0.phase) == phaseRank($1.phase)
            ? $0.updatedAt > $1.updatedAt
            : phaseRank($0.phase) < phaseRank($1.phase)
    }
}

private func compactTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return "\(value / 1_000)k" }
    return "\(value)"
}

private func compactPercent(_ value: Double) -> String {
    let hundredths = Int((value * 100).rounded())
    if hundredths % 100 == 0 { return "\(hundredths / 100)" }
    if hundredths % 10 == 0 { return String(format: "%.1f", Double(hundredths) / 100) }
    return String(format: "%.2f", Double(hundredths) / 100)
}

private func relativeAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86_400)d"
}

private func rateWindowLabel(_ minutes: Int) -> String {
    if minutes == 10_080 { return "wk" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
}

private func nextReset(in usage: UsageSnapshot?) -> RateLimitUsage? {
    [usage?.primaryLimit, usage?.secondaryLimit]
        .compactMap { $0 }
        .compactMap { limit in limit.resetsAt.map { (limit, $0) } }
        .min { $0.1 < $1.1 }?.0
}

private func usageSummary(_ usage: UsageSnapshot?) -> String {
    guard let usage else { return "" }
    var parts: [String] = []
    if usage.contextWindow > 0 {
        parts.append("ctx \(Int((100 * Double(usage.contextTokens) / Double(usage.contextWindow)).rounded()))%")
    }
    parts.append("\(compactTokens(usage.totalTokens)) tok")
    return parts.joined(separator: " · ")
}

private func remainingUsageSummary(_ usage: UsageSnapshot?) -> String {
    guard let usage else { return "usage unavailable" }
    var parts = [usage.primaryLimit, usage.secondaryLimit].compactMap { $0 }
        .sorted { $0.windowMinutes < $1.windowMinutes }
        .map { "\(rateWindowLabel($0.windowMinutes)) \(compactPercent(max(0, 100 - $0.usedPercent)))% left" }
    if let date = nextReset(in: usage)?.resetsAt {
        parts.append("reset \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
    }
    return parts.joined(separator: " · ")
}

private func piUsageSummary(_ activities: [ThreadActivity]) -> String {
    let piActivities = activities.filter { $0.agent == .pi }
    guard !piActivities.isEmpty else { return "" }
    let tokens = piActivities.compactMap { $0.usage?.totalTokens }.reduce(0, +)
    let cost = piActivities.compactMap { $0.usage?.costTotal }.reduce(0, +)
    var parts = ["pi \(compactTokens(tokens)) tok"]
    if cost > 0 { parts.append("$\(String(format: "%.2f", cost))") }
    return parts.joined(separator: " · ")
}

private func opencodeUsageSummary(_ activities: [ThreadActivity]) -> String {
    let opencodeActivities = activities.filter { $0.agent == .opencode }
    guard !opencodeActivities.isEmpty else { return "" }
    let tokens = opencodeActivities.compactMap { $0.usage?.totalTokens }.reduce(0, +)
    let cost = opencodeActivities.compactMap { $0.usage?.costTotal }.reduce(0, +)
    var parts = ["oc \(compactTokens(tokens)) tok"]
    if cost > 0 { parts.append("$\(String(format: "%.2f", cost))") }
    return parts.joined(separator: " · ")
}

private enum Palette {
    static let notchBlack = NSColor.black
    static let pacYellow = NSColor(srgbRed: 1, green: 0.82, blue: 0.18, alpha: 1)
    static let readyGreen = NSColor(srgbRed: 0.37, green: 0.88, blue: 0.38, alpha: 1)
    static let stoppedOrange = NSColor(srgbRed: 0.96, green: 0.32, blue: 0.16, alpha: 1)
    static let ghostPurple = NSColor(srgbRed: 0.64, green: 0.48, blue: 0.92, alpha: 1)
    static let vscodeBlue = NSColor(srgbRed: 0, green: 0.48, blue: 0.80, alpha: 1)
    static let piCyan = NSColor(srgbRed: 0.22, green: 0.78, blue: 0.96, alpha: 1)
    static let ocSilver = NSColor(srgbRed: 0.66, green: 0.65, blue: 0.64, alpha: 1)
    static let phosphor = NSColor(white: 0.94, alpha: 1)
    static let tertiaryInk = NSColor(white: 0.46, alpha: 1)
    static let mutedInk = NSColor(white: 0.29, alpha: 1)
}

private final class IslandView: NSView {
    var onExpansionChange: ((Bool) -> Void)?
    private(set) var expanded = false
    private var activities: [ThreadActivity] = []
    private var accountUsage: UsageSnapshot?
    private var topBandHeight: CGFloat = 32
    private var physicalNotchWidth: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var disclosureButtons: [String: NSButton] = [:]
    private var expandedGroupIDs = Set<String>()
    private var mouthOpen = true
    private var pacmanProgress: CGFloat = 0
    private let rowHeight: CGFloat = 58
    private let footerHeight: CGFloat = 26
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent status")
        setAccessibilityHelp("Hover or click to show Codex, Pi and opencode session details")
    }

    required init?(coder: NSCoder) { nil }

    func update(activities: [ThreadActivity], accountUsage: UsageSnapshot?) {
        self.activities = activities
        self.accountUsage = accountUsage
        expandedGroupIDs.formIntersection(groupActivities(activities).map(\.root.id))
        syncDisclosureButtons()
        updateAnimationTimer()
        updateAccessibilityValue()
        needsDisplay = true
    }

    func setTopBandHeight(_ height: CGFloat) {
        topBandHeight = height
        needsDisplay = true
    }

    func setPhysicalNotchWidth(_ width: CGFloat) {
        physicalNotchWidth = width
        needsDisplay = true
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else {
            if value { schedulePointerCheck() }
            return
        }
        expanded = value
        if value {
            schedulePointerCheck()
        } else {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
        }
        syncDisclosureButtons()
        needsDisplay = true
        onExpansionChange?(value)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateExpansion(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateExpansion(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        schedulePointerCheck()
    }

    private func updateExpansion(for event: NSEvent) {
        guard islandPath().contains(convert(event.locationInWindow, from: nil)) else {
            schedulePointerCheck()
            return
        }
        setExpanded(true)
    }

    private func schedulePointerCheck() {
        guard expanded else { return }
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, expanded else { return }
            if pointerIsInsideIsland {
                schedulePointerCheck()
            } else {
                setExpanded(false)
            }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private var pointerIsInsideIsland: Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return islandPath().contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard islandPath().contains(point) else {
            if expanded { setExpanded(false) }
            return
        }
        setExpanded(!expanded)
    }

    override func layout() {
        super.layout()
        syncDisclosureButtons()
    }

    var visibleRowCount: Int { visibleRows.count }
    var expandedContentHeight: CGFloat { CGFloat(max(1, visibleRowCount)) * rowHeight + footerHeight + 10 }

    private var visibleRows: [ActivityRow] {
        var rows: [ActivityRow] = []
        for group in groupActivities(activities).prefix(5) where rows.count < 8 {
            rows.append(ActivityRow(
                activity: group.root,
                phase: group.phase,
                depth: 0,
                childCount: group.children.count
            ))
            if expandedGroupIDs.contains(group.root.id) {
                for child in group.children where rows.count < 8 {
                    rows.append(ActivityRow(activity: child, phase: child.phase, depth: 1, childCount: 0))
                }
            }
        }
        return rows
    }

    private func syncDisclosureButtons() {
        let rows = visibleRows
        let groupIDs = Set(groupActivities(activities).filter { !$0.children.isEmpty }.map(\.root.id))
        for id in disclosureButtons.keys.filter({ !groupIDs.contains($0) }) {
            disclosureButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in groupIDs where disclosureButtons[id] == nil {
            let button = NSButton(title: "", target: self, action: #selector(toggleGroup(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.isBordered = false
            button.focusRingType = .none
            button.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
            button.contentTintColor = Palette.vscodeBlue
            addSubview(button)
            disclosureButtons[id] = button
        }
        for button in disclosureButtons.values { button.isHidden = true }
        guard expanded else { return }
        let bodyRight = bounds.maxX - bodyInset
        for (index, row) in rows.enumerated() where row.depth == 0 && row.childCount > 0 {
            let button = disclosureButtons[row.activity.id]!
            button.title = "\(expandedGroupIDs.contains(row.activity.id) ? "▾" : "▸") \(row.childCount)"
            button.toolTip = "\(row.childCount) subagent\(row.childCount == 1 ? "" : "s")"
            button.setAccessibilityLabel(button.toolTip)
            button.frame = NSRect(
                x: bodyRight - 116,
                y: bounds.maxY - topBandHeight - CGFloat(index) * rowHeight - 25,
                width: 46,
                height: 18
            )
            button.isHidden = false
        }
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedGroupIDs.contains(id) { expandedGroupIDs.remove(id) } else { expandedGroupIDs.insert(id) }
        syncDisclosureButtons()
        needsDisplay = true
        onExpansionChange?(true)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "Quit Notch Status", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        Palette.notchBlack.setFill()
        let path = islandPath()
        path.fill()
        path.addClip()

        let progress = expansionProgress
        if progress < 1 {
            context.saveGState()
            context.setAlpha(1 - progress)
            drawCollapsed()
            context.restoreGState()
        }
        if progress > 0 {
            context.saveGState()
            context.setAlpha(progress)
            drawExpanded()
            context.restoreGState()
        }
    }

    private func drawCollapsed() {
        let centerY = bounds.maxY - topBandHeight / 2
        let bodyLeft = bounds.minX + bodyInset
        let bodyRight = bounds.maxX - bodyInset
        let groups = groupActivities(activities)
        let runningCount = groups.filter { $0.phase == .running }.count
        drawText(
            String(runningCount),
            in: NSRect(x: bodyLeft + 14, y: centerY - 8, width: 28, height: 16),
            font: .monospacedSystemFont(ofSize: 13, weight: .bold),
            color: runningCount > 0 ? Palette.phosphor : Palette.tertiaryInk
        )

        if runningCount > 0 {
            let runningAgents = Set(groups.filter { $0.phase == .running }.map(\.root.agent))
            let track = visiblePacmanTrack(
                in: bounds,
                bodyInset: bodyInset,
                physicalNotchWidth: physicalNotchWidth
            )
            let pacmanX = track.lowerBound + (track.upperBound - track.lowerBound) * pacmanProgress
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bodyRight - 10 - bounds.minX,
                height: bounds.height
            )).addClip()
            drawDots(after: pacmanX, from: track.lowerBound + 9, through: track.upperBound, y: centerY)
            let lead: AgentKind = runningAgents.contains(.codex)
                ? .codex
                : (runningAgents.contains(.pi) ? .pi : .opencode)
            drawAgentSprite(agent: lead, at: NSPoint(x: pacmanX, y: centerY), pixel: 2, color: Palette.pacYellow, running: true)
            var trailX = pacmanX - 16
            for agent in [AgentKind.codex, .pi, .opencode]
            where agent != lead && runningAgents.contains(agent) {
                drawAgentSprite(
                    agent: agent,
                    at: NSPoint(x: max(track.lowerBound, trailX), y: centerY),
                    pixel: 2,
                    color: Palette.pacYellow,
                    running: true
                )
                trailX -= 14
            }
            NSGraphicsContext.restoreGraphicsState()
            setAccessibilityHelp("Agent is working")
        } else if let stopped = groups.first(where: { $0.phase == .stopped }) {
            drawAgentSprite(
                agent: stopped.root.agent,
                at: NSPoint(x: bodyRight - 20, y: centerY),
                pixel: 2,
                color: Palette.stoppedOrange,
                running: false
            )
            setAccessibilityHelp("\(stopped.root.title) stopped")
        } else if let ready = groups.first(where: { $0.phase == .ready }) {
            drawAgentSprite(
                agent: ready.root.agent,
                at: NSPoint(x: bodyRight - 20, y: centerY),
                pixel: 2,
                color: Palette.readyGreen,
                running: false
            )
            setAccessibilityHelp("\(ready.root.title) is complete")
        } else {
            Palette.ghostPurple.setFill()
            NSBezierPath(ovalIn: NSRect(x: bodyRight - 18, y: centerY - 2, width: 4, height: 4)).fill()
            setAccessibilityHelp("No active agent turns")
        }
    }

    private func drawExpanded() {
        let bodyLeft = bounds.minX + bodyInset
        let bodyRight = bounds.maxX - bodyInset
        let rows = visibleRows
        drawFooter(bodyLeft: bodyLeft, bodyRight: bodyRight)
        if rows.isEmpty {
            drawText(
                "No active agent turns",
                in: NSRect(x: bodyLeft + 16, y: footerHeight + 22, width: bodyRight - bodyLeft - 32, height: 14),
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                color: Palette.mutedInk
            )
            return
        }

        for (index, row) in rows.enumerated() {
            let activity = row.activity
            let rowTop = bounds.maxY - topBandHeight - CGFloat(index) * rowHeight
            let centerY = rowTop - 18
            let color = statusColor(for: row.phase)
            let textX = bodyLeft + 35 + CGFloat(row.depth) * 18
            let status = statusText(for: row.phase)
            let statusWidth: CGFloat = 58
            let statusX = bodyRight - statusWidth - 10
            let titleRight = row.childCount > 0 ? bodyRight - 122 : status.isEmpty ? bodyRight - 16 : statusX - 4
            let title = row.depth > 0 ? activity.nickname ?? activity.title : activity.title
            let metadata = [
                String(activity.project.prefix(18)),
                activity.model,
                usageSummary(activity.usage),
                relativeAge(activity.updatedAt),
            ].filter { !$0.isEmpty }.joined(separator: " · ")
            drawAgentSprite(
                agent: activity.agent,
                at: NSPoint(x: bodyLeft + 16 + CGFloat(row.depth) * 18, y: centerY),
                pixel: 2,
                color: color,
                running: row.phase == .running
            )
            drawText(
                title,
                in: NSRect(x: textX, y: rowTop - 24, width: max(60, titleRight - textX), height: 16),
                font: .monospacedSystemFont(ofSize: 12, weight: .bold),
                color: Palette.phosphor
            )
            drawText(
                status,
                in: NSRect(x: statusX, y: rowTop - 23, width: statusWidth, height: 14),
                font: .monospacedSystemFont(ofSize: 9, weight: .bold),
                color: color,
                alignment: .right
            )
            drawText(
                activity.detail,
                in: NSRect(x: textX, y: rowTop - 40, width: bodyRight - textX - 10, height: 12),
                font: .monospacedSystemFont(ofSize: 9, weight: .medium),
                color: Palette.tertiaryInk
            )
            drawSourceMarker(agent: activity.agent, source: activity.source, in: NSRect(x: textX, y: rowTop - 53, width: 9, height: 9))
            drawText(
                metadata,
                in: NSRect(x: textX + 14, y: rowTop - 56, width: bodyRight - textX - 24, height: 12),
                font: .monospacedSystemFont(ofSize: 8.5, weight: .medium),
                color: Palette.mutedInk
            )
        }
    }

    private func drawFooter(bodyLeft: CGFloat, bodyRight: CGFloat) {
        Palette.mutedInk.withAlphaComponent(0.3).setFill()
        NSRect(x: bodyLeft + 12, y: footerHeight + 5, width: bodyRight - bodyLeft - 24, height: 1).fill()

        var parts = [piUsageSummary(activities), opencodeUsageSummary(activities)].filter { !$0.isEmpty }
        if parts.isEmpty {
            parts = [remainingUsageSummary(accountUsage)]
        } else if accountUsage != nil {
            parts.append(remainingUsageSummary(accountUsage))
        }
        drawText(
            parts.joined(separator: " · "),
            in: NSRect(x: bodyLeft + 12, y: 11, width: bodyRight - bodyLeft - 24, height: 12),
            font: .monospacedSystemFont(ofSize: 8.5, weight: .medium),
            color: Palette.tertiaryInk,
            alignment: .center
        )
    }

    private var expansionProgress: CGFloat {
        min(1, max(0, (bounds.height - topBandHeight) / expandedContentHeight))
    }

    private var bodyInset: CGFloat { 12 + 18 * expansionProgress }

    private func islandPath() -> NSBezierPath {
        let neckHeight = 8 + 2 * expansionProgress
        let neckInset = neckHeight * 0.55
        let bottomRadius = 13 + 9 * expansionProgress
        let k: CGFloat = 0.552_284_8
        let topY = bounds.maxY
        let neckY = topY - neckHeight
        let bodyLeft = bounds.minX + bodyInset
        let bodyRight = bounds.maxX - bodyInset
        let path = NSBezierPath()

        path.move(to: NSPoint(x: bounds.minX, y: topY))
        path.line(to: NSPoint(x: bounds.maxX, y: topY))
        path.line(to: NSPoint(x: bodyRight + neckInset, y: topY))
        path.curve(
            to: NSPoint(x: bodyRight, y: neckY),
            controlPoint1: NSPoint(x: bodyRight + neckInset * (1 - k), y: topY),
            controlPoint2: NSPoint(x: bodyRight, y: neckY + neckHeight * k)
        )
        path.line(to: NSPoint(x: bodyRight, y: bounds.minY + bottomRadius))
        path.curve(
            to: NSPoint(x: bodyRight - bottomRadius, y: bounds.minY),
            controlPoint1: NSPoint(x: bodyRight, y: bounds.minY + bottomRadius * (1 - k)),
            controlPoint2: NSPoint(x: bodyRight - bottomRadius * (1 - k), y: bounds.minY)
        )
        path.line(to: NSPoint(x: bodyLeft + bottomRadius, y: bounds.minY))
        path.curve(
            to: NSPoint(x: bodyLeft, y: bounds.minY + bottomRadius),
            controlPoint1: NSPoint(x: bodyLeft + bottomRadius * (1 - k), y: bounds.minY),
            controlPoint2: NSPoint(x: bodyLeft, y: bounds.minY + bottomRadius * (1 - k))
        )
        path.line(to: NSPoint(x: bodyLeft, y: neckY))
        path.curve(
            to: NSPoint(x: bodyLeft - neckInset, y: topY),
            controlPoint1: NSPoint(x: bodyLeft, y: neckY + neckHeight * k),
            controlPoint2: NSPoint(x: bodyLeft - neckInset * (1 - k), y: topY)
        )
        path.line(to: NSPoint(x: bounds.minX, y: topY))
        path.close()
        return path
    }

    private func drawDots(after pacmanX: CGFloat, from startX: CGFloat, through endX: CGFloat, y: CGFloat) {
        Palette.tertiaryInk.setFill()
        var x = startX
        while x <= endX {
            if x > pacmanX + 7 {
                NSRect(x: x - 1, y: y - 1, width: 2, height: 2).fill()
            }
            x += 9
        }
    }

    private func drawPacman(at center: NSPoint, pixel: CGFloat, color: NSColor, open: Bool) {
        let rows: [UInt8] = open
            ? [0b0011100, 0b0111110, 0b1111100, 0b1110000, 0b1111100, 0b0111110, 0b0011100]
            : [0b0011100, 0b0111110, 0b1111110, 0b1111100, 0b1111110, 0b0111110, 0b0011100]
        let origin = NSPoint(x: center.x - pixel * 3.5, y: center.y - pixel * 3.5)
        color.setFill()
        for (y, row) in rows.enumerated() {
            for x in 0..<7 where row & (1 << (6 - x)) != 0 {
                NSRect(
                    x: origin.x + CGFloat(x) * pixel,
                    y: origin.y + CGFloat(6 - y) * pixel,
                    width: pixel,
                    height: pixel
                ).fill()
            }
        }
    }

    private func drawPiSymbol(at center: NSPoint, pixel: CGFloat, color: NSColor, bob: Bool) {
        let rows: [UInt8] = [
            0b1111111,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0100010,
        ]
        drawPixelSprite(rows, at: center, pixel: pixel, color: color, bob: bob)
    }

    // opencode's pixelated logo: a square frame with a filled block riding low in the cavity.
    private func drawOpencodeLogo(at center: NSPoint, pixel: CGFloat, color: NSColor, bob: Bool) {
        let frame: [UInt8] = [
            0b0111110,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0100010,
            0b0111110,
        ]
        let block: [UInt8] = [
            0b0000000,
            0b0000000,
            0b0000000,
            0b0011100,
            0b0011100,
            0b0011100,
            0b0000000,
        ]
        drawPixelSprite(frame, at: center, pixel: pixel, color: color, bob: bob)
        drawPixelSprite(block, at: center, pixel: pixel, color: color.withAlphaComponent(0.55), bob: bob)
    }

    private func drawPixelSprite(_ rows: [UInt8], at center: NSPoint, pixel: CGFloat, color: NSColor, bob: Bool) {
        let origin = NSPoint(
            x: center.x - pixel * 3.5,
            y: center.y - pixel * 3.5 + (bob ? pixel : 0)
        )
        color.setFill()
        for (y, row) in rows.enumerated() {
            for x in 0..<7 where row & (1 << (6 - x)) != 0 {
                NSRect(
                    x: origin.x + CGFloat(x) * pixel,
                    y: origin.y + CGFloat(6 - y) * pixel,
                    width: pixel,
                    height: pixel
                ).fill()
            }
        }
    }

    private func drawAgentSprite(agent: AgentKind, at center: NSPoint, pixel: CGFloat, color: NSColor, running: Bool) {
        switch agent {
        case .codex:
            drawPacman(at: center, pixel: pixel, color: color, open: !running || mouthOpen)
        case .pi:
            drawPiSymbol(at: center, pixel: pixel, color: color, bob: running && mouthOpen)
        case .opencode:
            drawOpencodeLogo(at: center, pixel: pixel, color: color, bob: running && mouthOpen)
        }
    }

    private func statusColor(for phase: ThreadPhase) -> NSColor {
        switch phase {
        case .running: return Palette.pacYellow
        case .ready: return Palette.readyGreen
        case .stopped: return Palette.stoppedOrange
        case .seen: return Palette.tertiaryInk
        }
    }

    private func statusText(for phase: ThreadPhase) -> String {
        switch phase {
        case .running: return "RUNNING"
        case .ready: return ""
        case .stopped: return "STOPPED"
        case .seen: return ""
        }
    }

    private func drawSourceMarker(agent: AgentKind, source: String, in rect: NSRect) {
        let color: NSColor
        switch agent {
        case .pi:
            color = Palette.piCyan
        case .opencode:
            color = Palette.ocSilver
        case .codex:
            color = ([
                "extension": Palette.vscodeBlue,
                "cli": Palette.readyGreen,
                "codex": Palette.ghostPurple,
            ][source] ?? Palette.phosphor)
        }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private func updateAnimationTimer() {
        let shouldAnimate = activities.contains { $0.phase == .running }
        if shouldAnimate, animationTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                mouthOpen.toggle()
                pacmanProgress += 0.04
                if pacmanProgress >= 1 { pacmanProgress = 0 }
                needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !shouldAnimate {
            animationTimer?.invalidate()
            animationTimer = nil
            mouthOpen = true
            pacmanProgress = 0
        }
    }

    private func updateAccessibilityValue() {
        let running = activities.filter { $0.phase == .running }.count
        let ready = activities.filter { $0.phase == .ready }.count
        let stopped = activities.filter { $0.phase == .stopped }.count
        let seen = activities.filter { $0.phase == .seen }.count
        setAccessibilityValue(
            "\(running) running, \(ready) ready, \(stopped) stopped, \(seen) seen, \(remainingUsageSummary(accountUsage))"
        )
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandController {
    private let panel: IslandPanel
    private let island: IslandView
    private var outsideClickMonitor: Any?

    init() {
        island = IslandView(frame: .zero)
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = island
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        island.onExpansionChange = { [weak self] _ in self?.resize(animated: true) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.resize(animated: false) }

        resize(animated: false)
        panel.orderFrontRegardless()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.island.expanded, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            DispatchQueue.main.async { self.island.setExpanded(false) }
        }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    func update(_ activities: [ThreadActivity], accountUsage: UsageSnapshot?) {
        island.update(activities: activities, accountUsage: accountUsage)
        resize(animated: true)
    }

    private func resize(animated: Bool) {
        guard let screen = targetScreen() else { return }
        let collapsedHeight = max(30, screen.safeAreaInsets.top)
        let physicalNotchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            physicalNotchWidth = max(0, right.minX - left.maxX)
        } else {
            physicalNotchWidth = 0
        }

        let collapsedWidth = physicalNotchWidth > 0 ? (physicalNotchWidth + 180) * 0.75 : 189
        island.setTopBandHeight(collapsedHeight)
        island.setPhysicalNotchWidth(physicalNotchWidth)
        let width = island.expanded ? max(540, collapsedWidth) : collapsedWidth
        let height = island.expanded
            ? collapsedHeight + island.expandedContentHeight
            : collapsedHeight
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private struct AcknowledgementPlan {
    var codexSources: Set<String> = []
    var piSources: Set<String> = []
    var opencodeSources: Set<String> = []

    var isEmpty: Bool { codexSources.isEmpty && piSources.isEmpty && opencodeSources.isEmpty }
}

private func acknowledgementPlan(for application: NSRunningApplication) -> AcknowledgementPlan {
    let identifier = application.bundleIdentifier?.lowercased() ?? ""
    let name = application.localizedName?.lowercased() ?? ""
    if identifier.contains("codex") || name == "codex" { return AcknowledgementPlan(codexSources: ["codex"]) }
    if identifier.contains("vscode") || identifier.contains("cursor") || name.contains("visual studio code") {
        return AcknowledgementPlan(codexSources: ["extension", "cli"], piSources: ["cli"], opencodeSources: ["cli"])
    }
    let terminals = ["terminal", "ghostty", "iterm", "kitty", "warp", "alacritty", "wezterm"]
    return terminals.contains(where: { identifier.contains($0) || name.contains($0) })
        ? AcknowledgementPlan(codexSources: ["cli"], piSources: ["cli"], opencodeSources: ["cli"])
        : AcknowledgementPlan()
}

private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let monitor = SessionMonitor()
    private var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Notification authorization failed: %@", error.localizedDescription) }
        }

        let island = IslandController()
        self.island = island
        monitor.onChange = { [weak island] activities, usage in island?.update(activities, accountUsage: usage) }
        monitor.onCompletion = { activity in
            let content = UNMutableNotificationContent()
            content.title = "\(activity.agent.displayName) task complete"
            let marker: String
            switch activity.agent {
            case .pi:
                marker = "🟦"
            case .opencode:
                marker = "⬜"
            case .codex:
                marker = ["extension": "🟦", "cli": "🟩", "codex": "🟪"][activity.source] ?? "⬜"
            }
            content.subtitle = "\(marker) \(activity.project.prefix(18))"
            content.body = activity.title
            NSSound(named: "Blow")?.play()
            notifications.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                withCompletionHandler: { error in
                    if let error { NSLog("Notification delivery failed: %@", error.localizedDescription) }
                }
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let plan = acknowledgementPlan(for: application)
            if !plan.isEmpty {
                self.monitor.acknowledge(
                    codexSources: plan.codexSources,
                    piSources: plan.piSources,
                    opencodeSources: plan.opencodeSources
                )
            }
        }
        monitor.start()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}

private func runSelfTest() {
    let started = Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)
    let completed = Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)
    let cancelled = Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#.utf8)
    let response = Data(#"{"type":"event_msg","payload":{"type":"agent_message","message":"Done.\nReady now."}}"#.utf8)
    let prompt = Data(#"{"type":"event_msg","payload":{"type":"user_message","message":"whats this codebase about?"}}"#.utf8)
    let context = Data(#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"high"}}"#.utf8)
    let usage = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120000},"last_token_usage":{"total_tokens":50000},"model_context_window":250000},"rate_limits":{"primary":{"used_percent":12.345,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":34.5,"window_minutes":10080,"resets_at":1800600000}}}}"#.utf8)
    let unrelated = Data(#"{"type":"event_msg","payload":{"type":"token_count"}}"#.utf8)
    assert(parseTurnEvent(started) == .started)
    assert(parseTurnEvent(completed) == .completed)
    assert(parseTurnEvent(cancelled) == .cancelled)
    assert(parseTurnEvent(unrelated) == nil)
    assert(parseResponse(response) == "Done. Ready now.")
    assert(parsePrompt(prompt) == "whats this codebase about?")
    assert(parseModel(context) == "gpt-5.6-sol/high")
    assert(parseUsage(usage)?.contextTokens == 50_000)
    assert(usageSummary(parseUsage(usage)) == "ctx 20% · 120k tok")
    assert(nextReset(in: parseUsage(usage))?.windowMinutes == 300)
    assert(remainingUsageSummary(parseUsage(usage)).contains("5h 87.66% left"))
    assert(remainingUsageSummary(parseUsage(usage)).contains("reset"))
    assert(relativeAge(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 3600)) == "1h")
    assert(parseResponse(unrelated) == nil)
    assert(shouldRetain(.running, updatedAt: .distantPast))
    assert(shouldRetain(.ready, updatedAt: Date().addingTimeInterval(-activityRetention + 1)))
    assert(!shouldRetain(.stopped, updatedAt: Date().addingTimeInterval(-activityRetention - 1)))
    assert(shouldMarkStopped(.running, updatedAt: Date().addingTimeInterval(-runningInactivityTimeout - 1), timeout: runningInactivityTimeout))
    assert(!shouldMarkStopped(.ready, updatedAt: .distantPast, timeout: runningInactivityTimeout))
    assert(shouldMarkStopped(.running, updatedAt: Date().addingTimeInterval(-piRunningInactivityTimeout - 1), timeout: piRunningInactivityTimeout))
    let piUserEntry = Data(#"{"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-15T18:56:11.218Z","message":{"role":"user","content":[{"type":"text","text":"hello from pi"}],"timestamp":1786820171215}}"#.utf8)
    let piToolUseEntry = Data(#"{"type":"message","id":"b1","parentId":"a1","timestamp":"2026-08-15T18:56:14.404Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_1","name":"bash","arguments":{}}],"api":"openai-completions","provider":"zai","model":"glm-5.3","usage":{"input":1500,"output":200,"cacheRead":500,"cacheWrite":0,"totalTokens":2200,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0.1}},"stopReason":"toolUse","timestamp":1786820171267}}"#.utf8)
    let piDoneEntry = Data(#"{"type":"message","id":"c1","parentId":"b1","timestamp":"2026-08-15T18:57:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"All done.\nShip it."}],"api":"openai-completions","provider":"zai","model":"glm-5.3","usage":{"input":2000,"output":300,"cacheRead":500,"cacheWrite":0,"totalTokens":2800,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0.4}},"stopReason":"stop","timestamp":1786820220000}}"#.utf8)
    let piAbortedEntry = Data(#"{"type":"message","id":"d1","parentId":"c1","timestamp":"2026-08-15T18:58:00.000Z","message":{"role":"assistant","content":[],"provider":"zai","model":"glm-5.3","usage":{"input":100,"output":10,"totalTokens":110,"cost":{"total":0}},"stopReason":"aborted","timestamp":1786820280000}}"#.utf8)
    let piModelChange = Data(#"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-15T18:55:41.106Z","provider":"zai","modelId":"glm-5.3"}"#.utf8)
    let piThinkingChange = Data(#"{"type":"thinking_level_change","id":"t1","parentId":"m1","timestamp":"2026-08-15T18:55:41.106Z","thinkingLevel":"high"}"#.utf8)
    let piSessionInfo = Data(#"{"type":"session_info","id":"s1","parentId":"t1","timestamp":"2026-08-15T18:55:41.106Z","name":"Refactor auth"}"#.utf8)
    let piIrrelevant = Data(#"{"type":"custom","id":"x1","parentId":null,"timestamp":"2026-08-15T18:55:41.106Z","customType":"ext","data":{}}"#.utf8)
    if case .userPrompt(let prompt)? = parsePiEvent(piUserEntry) { assert(prompt == "hello from pi") } else { assertionFailure() }
    if case .assistant(let text, let model, _, let stopReason, let usage)? = parsePiEvent(piDoneEntry) {
        assert(text == "All done. Ship it.")
        assert(model == "glm-5.3")
        assert(stopReason == "stop")
        assert(usage?.totalTokens == 2_800 && usage?.contextTokens == 2_500 && usage?.cost == 0.4)
    } else { assertionFailure() }
    assert(piTurnEvent(parsePiEvent(piUserEntry)!) == .started)
    assert(piTurnEvent(parsePiEvent(piDoneEntry)!) == .completed)
    assert(piTurnEvent(parsePiEvent(piAbortedEntry)!) == .cancelled)
    assert(piTurnEvent(parsePiEvent(piToolUseEntry)!) == nil)
    assert(piTurnEvent(parsePiEvent(piModelChange)!) == nil)
    assert(parsePiEvent(piIrrelevant) == nil)
    let ocUserHeader = parseOpencodeMessageHeader(Data(#"{"role":"user","time":{"created":1786825803000}}"#.utf8))
    let ocStreamingHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","modelID":"glm-5.3","providerID":"zai-coding-plan","variant":"high","agent":"build","time":{"created":1786825803000}}"#.utf8))
    let ocDoneHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":1786825803000,"completed":1786825806000},"finish":"stop","tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":300,"write":10}},"cost":0.01}"#.utf8))
    let ocAbortHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","time":{"created":1786825803000,"completed":1786825806000},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}"#.utf8))
    assert(ocUserHeader?.role == "user")
    assert(ocStreamingHeader?.completed == false)
    assert(ocDoneHeader?.contextTokens == 460)
    assert(ocAbortHeader?.aborted == true)
    assert(opencodeTurnEvent(ocUserHeader) == .started)
    assert(opencodeTurnEvent(ocStreamingHeader) == .started)
    assert(opencodeTurnEvent(ocDoneHeader) == .completed)
    assert(opencodeTurnEvent(ocAbortHeader) == .cancelled)
    assert(opencodeTurnEvent(nil) == nil)
    assert(opencodeModelLabel(modelID: "glm-5.3", variant: "high") == "glm-5.3/high")
    assert(opencodeModelLabel(modelID: "glm-5.3", variant: nil) == "glm-5.3")
    assert(opencodeSessionModel(#"{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}"#) == "glm-5.3/high")
    assert(shouldMarkStopped(.running, updatedAt: Date().addingTimeInterval(-opencodeRunningInactivityTimeout - 1), timeout: opencodeRunningInactivityTimeout))
    let track = visiblePacmanTrack(
        in: NSRect(x: 0, y: 0, width: 360, height: 37),
        bodyInset: 24,
        physicalNotchWidth: 180
    )
    assert(track.lowerBound == 263 && track.upperBound == 329)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-\(UUID().uuidString)")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let sessions = root.appendingPathComponent("sessions/\(formatter.string(from: Date()))")
    let session = sessions.appendingPathComponent("rollout.jsonl")
    let childSession = sessions.appendingPathComponent("child.jsonl")
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let meta = #"{"type":"session_meta","payload":{"id":"self-test","source":"vscode","originator":"codex_vscode","cwd":"/tmp/workspace"}}"#
    let childMeta = #"{"type":"session_meta","payload":{"id":"child","parent_thread_id":"self-test","source":{"subagent":{"thread_spawn":{"agent_nickname":"guardian","parent_thread_id":"self-test"}}},"thread_source":"cli","originator":"codex_cli_rs","cwd":"/tmp/workspace"}}"#
    try! Data("\(meta)\n\(String(decoding: started, as: UTF8.self))\n\(String(decoding: prompt, as: UTF8.self))\n\(String(decoding: context, as: UTF8.self))\n\(String(decoding: usage, as: UTF8.self))\n".utf8).write(to: session)
    try! Data("\(childMeta)\n\(String(decoding: started, as: UTF8.self))\n\(String(decoding: prompt, as: UTF8.self))\n".utf8).write(to: childSession)
    setenv("CODEX_HOME", root.path, 1)
    // isolate opencode from the machine's real ~/.local/share/opencode during monitor tests
    let emptyDataHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-status-xdg-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: emptyDataHome, withIntermediateDirectories: true)
    setenv("XDG_DATA_HOME", emptyDataHome.path, 1)

    let monitor = SessionMonitor()
    var latest: [ThreadActivity] = []
    var completions: [ThreadActivity] = []
    monitor.onChange = { activities, _ in latest = activities }
    monitor.onCompletion = { completions.append($0) }
    monitor.start()
    assert(waitUntil {
        latest.contains { $0.id == "self-test" && $0.phase == .running }
            && latest.contains { $0.id == "child" && $0.phase == .running }
    })
    let parent = latest.first { $0.id == "self-test" }
    let child = latest.first { $0.id == "child" }
    assert(parent?.title == "whats this codebase about?")
    assert(parent?.model == "gpt-5.6-sol/high")
    assert(parent?.usage?.totalTokens == 120_000)
    assert(child?.parentID == "self-test" && child?.nickname == "guardian")
    assert(groupActivities(latest).first(where: { $0.root.id == "self-test" })?.children.map(\.id) == ["child"])
    assert(completions.isEmpty)

    let handle = try! FileHandle(forWritingTo: session)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: completed + Data("\n".utf8))
    try! handle.close()
    assert(waitUntil(timeout: 3) { latest.first(where: { $0.id == "self-test" })?.phase == .ready && completions.count == 1 })
    assert(completions.first?.id == "self-test")
    assert(groupActivities(latest).first { $0.root.id == "self-test" }?.phase == .running)
    let childHandle = try! FileHandle(forWritingTo: childSession)
    try! childHandle.seekToEnd()
    try! childHandle.write(contentsOf: completed + Data("\n".utf8))
    try! childHandle.close()
    assert(waitUntil(timeout: 3) { latest.first(where: { $0.id == "child" })?.phase == .ready })
    assert(completions.count == 1)
    monitor.acknowledge(codexSources: ["extension"], piSources: [], opencodeSources: [])
    assert(waitUntil { latest.first(where: { $0.id == "self-test" })?.phase == .seen })

    let shellSnapshots = root.appendingPathComponent("shell_snapshots")
    try! FileManager.default.createDirectory(at: shellSnapshots, withIntermediateDirectories: true)
    try! Data("export TERM_PROGRAM=WarpTerminal\n".utf8).write(
        to: shellSnapshots.appendingPathComponent("self-test.2.sh")
    )
    let resumedHandle = try! FileHandle(forWritingTo: session)
    try! resumedHandle.seekToEnd()
    try! resumedHandle.write(contentsOf: started + Data("\n".utf8))
    try! resumedHandle.close()
    assert(waitUntil {
        latest.first(where: { $0.id == "self-test" }).map { $0.phase == .running && $0.source == "cli" } ?? false
    })
    monitor.stop()
    try? FileManager.default.removeItem(at: root)

    // Pi monitor: session lifecycle, model/thinking labels, cumulative usage, names, aborts.
    let piRoot = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-pi-\(UUID().uuidString)")
    let piProject = piRoot.appendingPathComponent("sessions/--tmp-workspace--", isDirectory: true)
    try! FileManager.default.createDirectory(at: piProject, withIntermediateDirectories: true)
    let isoFormatter = ISO8601DateFormatter()
    let fileName = "\(isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))_pi-test.jsonl"
    let piSession = piProject.appendingPathComponent(fileName)
    let piHeader = #"{"type":"session","version":3,"id":"pi-test","timestamp":"2026-08-15T18:55:41.082Z","cwd":"/tmp/workspace"}"#
    try! Data("\(piHeader)\n\(String(decoding: piModelChange, as: UTF8.self))\n\(String(decoding: piThinkingChange, as: UTF8.self))\n\(String(decoding: piSessionInfo, as: UTF8.self))\n\(String(decoding: piUserEntry, as: UTF8.self))\n".utf8).write(to: piSession)
    try! Data(#"{"zai":{"models":[{"id":"glm-5.3","contextWindow":5000}]}}"#.utf8)
        .write(to: piRoot.appendingPathComponent("models-store.json"))
    setenv("PI_CODING_AGENT_DIR", piRoot.path, 1)

    let piMonitor = SessionMonitor()
    piMonitor.onChange = { activities, _ in latest = activities }
    piMonitor.onCompletion = { completions.append($0) }
    piMonitor.start()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "pi-test" }.map { $0.agent == .pi && $0.phase == .running } ?? false
    })
    let piActivity = latest.first { $0.id == "pi-test" }
    assert(piActivity?.title == "hello from pi")
    assert(piActivity?.model == "glm-5.3/high")
    assert(piActivity?.project == "workspace")
    assert(piActivity?.source == "cli")

    let piHandle = try! FileHandle(forWritingTo: piSession)
    try! piHandle.seekToEnd()
    try! piHandle.write(contentsOf: piToolUseEntry + Data("\n".utf8))
    try! piHandle.close()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "pi-test" }.map { $0.phase == .running && $0.usage?.totalTokens == 2_200 } ?? false
    })
    assert(latest.first { $0.id == "pi-test" }?.usage?.contextTokens == 2_000)
    assert(latest.first { $0.id == "pi-test" }?.usage?.contextWindow == 5_000)

    let reopen = try! FileHandle(forWritingTo: piSession)
    try! reopen.seekToEnd()
    try! reopen.write(contentsOf: piDoneEntry + Data("\n".utf8))
    try! reopen.close()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "pi-test" }.map { $0.phase == .ready } ?? false
            && completions.contains { $0.id == "pi-test" && $0.agent == .pi }
    })
    let finished = latest.first { $0.id == "pi-test" }
    assert(finished?.detail == "All done. Ship it.")
    assert(finished?.usage?.totalTokens == 5_000)
    assert(finished?.usage?.costTotal == 0.5)
    assert(usageSummary(finished?.usage) == "ctx 50% · 5k tok")
    assert(piUsageSummary(latest).contains("pi 5k tok"))
    assert(piUsageSummary(latest).contains("$0.50"))
    piMonitor.acknowledge(codexSources: ["cli"], piSources: ["cli"], opencodeSources: [])
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.phase == .seen })

    let secondTurn = try! FileHandle(forWritingTo: piSession)
    try! secondTurn.seekToEnd()
    try! secondTurn.write(contentsOf: piUserEntry + Data("\n".utf8))
    try! secondTurn.write(contentsOf: piAbortedEntry + Data("\n".utf8))
    try! secondTurn.close()
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.phase == .stopped })
    piMonitor.stop()
    try? FileManager.default.removeItem(at: piRoot)

    // opencode monitor: sqlite lifecycle, titles, model/usage labels, aborts, subagent grouping.
    let ocRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-status-oc-\(UUID().uuidString)", isDirectory: true)
    let ocData = ocRoot.appendingPathComponent("opencode", isDirectory: true)
    try! FileManager.default.createDirectory(at: ocData, withIntermediateDirectories: true)
    let ocDB = ocData.appendingPathComponent("opencode.db")

    func opencodeExecute(_ sql: String) {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(ocDB.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            assertionFailure()
            return
        }
    }

    opencodeExecute("CREATE TABLE session (id text PRIMARY KEY, parent_id text, title text NOT NULL, directory text NOT NULL, agent text, model text, cost real DEFAULT 0 NOT NULL, tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL, tokens_reasoning integer DEFAULT 0 NOT NULL, tokens_cache_read integer DEFAULT 0 NOT NULL, tokens_cache_write integer DEFAULT 0 NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer); CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL); CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);")
    setenv("XDG_DATA_HOME", ocRoot.path, 1)

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    opencodeExecute("""
    INSERT INTO session (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-1', NULL, 'Ship the widget', '/tmp/workspace', 'build', '{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}', 0.0123, 1000, 200, 50, 3000, 0, \(nowMs - 8000), \(nowMs - 1000), NULL);
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m1', 'ses_oc-1', \(nowMs - 8000), \(nowMs - 8000), '{"role":"user","time":{"created":\(nowMs - 8000)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p1', 'm1', 'ses_oc-1', \(nowMs - 8000), \(nowMs - 8000), '{"type":"text","text":"add opencode support please"}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m2', 'ses_oc-1', \(nowMs - 1000), \(nowMs - 1000), '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs - 1000)}}');
    """)

    let ocMonitor = SessionMonitor()
    ocMonitor.onChange = { activities, _ in latest = activities }
    ocMonitor.onCompletion = { completions.append($0) }
    ocMonitor.start()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-1" }.map { $0.agent == .opencode && $0.phase == .running } ?? false
    })
    let ocActivity = latest.first { $0.id == "ses_oc-1" }
    assert(ocActivity?.title == "Ship the widget")
    assert(ocActivity?.model == "glm-5.3/high")
    assert(ocActivity?.project == "workspace")
    assert(ocActivity?.source == "cli")
    assert(ocActivity?.detail == "")

    opencodeExecute("""
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p2', 'm2', 'ses_oc-1', \(nowMs + 1000), \(nowMs + 1000), '{"type":"text","text":"Done. Shipped."}');
    UPDATE message SET data = '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs - 1000),"completed":\(nowMs + 2000)},"finish":"stop","tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":300,"write":10}},"cost":0.01}', time_updated = \(nowMs + 2000) WHERE id = 'm2';
    UPDATE session SET time_updated = \(nowMs + 2000) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-1" }.map { $0.phase == .ready && $0.detail == "Done. Shipped." } ?? false
            && completions.contains { $0.id == "ses_oc-1" && $0.agent == .opencode }
    })
    let ocFinished = latest.first { $0.id == "ses_oc-1" }
    assert(ocFinished?.usage?.totalTokens == 4_250)
    assert(ocFinished?.usage?.contextTokens == 460)
    assert(ocFinished?.usage?.costTotal == 0.0123)
    assert(usageSummary(ocFinished?.usage) == "4k tok")
    assert(opencodeUsageSummary(latest) == "oc 4k tok · $0.01")
    ocMonitor.acknowledge(codexSources: [], piSources: [], opencodeSources: ["cli"])
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_oc-1" }?.phase == .seen })

    opencodeExecute("""
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m3', 'ses_oc-1', \(nowMs + 3000), \(nowMs + 3000), '{"role":"user","time":{"created":\(nowMs + 3000)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p3', 'm3', 'ses_oc-1', \(nowMs + 3000), \(nowMs + 3000), '{"type":"text","text":"go again"}');
    INSERT INTO session (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-2', 'ses_oc-1', 'Explore (@explore)', '/tmp/workspace', 'explore', NULL, 0, 100, 20, 0, 0, 0, \(nowMs + 3100), \(nowMs + 3500), NULL);
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m4', 'ses_oc-2', \(nowMs + 3200), \(nowMs + 3200), '{"role":"user","time":{"created":\(nowMs + 3200)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p4', 'm4', 'ses_oc-2', \(nowMs + 3200), \(nowMs + 3200), '{"type":"text","text":"explore the repo"}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m5', 'ses_oc-2', \(nowMs + 3500), \(nowMs + 3500), '{"role":"assistant","agent":"explore","time":{"created":\(nowMs + 3500)}}');
    UPDATE session SET time_updated = \(nowMs + 4000) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-2" }.map { $0.agent == .opencode && $0.phase == .running && $0.parentID == "ses_oc-1" } ?? false
            && latest.first { $0.id == "ses_oc-1" }?.phase == .running
    })
    assert(latest.first { $0.id == "ses_oc-2" }?.nickname == "explore")
    assert(latest.first { $0.id == "ses_oc-1" }?.title == "Ship the widget")
    assert(latest.first { $0.id == "ses_oc-1" }?.detail == "")
    assert(
        groupActivities(latest).first { $0.root.id == "ses_oc-1" }?.children.map(\.id) == ["ses_oc-2"]
    )

    opencodeExecute("""
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m6', 'ses_oc-1', \(nowMs + 5000), \(nowMs + 5000), '{"role":"assistant","time":{"created":\(nowMs + 5000),"completed":\(nowMs + 6000)},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}');
    UPDATE session SET time_updated = \(nowMs + 6000) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_oc-1" }?.phase == .stopped })
    ocMonitor.stop()
    try? FileManager.default.removeItem(at: ocRoot)
    try? FileManager.default.removeItem(at: emptyDataHome)
    print("Session monitor: OK")
}

private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTest()
    exit(EXIT_SUCCESS)
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
