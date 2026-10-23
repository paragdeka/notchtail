import AppKit
import CoreServices
import Darwin
import Foundation
import ServiceManagement
import SQLite3
import UserNotifications

private enum ThreadPhase: Equatable {
    case running
    case delegating
    case ready
    case stopped
    case seen
}

// A blocking question or permission request the agent is waiting on. Read-only:
// the notch surfaces it, the user answers in the agent's own surface.
private struct AgentPrompt: Equatable {
    enum Kind: Equatable {
        case question
        case permission
    }

    let kind: Kind
    let tool: String
    let text: String
    let callID: String

    var line: String {
        switch kind {
        case .question:
            return text.isEmpty ? "asked a question" : text
        case .permission:
            return text.isEmpty ? "allow \(tool)?" : "\(tool): \(text)"
        }
    }

    var verb: String {
        kind == .question ? "Asked a question" : "Waiting for permission"
    }
}

private enum AgentKind: Equatable {
    case codex
    case pi
    case opencode
    case opencode2
    case claude

    var label: String {
        switch self {
        case .codex: return "codex"
        case .pi: return "pi"
        case .opencode: return "opencode"
        case .opencode2: return "opencode2"
        case .claude: return "claude"
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .opencode: return "opencode"
        case .opencode2: return "opencode2"
        case .claude: return "Claude"
        }
    }
}

private let activityRetention: TimeInterval = 15 * 60
private let runningInactivityTimeout: TimeInterval = 6 * 60 * 60
private let piRunningInactivityTimeout: TimeInterval = 30 * 60
private let opencodeRunningInactivityTimeout: TimeInterval = 30 * 60
private let claudeRunningInactivityTimeout: TimeInterval = 30 * 60

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
    case .delegating: return 1
    case .stopped: return 2
    case .ready: return 3
    case .seen: return 4
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
    var prompt: AgentPrompt? = nil

    var key: String { "\(agent.label):\(id)" }
    var runningTimeout: TimeInterval {
        switch agent {
        case .codex: return runningInactivityTimeout
        case .pi: return piRunningInactivityTimeout
        case .opencode: return opencodeRunningInactivityTimeout
        case .opencode2: return opencodeRunningInactivityTimeout
        case .claude: return claudeRunningInactivityTimeout
        }
    }
}

private func activityUIIdentity(_ activity: ThreadActivity) -> String {
    activity.key
}

private func agentRowLabel(_ agent: AgentKind) -> String? {
    switch agent {
    case .opencode: return "oc"
    case .opencode2: return "oc2"
    case .claude: return "claude"
    case .codex, .pi: return nil
    }
}

// a subagent usually inherits its parent's model; show only what differs, often just the reasoning level.
private func modelDelta(_ model: String, parent: String?) -> String? {
    guard !model.isEmpty, model != parent else { return nil }
    let parts = model.split(separator: "/", maxSplits: 1)
    if parts.count == 2, parent?.split(separator: "/", maxSplits: 1).first == parts[0] { return "/\(parts[1])" }
    return model
}

// names the surface a session runs in, so the colored source marker beside it explains itself.
private func surfaceLabel(_ agent: AgentKind, source: String) -> String? {
    switch agent {
    case .codex: return ["codex": "desktop", "extension": "extension", "cli": "cli"][source]
    case .claude: return source
    case .pi, .opencode, .opencode2: return nil
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
    var unavailableReason: String? = nil

    var refreshWarning: String? {
        guard let unavailableReason else { return nil }
        let prefix = primaryLimit != nil || secondaryLimit != nil ? "Showing last known limits. " : ""
        return prefix + unavailableReason
    }
}

private struct RemoteRateLimits: Equatable {
    let primary: RateLimitUsage?
    let secondary: RateLimitUsage?
}

private func mergedRateLimits(_ current: RemoteRateLimits?, with refreshed: RemoteRateLimits?) -> RemoteRateLimits? {
    let primary = refreshed?.primary ?? current?.primary
    let secondary = refreshed?.secondary ?? current?.secondary
    guard primary != nil || secondary != nil else { return nil }
    return RemoteRateLimits(primary: primary, secondary: secondary)
}

private func effectiveUsage(local: UsageSnapshot?, remote: RemoteRateLimits?, unavailableReason: String? = nil) -> UsageSnapshot? {
    guard local != nil || remote != nil || unavailableReason != nil else { return nil }
    guard let local else {
        return UsageSnapshot(
            totalTokens: 0,
            contextTokens: 0,
            contextWindow: 0,
            primaryLimit: remote?.primary,
            secondaryLimit: remote?.secondary,
            costTotal: nil,
            unavailableReason: unavailableReason
        )
    }
    return UsageSnapshot(
        totalTokens: local.totalTokens,
        contextTokens: local.contextTokens,
        contextWindow: local.contextWindow,
        primaryLimit: remote?.primary ?? local.primaryLimit,
        secondaryLimit: remote?.secondary ?? local.secondaryLimit,
        costTotal: local.costTotal,
        unavailableReason: unavailableReason ?? local.unavailableReason
    )
}

private struct OpencodeStore {
    let databaseURL: URL
}

private func parseCodexUsageResponse(_ data: Data) -> (primary: RateLimitUsage?, secondary: RateLimitUsage?)? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rateLimit = object["rate_limit"] as? [String: Any] else { return nil }
    func parse(_ value: Any?) -> RateLimitUsage? {
        guard let window = value as? [String: Any],
              let used = (window["used_percent"] as? NSNumber)?.doubleValue,
              let seconds = (window["limit_window_seconds"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (window["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitUsage(usedPercent: used, windowMinutes: Int((seconds / 60).rounded()), resetsAt: reset)
    }
    return (parse(rateLimit["primary_window"]), parse(rateLimit["secondary_window"]))
}

private func parseClaudeUsageResponse(_ data: Data) -> RemoteRateLimits? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["five_hour"] != nil || object["seven_day"] != nil else { return nil }
    func window(_ key: String, minutes: Int) -> RateLimitUsage? {
        guard let value = object[key] as? [String: Any],
              let number = value["utilization"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        let reset = (value["resets_at"] as? String).flatMap {
            claudeTimestamp.date(from: $0) ?? claudeTimestampWithoutFraction.date(from: $0)
        }
        return RateLimitUsage(usedPercent: number.doubleValue, windowMinutes: minutes, resetsAt: reset)
    }
    return RemoteRateLimits(primary: window("five_hour", minutes: 300), secondary: window("seven_day", minutes: 10_080))
}

private func claudeUsageFailure(statusCode: Int?, limits: RemoteRateLimits?) -> String? {
    switch statusCode {
    case 200 where limits?.primary != nil || limits?.secondary != nil:
        return nil
    case 200:
        return "Claude returned no usable limits. Retrying automatically."
    case 401, 403:
        return "Claude login expired or lacks usage access. Open Claude Code and sign in again."
    case 429:
        return "Claude usage is temporarily rate limited. Retrying automatically."
    case let status?:
        return "Claude usage request failed (HTTP \(status)). Retrying automatically."
    case nil:
        return "Cannot reach Claude usage. Check your connection; retrying automatically."
    }
}

private func parseClaudeAccessToken(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = object["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return token
}

// claude code writes this item through /usr/bin/security, which recreates its ACL on every
// token refresh; reading through the same tool stays trusted, while a direct
// SecItemCopyMatching loses its "Always Allow" approval each time.
private func readClaudeKeychainCredentials() -> (data: Data?, exitStatus: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return (nil, -1) }
    if finished.wait(timeout: .now() + 10) == .timedOut {
        process.terminate()
        return (nil, -1)
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus == 0 ? data : nil, process.terminationStatus)
}

private func loadClaudeAccessToken(home: URL) -> (token: String?, unavailableReason: String?) {
    let missingLogin = "Claude login unavailable. Open Claude Code and sign in."
    if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return (token, nil) }
    let file = home.appendingPathComponent(".credentials.json")
    if FileManager.default.fileExists(atPath: file.path) {
        let token = (try? Data(contentsOf: file)).flatMap(parseClaudeAccessToken)
        return (token, token == nil ? missingLogin : nil)
    }
    let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    guard home.resolvingSymlinksInPath().path == defaultHome.resolvingSymlinksInPath().path else { return (nil, missingLogin) }
    let result = readClaudeKeychainCredentials()
    // security exits 44 when the item does not exist.
    if result.exitStatus == 44 { return (nil, missingLogin) }
    guard let data = result.data else {
        return (nil, "Keychain read failed (\(result.exitStatus)). Retrying automatically.")
    }
    let token = parseClaudeAccessToken(data)
    return (token, token == nil ? missingLogin : nil)
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

private func isOpencodeDefaultTitle(_ title: String) -> Bool {
    // Mirrors opencode's `isDefaultTitle`: auto titles like
    // "New session - 2026-09-15T07:44:54.967Z" carry no meaning, so the row
    // falls back to the user message instead.
    title.range(
        of: "^(New session - |Child session - )\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$",
        options: .regularExpression
    ) != nil
}

private let taskNeedle = Data("\"payload\":{\"type\":\"task_".utf8)
private let abortedNeedle = Data("\"payload\":{\"type\":\"turn_aborted\"".utf8)
private let responseNeedle = Data("\"payload\":{\"type\":\"agent_message\"".utf8)
private let promptNeedle = Data("\"payload\":{\"type\":\"user_message\"".utf8)
private let messageRoleNeedle = Data("\"role\"".utf8)
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

private func parseMessage(_ line: Data, needle: Data, type: String, role: String) -> String? {
    guard line.range(of: needle) != nil || line.range(of: messageRoleNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let payload = object["payload"] as? [String: Any] else { return nil }

    if object["type"] as? String == "event_msg", payload["type"] as? String == type,
       let message = payload["message"] as? String {
        return condensedText(message)
    }
    guard object["type"] as? String == "response_item",
          payload["type"] as? String == "message", payload["role"] as? String == role,
          let content = payload["content"] as? [[String: Any]] else { return nil }
    let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
    let kinds = metadata?["content_item_kinds"] as? [String]
    let texts = content.enumerated().compactMap { index, block -> String? in
        guard block["type"] as? String == (role == "user" ? "input_text" : "output_text"),
              let text = block["text"] as? String else { return nil }
        if role == "user" {
            if let kinds {
                guard kinds.indices.contains(index), kinds[index] == "user.text" else { return nil }
            } else if text.hasPrefix("# AGENTS.md instructions") || text.hasPrefix("<environment_context>") {
                return nil
            }
        }
        return text
    }
    return condensedText(texts.joined(separator: "\n"))
}

private func parseResponse(_ line: Data) -> String? {
    parseMessage(line, needle: responseNeedle, type: "agent_message", role: "assistant")
}

private func parsePrompt(_ line: Data) -> String? {
    parseMessage(line, needle: promptNeedle, type: "user_message", role: "user")
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

// Codex persists protocol response items even when the UI that owns the
// approval is not running. Keep these waits read-only and correlate results by
// call id so an old approval cannot remain visible after the tool finishes.
// every value the parser accepts appears verbatim in the line, so these cheap
// scans skip the full json parse for the vast majority of rollout lines.
private let codexPendingNeedles = ["request_user_input", "user_input_request", "require_escalated"].map { Data($0.utf8) }
private let codexResolvedNeedles = ["function_call_output", "function_call_result", "response_item_output"].map { Data($0.utf8) }

private func parseCodexPendingPrompt(_ line: Data) -> AgentPrompt? {
    guard codexPendingNeedles.contains(where: { line.range(of: $0) != nil }),
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
    let outerPayload = object["payload"] as? [String: Any]
    let item = ((outerPayload?["type"] as? String) == "response_item" ? outerPayload?["payload"] as? [String: Any] : outerPayload) ?? object
    let type = item["type"] as? String ?? ""
    let callID = item["call_id"] as? String ?? item["callId"] as? String ?? item["id"] as? String ?? ""
    guard !callID.isEmpty else { return nil }
    let arguments: [String: Any]
    if let value = item["arguments"] as? [String: Any] { arguments = value }
    else if let value = item["arguments"] as? String,
            let data = value.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { arguments = parsed }
    else { arguments = [:] }
    let requestInput = type == "request_user_input" || type == "user_input_request"
        || (type == "function_call" && (item["name"] as? String) == "request_user_input")
    if requestInput {
        let source = arguments.isEmpty ? item : arguments
        let text = (source["questions"] as? [[String: Any]])?.compactMap { $0["question"] as? String }.first
            ?? source["question"] as? String ?? source["prompt"] as? String ?? ""
        return AgentPrompt(kind: .question, tool: "request_user_input", text: String(text.prefix(160)), callID: callID)
    }
    guard type == "function_call", (item["name"] as? String) == "exec_command" else { return nil }
    guard (arguments["sandbox_permissions"] as? String) == "require_escalated" else { return nil }
    let text = arguments["command"] as? String ?? arguments["cmd"] as? String ?? ""
    return AgentPrompt(kind: .permission, tool: "exec_command", text: String(text.prefix(160)), callID: callID)
}

private func parseCodexResolvedCallID(_ line: Data) -> String? {
    guard codexResolvedNeedles.contains(where: { line.range(of: $0) != nil }),
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
    let item = (object["payload"] as? [String: Any]) ?? object
    let type = item["type"] as? String ?? ""
    guard type == "function_call_output" || type == "function_call_result" || type == "response_item_output" else { return nil }
    return item["call_id"] as? String ?? item["callId"] as? String
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

// Claude writes several content blocks with the same message ID and cumulative usage.
private struct ClaudeSessionState {
    var event: TurnEvent?
    var prompt: String?
    var response: String?
    var model: String?
    var name: String? { customName ?? generatedName }
    var source: String?
    var updatedAt: Date?
    var pending: [String: AgentPrompt] = [:]
    var subagentNames: [String: String] = [:]
    private var customName: String?
    private var generatedName: String?
    private var handbacks: [String: String] = [:]
    private var messageTokens: [String: Int] = [:]
    private var totalTokens = 0
    private var contextTokens = 0

    var usage: UsageSnapshot? {
        guard !messageTokens.isEmpty else { return nil }
        return UsageSnapshot(totalTokens: totalTokens, contextTokens: contextTokens, contextWindow: 0,
                             primaryLimit: nil, secondaryLimit: nil, costTotal: nil)
    }

    @discardableResult
    mutating func consume(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return false }
        if let entrypoint = object["entrypoint"] as? String {
            source = claudeSource(entrypoint)
        }
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"]
        let blocks = content as? [[String: Any]] ?? []
        let text = piTextContent(content)
        var turnActivity = true

        switch type {
        case "user":
            let results = blocks.filter { ($0["type"] as? String) == "tool_result" }
            var deliveredReport: String?
            for result in results {
                guard let id = result["tool_use_id"] as? String else { continue }
                pending.removeValue(forKey: id)
                if let report = handbacks.removeValue(forKey: id), result["is_error"] as? Bool != true {
                    let status = piTextContent(result["content"]).flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if status?["success"] as? Bool == true { deliveredReport = report }
                }
            }
            if let result = object["toolUseResult"] as? [String: Any],
               let agentID = result["agentId"] as? String, let sessionID = object["sessionId"] as? String,
               let name = condensedText(result["description"] as? String ?? "") {
                subagentNames["\(sessionID):agent:\(agentID)"] = name
            }
            let interrupted = (object["toolUseResult"] as? [String: Any])?["interrupted"] as? Bool == true
                || text?.hasPrefix("[Request interrupted by user") == true
            if interrupted {
                event = .cancelled
                pending.removeAll()
                handbacks.removeAll()
            } else if let deliveredReport, event != .cancelled {
                event = .completed
                response = condensedText(deliveredReport)
            } else if !results.isEmpty {
                if event != .cancelled { event = .started }
            } else {
                guard object["isMeta"] as? Bool != true,
                      object["isCompactSummary"] as? Bool != true,
                      text?.hasPrefix("<local-command-") != true,
                      text?.hasPrefix("<command-name>") != true else { return false }
                let taskNotification = text?.hasPrefix("<task-notification>") == true
                    || (object["origin"] as? [String: Any])?["kind"] as? String == "task-notification"
                    || object["turnOrigin"] as? String == "task_notification"
                if !taskNotification, let text { prompt = text }
                response = nil
                pending.removeAll()
                handbacks.removeAll()
                event = .started
            }
        case "assistant":
            if let value = message["model"] as? String, value != "<synthetic>" { model = value }
            if let text { response = text }
            if let usage = message["usage"] as? [String: Any],
               let id = message["id"] as? String ?? object["uuid"] as? String {
                func tokens(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
                let input = tokens("input_tokens") + tokens("cache_read_input_tokens") + tokens("cache_creation_input_tokens")
                let count = input + tokens("output_tokens")
                let previous = messageTokens[id] ?? 0
                messageTokens[id] = max(previous, count)
                totalTokens += max(0, count - previous)
                contextTokens = count
            }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let tool = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if tool == "SubagentHandback" { handbacks[id] = input["message"] as? String ?? "" }
                if tool != "SubagentHandback" && tool != "AskUserQuestion" && tool != "ExitPlanMode" {
                    let detail = condensedText(input["description"] as? String ?? "") ?? condensedText(promptText(tool: tool, input: input))
                    response = detail.map { "\(tool): \($0)" } ?? tool
                }
                guard tool == "AskUserQuestion" || tool == "ExitPlanMode" else { continue }
                let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
                pending[id] = AgentPrompt(kind: tool == "AskUserQuestion" ? .question : .permission,
                    tool: tool, text: condensedText(question ?? input["plan"] as? String ?? "") ?? "", callID: id)
            }
            if object["isApiErrorMessage"] as? Bool == true {
                event = .cancelled
            } else {
                switch message["stop_reason"] as? String {
                case "end_turn", "max_tokens", "stop_sequence", "refusal":
                    // Earlier thinking blocks also carry the message's final stop reason.
                    let thinkingOnly = !blocks.isEmpty && blocks.allSatisfy {
                        let type = $0["type"] as? String
                        return type == "thinking" || type == "redacted_thinking"
                    }
                    event = thinkingOnly ? .started : .completed
                default: event = .started
                }
            }
            if event != .started { pending.removeAll() }
        case "system":
            guard object["subtype"] as? String == "turn_duration", event != nil else { return false }
            // Some Claude versions persist null stop reasons even on their final reply.
            if event != .cancelled { event = .completed }
            pending.removeAll()
        case "progress":
            guard event == .started else { return false }
        case "custom-title":
            guard let value = object["customTitle"] as? String else { return false }
            customName = condensedText(value)
            turnActivity = false
        case "ai-title":
            guard let value = object["aiTitle"] as? String, let title = condensedText(value) else { return false }
            generatedName = title
            turnActivity = false
        default: return false
        }
        if turnActivity {
            updatedAt = (object["timestamp"] as? String).flatMap {
                claudeTimestamp.date(from: $0) ?? claudeTimestampWithoutFraction.date(from: $0)
            } ?? Date()
        }
        return true
    }
}

private let claudeTimestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let claudeTimestampWithoutFraction = ISO8601DateFormatter()

private func claudeSource(_ entrypoint: String) -> String {
    if entrypoint.contains("desktop") { return "desktop" }
    if entrypoint.contains("vscode") { return "extension" }
    return "cli"
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

// pi writes assistant toolCall blocks before executing them; while an ask-type
// tool waits for the user there is no matching toolResult entry yet.
private let piToolCallNeedle = Data("\"type\":\"toolCall\"".utf8)
private let piToolResultNeedle = Data("\"role\":\"toolResult\"".utf8)

private func piAskText(_ arguments: [String: Any]) -> String {
    for key in ["question", "prompt", "title", "message", "text"] {
        if let value = arguments[key] as? String, !value.isEmpty {
            return String(value.prefix(160))
        }
    }
    return ""
}

private func parsePiToolCalls(_ line: Data) -> [(id: String, name: String, text: String, permission: Bool)]? {
    guard line.range(of: piToolCallNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let message = object["message"] as? [String: Any],
          message["role"] as? String == "assistant",
          let blocks = message["content"] as? [[String: Any]] else { return nil }

    let calls = blocks.filter { $0["type"] as? String == "toolCall" }.compactMap { block -> (String, String, String, Bool)? in
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
        let arguments = block["arguments"] as? [String: Any] ?? [:]
        return (id, name, piAskText(arguments), isPermissionToolName(name))
    }
    return calls.isEmpty ? nil : calls
}

private func parsePiToolResultID(_ line: Data) -> String? {
    guard line.range(of: piToolResultNeedle) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let message = object["message"] as? [String: Any],
          message["role"] as? String == "toolResult" else { return nil }
    return message["toolCallId"] as? String
}

// MARK: - opencode session parsing

private struct OpencodeMessageHeader {
    let role: String
    let completed: Bool
    let stopped: Bool
    let finish: String?
    let modelID: String?
    let variant: String?
    let contextTokens: Int
}

private func parseOpencodeMessageHeader(_ data: Data) -> OpencodeMessageHeader? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let role = object["role"] as? String else { return nil }

    let time = object["time"] as? [String: Any]
    let tokens = object["tokens"] as? [String: Any]
    let cache = tokens?["cache"] as? [String: Any]

    func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    let completed = (time?["completed"] as? NSNumber) != nil
    return OpencodeMessageHeader(
        role: role,
        completed: completed,
        stopped: object["error"] is [String: Any] || object["finish"] as? String == "error",
        finish: object["finish"] as? String,
        modelID: object["modelID"] as? String,
        variant: object["variant"] as? String,
        contextTokens: number(tokens?["input"]) + number(tokens?["output"])
            + number(tokens?["reasoning"]) + number(cache?["read"]) + number(cache?["write"])
    )
}

private func opencodeTurnEvent(_ header: OpencodeMessageHeader?) -> TurnEvent? {
    guard let header else { return nil }
    if header.role == "user" { return .started }
    guard header.role == "assistant" || header.role == "idle" else { return nil }
    if header.stopped { return .cancelled }
    if header.role == "idle" { return .completed }
    if !header.completed { return .started }
    // a reply that ended in tool calls only finished one segment; the turn keeps running
    if header.finish == "tool-calls" || header.finish == "tool_calls" { return .started }
    return .completed
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

// MARK: - agent prompts (questions / permission asks)

// Tools whose "running with input but no progress" state means the agent is
// parked on a permission dialog. Long-running silent tools (webfetch, grep,
// subagent `task`) are excluded on purpose: they look identical while executing.
private let opencodePermissionTools: Set<String> = [
    "bash", "shell", "edit", "write", "read", "apply_patch", "multiedit", "ls"
]
private let opencodePromptDebounce: TimeInterval = 5
private let opencodeWaitingStatuses: Set<String> = ["pending", "streaming", "running"]

private func isAskToolName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    if lowered.hasPrefix("ask") || lowered.hasPrefix("question") { return true }
    return lowered.contains("ask_user") || lowered.contains("ask-user") || lowered.hasSuffix("-ask")
        || lowered.contains("question") || lowered.contains("confirm") || lowered.contains("approval")
        || lowered.contains("permission") || lowered.contains("request_permission") || lowered.contains("request-permission")
        || lowered.contains("request_user_input") || lowered.contains("request-user-input")
        || lowered.contains("user_input") || lowered.contains("user-input") || lowered.contains("input_request")
}

private func isPermissionToolName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.contains("permission") || lowered.contains("approval") || lowered.contains("confirm")
        || lowered.contains("authorize") || lowered.contains("request_permission") || lowered.contains("request-permission")
}

private struct OpencodeToolObservation {
    let callID: String
    let name: String
    let status: String
    let input: [String: Any]
    let progressed: Bool
    let createdAt: Date
}

// opencode logs every permission dialog it shows ("message=asking id=per_...")
// to its run log. Correlating those events with a stalled tool part is what
// separates "parked on the user" from "running a silent command".
private struct OpencodeAskingEvent: Equatable {
    let id: String
    let permission: String
    let at: Date
}

private func parseOpencodePending(id: String, type: String, data: String?) -> AgentPrompt? {
    let object = data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    var candidates: [[String: Any]] = [object]
    var index = 0
    while index < candidates.count {
        let candidate = candidates[index]
        for key in ["request", "data", "payload"] {
            if let nested = candidate[key] as? [String: Any] { candidates.append(nested) }
        }
        index += 1
    }
    let kinds = ([type] + candidates.compactMap { $0["type"] as? String }).joined(separator: " ").lowercased()
    let questionType = kinds.contains("question") || kinds.contains("form")
    let hasQuestions = candidates.contains { $0["questions"] != nil || $0["fields"] != nil || $0["question"] != nil }
    if questionType || hasQuestions {
        let text = candidates.compactMap { candidate -> String? in
            if let questions = candidate["questions"] as? [[String: Any]] {
                return questions.compactMap { $0["question"] as? String }.first
            }
            if let fields = candidate["fields"] as? [[String: Any]] {
                return fields.compactMap { ($0["label"] as? String) ?? ($0["name"] as? String) }.first
            }
            return candidate["question"] as? String
        }.first ?? ""
        return AgentPrompt(kind: .question, tool: type, text: String(text.prefix(160)), callID: id)
    }
    let permissionType = kinds.contains("permission") || kinds.contains("approval") || kinds.contains("external_directory")
    let hasPermissionData = candidates.contains { candidate in
        ["permission", "action", "resources", "resource", "command", "path", "pattern"].contains { candidate[$0] != nil }
    }
    guard permissionType || hasPermissionData else { return nil }
    let permission = candidates.compactMap { ($0["permission"] as? String) ?? ($0["action"] as? String) }.first ?? type
    let text = candidates.compactMap { candidate in
        (candidate["command"] as? String) ?? (candidate["path"] as? String) ?? (candidate["pattern"] as? String)
    }.first ?? ""
    return AgentPrompt(kind: .permission, tool: permission, text: String(text.prefix(160)), callID: id)
}

private func parseOpencodeAskingLine(_ line: String) -> OpencodeAskingEvent? {
    guard line.contains("message=asking"),
          let idRange = line.range(of: " id=") else { return nil }
    let id = String(line[idRange.upperBound...].prefix { $0 != " " })
    guard id.hasPrefix("per_") else { return nil }
    let permission = line.range(of: " permission=")
        .map { String(line[$0.upperBound...].prefix { $0 != " " }) } ?? ""
    let timestamp = line.range(of: "timestamp=")
        .map { String(line[$0.upperBound...].prefix(24)) } ?? ""
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else { return nil }
    return OpencodeAskingEvent(id: id, permission: permission, at: date)
}

private func promptText(tool: String, input: [String: Any]) -> String {
    if tool == "question" {
        let questions = (input["questions"] as? [[String: Any]]) ?? []
        let text = questions.compactMap { $0["question"] as? String }.first { !$0.isEmpty }
        if let text { return String(text.prefix(160)) }
    }
    for key in ["command", "filePath", "file_path", "path", "pattern", "url"] {
        if let value = input[key] as? String, !value.isEmpty {
            return String(value.prefix(160))
        }
    }
    return ""
}

private func opencodePrompt(
    from tools: [OpencodeToolObservation],
    askingEvents: [OpencodeAskingEvent],
    now: Date = Date()
) -> AgentPrompt? {
    for tool in tools
        where tool.name == "question"
        && !tool.input.isEmpty
        && opencodeWaitingStatuses.contains(tool.status) {
        return AgentPrompt(
            kind: .question,
            tool: tool.name,
            text: promptText(tool: tool.name, input: tool.input),
            callID: tool.callID
        )
    }
    for tool in tools
    where opencodePermissionTools.contains(tool.name)
        && opencodeWaitingStatuses.contains(tool.status)
        && !tool.progressed
        && now.timeIntervalSince(tool.createdAt) >= opencodePromptDebounce
        && askingEvents.contains(where: { event in
            let skew = event.at.timeIntervalSince(tool.createdAt)
            return skew > -5 && skew < 30
        }) {
        return AgentPrompt(
            kind: .permission,
            tool: tool.name,
            text: promptText(tool: tool.name, input: tool.input),
            callID: tool.callID
        )
    }
    return nil
}

private struct OpencodeV2Message {
    let id: String
    let header: OpencodeMessageHeader
    let text: String?
}

private func parseOpencodeV2Message(id: String, role: String, data: Data) -> OpencodeV2Message? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let time = object["time"] as? [String: Any]
    let tokens = object["tokens"] as? [String: Any]
    let cache = tokens?["cache"] as? [String: Any]
    let model = object["model"] as? [String: Any]

    func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    let completed = (time?["completed"] as? NSNumber) != nil
    let header = OpencodeMessageHeader(
        role: role,
        completed: completed,
        stopped: object["error"] is [String: Any] || object["finish"] as? String == "error"
            || ["failed", "interrupted"].contains(object["outcome"] as? String ?? ""),
        finish: object["finish"] as? String,
        modelID: model?["id"] as? String,
        variant: model?["variant"] as? String,
        contextTokens: number(tokens?["input"]) + number(tokens?["output"])
            + number(tokens?["reasoning"]) + number(cache?["read"]) + number(cache?["write"])
    )

    // v2 keeps text inline: typed prompts in `text`, replies as `content` parts
    let rawText: String?
    if role == "user" {
        rawText = object["text"] as? String
    } else {
        let parts = object["content"] as? [[String: Any]] ?? []
        rawText = parts.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
    }
    return OpencodeV2Message(id: id, header: header, text: condensedText(rawText ?? ""))
}

private func opencodeColumnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// size + mtime is enough to tell whether a file needs re-reading without opening it.
private struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified
    }
}

private func sqliteStamps(_ databaseURL: URL) -> [FileStamp?] {
    [FileStamp(databaseURL), FileStamp(URL(fileURLWithPath: databaseURL.path + "-wal"))]
}

// rollout paths among `candidates` that some process of this user has open.
// matched by device and inode because the kernel reports /private-prefixed paths.
private func filesHeldOpen(_ candidates: Set<String>) -> Set<String> {
    var wanted: [String: String] = [:]
    for path in candidates {
        var info = stat()
        if stat(path, &info) == 0 { wanted["\(UInt32(truncatingIfNeeded: info.st_dev)):\(info.st_ino)"] = path }
    }
    guard !wanted.isEmpty else { return [] }

    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
    let listed = pids.withUnsafeMutableBytes {
        proc_listallpids($0.baseAddress, Int32($0.count))
    }
    var held = Set<String>()
    for pid in pids.prefix(Int(max(0, listed))) where pid > 0 {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let used = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        for fd in fds.prefix(Int(max(0, used)) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let stat = vnode.pvip.vip_vi.vi_stat
            if let path = wanted["\(UInt32(truncatingIfNeeded: stat.vst_dev)):\(stat.vst_ino)"] {
                held.insert(path)
                if held.count == wanted.count { return held }
            }
        }
    }
    return held
}

private final class SessionMonitor {
    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        var meta: SessionMeta
    }

    var onChange: (([ThreadActivity], UsageSnapshot?, UsageSnapshot?) -> Void)?
    var onCompletion: ((ThreadActivity) -> Void)?
    var onAsking: ((ThreadActivity) -> Void)?

    private let queue = DispatchQueue(label: "app.notchstatus.sessions", qos: .utility)
    private let codexHome: URL
    private let sessionsRoot: URL
    private let shellSnapshotsRoot: URL
    private let piHome: URL
    private let piSessionsRoot: URL
    private let claudeProjectsRoot: URL
    private let claudeHome: URL
    private let opencodeDataDirectory: URL
    private let opencodeLogURL: URL
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
    private var claudeSessions: [String: ClaudeSessionState] = [:]
    private var piContextWindows: [String: Int] = [:]
    private var opencodeLastUpdates: [String: Int64] = [:]
    private var opencodeTitles: [String: String] = [:]
    private var agentPrompts: [String: AgentPrompt] = [:]
    private var promptedIDs: Set<String> = []
    private var pendingCompletions: Set<String> = []
    private var opencodeAskingEvents: [OpencodeAskingEvent] = []
    private var opencodeLogOffset: UInt64 = 0
    private var opencodeLogLoaded = false
    private struct PiOpenAsk {
        let name: String
        let text: String
        let permission: Bool
    }
    private var piOpenAsks: [String: [String: PiOpenAsk]] = [:]
    private var codexOpenPrompts: [String: [String: AgentPrompt]] = [:]
    private var nativeUsage: UsageSnapshot?
    private var nativeUsageUpdatedAt = Date.distantPast
    private var remoteRateLimits: RemoteRateLimits?
    private var accountUsageFetchInFlight = false
    private var accountUsageFetchAttemptedAt = Date.distantPast
    private var accountUsageTask: URLSessionDataTask?
    private var claudeRateLimits: RemoteRateLimits?
    private var claudeUsageUnavailableReason: String?
    private var claudeUsageFetchInFlight = false
    private var claudeUsageNextFetchAt = Date.distantPast
    private var claudeUsageTask: URLSessionDataTask?
    private let claudeUsageSession = URLSession(configuration: .ephemeral)
    private var expiryWorkItem: DispatchWorkItem?
    private var reconciliationTimer: DispatchSourceTimer?
    private var reconciliationInterval: TimeInterval = 0
    private var lastDiscoveryAt = Date.distantPast
    private var titlesStamps: [FileStamp?]?
    private var indexTitlesCache: (stamp: FileStamp?, titles: [String: String])?
    private var opencodeStoresStamps: [[FileStamp?]]?
    // files not worth reading again until they grow: metadata not written yet,
    // or idle sessions retired from the cursor set.
    private var skipUntilGrowth: [String: UInt64] = [:]
    private var abandonedCodexKeys: Set<String> = []
    private var lastLivenessCheckAt = Date.distantPast
    private var opencodeRecheckWorkItem: DispatchWorkItem?
    private var readConnections: [String: (fileNumber: UInt64, database: OpaquePointer)] = [:]
    private var generation: UInt = 0
    private var active = false
    private let lifecycleLock = NSLock()
    private var lifecycleGeneration: UInt = 0
    private var lifecycleActive = false

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

        claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        claudeProjectsRoot = claudeHome.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath()

        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        // opencode v1 and v2 share one data directory: official builds write
        // `opencode.db`, while local/parallel builds (e.g. the `ocfix` alias)
        // write `opencode-<channel>.db` next to it. legacy sessions live in the
        // `session`/`message` tables, v2 (the `opencode2` binary) in `session_v2`/`session_message`.
        opencodeDataDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        opencodeLogURL = dataHome.appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("log", isDirectory: true)
            .appendingPathComponent("opencode.log")
    }

    func start() {
        var startGeneration: UInt = 0
        queue.sync {
            generation &+= 1
            active = true
            startGeneration = generation
            lifecycleLock.lock()
            lifecycleGeneration = generation
            lifecycleActive = true
            lifecycleLock.unlock()
        }
        queue.async { [self] in
            guard active, generation == startGeneration else { return }
            titlesStamps = nil
            opencodeStoresStamps = nil
            refreshCodexTitles()
            piContextWindows = loadPiContextWindows()
            bootstrap()
            lastDiscoveryAt = Date()
            _ = reconcileOpencode()
            startEventStreams()
            startReconciliationTimer()
            publish()
        }
    }

    func stop() {
        queue.sync { [self] in
            active = false
            pendingCompletions.removeAll()
            generation &+= 1
            lifecycleLock.lock()
            lifecycleGeneration = generation
            lifecycleActive = false
            lifecycleLock.unlock()
            expiryWorkItem?.cancel()
            opencodeRecheckWorkItem?.cancel()
            opencodeRecheckWorkItem = nil
            for connection in readConnections.values { sqlite3_close(connection.database) }
            readConnections.removeAll()
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            accountUsageTask?.cancel()
            accountUsageTask = nil
            accountUsageFetchInFlight = false
            claudeUsageTask?.cancel()
            claudeUsageTask = nil
            claudeUsageFetchInFlight = false
            for stream in streams {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            streams.removeAll()
        }
    }

    func acknowledge(codexSources: Set<String>, piSources: Set<String>, opencodeSources: Set<String>, claudeSources: Set<String> = []) {
        queue.async { [self] in
            var changed = false
            let workingParents = Set(groupActivities(Array(activities.values)).filter { $0.phase == .delegating }.map { $0.root.key })
            for (key, var activity) in activities where activity.phase == .ready && !workingParents.contains(key) {
                let sources: Set<String>
                switch activity.agent {
                case .pi: sources = piSources
                case .opencode, .opencode2: sources = opencodeSources
                case .codex: sources = codexSources
                case .claude: sources = claudeSources
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
        // one pool per file: startup parses dozens of sessions in a single queue block.
        for path in recentSessionPaths() {
            autoreleasepool { _ = register(path) }
        }
    }

    private func recentSessionPaths() -> [String] {
        // Discovery and FSEvents must use the same key for filesystem aliases.
        let paths = (codexSessionPaths() + piSessionPaths() + claudeSessionPaths())
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return Array(Set(paths)).filter { cursors[$0] == nil }
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
        // The VS Code extension resumes long-lived threads whose rollout files
        // live in old date directories; the codex threads index covers those.
        paths.append(contentsOf: codexIndexedThreadPaths())
        return Array(Set(paths))
    }

    private var codexStateDatabaseURL: URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .compactMap({ file -> (Int, URL)? in
                guard file.lastPathComponent.hasPrefix("state_"), file.pathExtension == "sqlite" else { return nil }
                let digits = file.deletingPathExtension().lastPathComponent.dropFirst("state_".count)
                guard let version = Int(digits) else { return nil }
                return (version, file)
            })
            .max(by: { $0.0 < $1.0 })?.1
    }

    private func codexIndexedThreadPaths() -> [String] {
        guard let index = codexStateDatabaseURL else { return [] }
        return withReadOnlyDatabase(index) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            // Two-day cutoff mirrors the date-directory scan above.
            guard sqlite3_prepare_v2(
                database,
                "SELECT rollout_path FROM threads WHERE archived = 0 AND updated_at > ?",
                -1, &statement, nil
            ) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970 - 2 * 86_400))

            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) {
                paths.append(String(cString: text))
            }
            return paths
        } ?? []
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

    private func claudeSessionPaths() -> [String] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: claudeProjectsRoot,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        var paths: [String] = []
        for project in projects where project.hasDirectoryPath {
            guard let entries = try? manager.contentsOfDirectory(at: project,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            var files = entries.filter { $0.pathExtension == "jsonl" }
            for session in entries where session.hasDirectoryPath {
                let subagents = session.appendingPathComponent("subagents", isDirectory: true)
                files += (try? manager.contentsOfDirectory(at: subagents,
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff else { continue }
                paths.append(file.path)
            }
        }
        return paths
    }

    private func startReconciliationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        reconciliationTimer = timer
        reconciliationInterval = 0
        updateReconciliationCadence()
        timer.resume()
    }

    // fsevents deliver every session, title and opencode write (opencode permission
    // debounces get a one-shot recheck), so the timer only covers state without a
    // file signal: silent turn timeouts, dead codex processes and account usage.
    private var desiredReconciliationInterval: TimeInterval {
        activities.values.contains { $0.phase == .running } ? 10 : 30
    }

    private func updateReconciliationCadence() {
        guard let timer = reconciliationTimer else { return }
        let interval = desiredReconciliationInterval
        guard interval != reconciliationInterval else { return }
        reconciliationInterval = interval
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(interval * 250))
        )
    }

    private func reconcile() {
        var changed = refreshCodexTitles()
        // backstop for missed fsevents and roots created after launch.
        var paths = Set(cursors.keys)
        if Date().timeIntervalSince(lastDiscoveryAt) >= 60 {
            lastDiscoveryAt = Date()
            retireIdleCursors()
            paths = Set(cursors.keys).union(recentSessionPaths())
        }
        for path in paths {
            changed = (cursors[path] == nil ? register(path) : readAppendedEvents(from: path)) || changed
        }
        changed = reconcileOpencode() || changed
        changed = stopOrphanedTurns() || changed
        changed = stopAbandonedCodexTurns() || changed
        refreshCodexAccountUsageIfNeeded()
        refreshClaudeAccountUsageIfNeeded()
        if changed { publish() }
        updateReconciliationCadence()
    }

    // sessions that left the island and sat idle past the discovery window are
    // dropped; fsevents register them again if they are ever written.
    private func retireIdleCursors() {
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        for (path, cursor) in cursors where activities[cursor.meta.key] == nil {
            let stamp = FileStamp(URL(fileURLWithPath: path))
            if let stamp {
                guard stamp.modified < cutoff else { continue }
                skipUntilGrowth[path] = stamp.size
            }
            cursors.removeValue(forKey: path)
            let key = cursor.meta.key
            responses.removeValue(forKey: key)
            prompts.removeValue(forKey: key)
            models.removeValue(forKey: key)
            usages.removeValue(forKey: key)
            piBaseModels.removeValue(forKey: key)
            piProviders.removeValue(forKey: key)
            thinkingLevels.removeValue(forKey: key)
            piSessionNames.removeValue(forKey: key)
            piTotals.removeValue(forKey: key)
            claudeSessions.removeValue(forKey: key)
            codexOpenPrompts.removeValue(forKey: key)
        }
    }

    // the codex app server keeps every loaded thread's rollout open, so a running
    // turn whose rollout no process holds can never finish. without this a crashed
    // codex keeps the island animating until the six-hour silence timeout.
    private func stopAbandonedCodexTurns() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastLivenessCheckAt) >= 30 else { return false }
        let silent = cursors.filter { path, cursor in
            guard cursor.meta.agent == .codex,
                  let activity = activities[cursor.meta.key],
                  activity.phase == .running, activity.prompt == nil,
                  let stamp = FileStamp(URL(fileURLWithPath: path)) else { return false }
            return now.timeIntervalSince(stamp.modified) >= 120
        }
        guard !silent.isEmpty else { return false }
        lastLivenessCheckAt = now
        let held = filesHeldOpen(Set(silent.keys))
        var changed = false
        for (path, cursor) in silent where !held.contains(path) {
            guard var activity = activities[cursor.meta.key] else { continue }
            activity.phase = .stopped
            activity.updatedAt = now
            activities[cursor.meta.key] = activity
            abandonedCodexKeys.insert(cursor.meta.key)
            changed = true
        }
        return changed
    }

    @discardableResult
    private func refreshCodexTitles() -> Bool {
        let stamps = [FileStamp(codexHome.appendingPathComponent("session_index.jsonl"))]
            + (codexStateDatabaseURL.map(sqliteStamps) ?? [])
        guard stamps != titlesStamps else { return false }
        titlesStamps = stamps
        let refreshedTitles = loadTitles()
        guard refreshedTitles != titles else { return false }
        titles = refreshedTitles
        var changed = false
        for cursor in cursors.values where cursor.meta.agent == .codex {
            guard let previous = activities[cursor.meta.key] else { continue }
            let updated = activity(for: cursor.meta, phase: previous.phase, at: previous.updatedAt)
            if previous != updated {
                activities[cursor.meta.key] = updated
                changed = true
            }
        }
        return changed
    }

    private func stopOrphanedTurns() -> Bool {
        let now = Date()
        var changed = false
        // shortcut: silence detects abandoned turns; use process liveness if long silent work is common.
        for (key, var activity) in activities
        where activity.prompt == nil
            && shouldMarkStopped(activity.phase, updatedAt: activity.updatedAt, timeout: activity.runningTimeout, now: now) {
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
    let activityMarker: Int64
}

    private enum OpencodeSchema {
        case v1
        case v2
    }

    // Resolved on every pass so databases created after launch (e.g. by
    // starting `ocfix` later) are picked up without a restart.
    private var opencodeStores: [OpencodeStore] {
        let fallback = opencodeDataDirectory.appendingPathComponent("opencode.db")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: opencodeDataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [OpencodeStore(databaseURL: fallback)] }
        let matches = files.filter {
            $0.pathExtension == "db"
                && ($0.lastPathComponent == "opencode.db" || $0.lastPathComponent.hasPrefix("opencode-"))
        }.sorted {
            if $0.lastPathComponent == "opencode.db" { return true }
            if $1.lastPathComponent == "opencode.db" { return false }
            return $0.lastPathComponent < $1.lastPathComponent
        }
        return matches.isEmpty ? [OpencodeStore(databaseURL: fallback)] : matches.map { OpencodeStore(databaseURL: $0) }
    }

    private func reconcileOpencode() -> Bool {
        tailOpencodeLog()
        let stores = opencodeStores
        let stamps = stores.map { sqliteStamps($0.databaseURL) }
        let storesChanged = stamps != opencodeStoresStamps
        let promptsPending = activities.values.contains {
            $0.phase == .running && ($0.agent == .opencode || $0.agent == .opencode2)
        }
        guard storesChanged || promptsPending else { return false }
        opencodeStoresStamps = stamps
        var changed = false
        for store in stores where FileManager.default.fileExists(atPath: store.databaseURL.path) {
            let storeChanged = withReadOnlyDatabase(store.databaseURL) { database in
                let legacyChanged = storesChanged && readOpencodeSessions(database, agent: .opencode, table: "session", schema: .v1)
                let v2Changed = storesChanged && readOpencodeSessions(database, agent: .opencode2, table: "session_v2", schema: .v2)
                let promptChanged = refreshOpencodePrompts(database)
                return legacyChanged || v2Changed || promptChanged
            }
            // an unreadable store must be retried on the next pass even without a new write.
            if storeChanged == nil { opencodeStoresStamps = nil }
            changed = (storeChanged ?? false) || changed
        }
        return changed
    }

    private func tailOpencodeLog() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: opencodeLogURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0 else { return }
        if !opencodeLogLoaded {
            opencodeLogOffset = size > 131_072 ? size - 131_072 : 0
            opencodeLogLoaded = true
        } else if size < opencodeLogOffset {
            opencodeLogOffset = 0
        }
        guard size > opencodeLogOffset,
              let handle = try? FileHandle(forReadingFrom: opencodeLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: opencodeLogOffset)
            guard let appended = try handle.readToEnd() else { return }
            opencodeLogOffset = size
            for chunk in appended.split(separator: 0x0A) {
                if let event = parseOpencodeAskingLine(String(decoding: chunk, as: UTF8.self)) {
                    opencodeAskingEvents.append(event)
                }
            }
            if opencodeAskingEvents.count > 64 {
                opencodeAskingEvents.removeFirst(opencodeAskingEvents.count - 64)
            }
        } catch {
            return
        }
    }

    // connections stay open between passes (opening re-reads the schema each time);
    // a replaced file has a new file number and gets a fresh connection.
    private func withReadOnlyDatabase<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let path = url.path
        let fileNumber = ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
        if let cached = readConnections[path] {
            if cached.fileNumber == fileNumber { return body(cached.database) }
            sqlite3_close(cached.database)
            readConnections.removeValue(forKey: path)
        }
        guard let fileNumber else { return nil }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 300)
        readConnections[path] = (fileNumber, database)
        return body(database)
    }

    private func readOpencodeSessions(_ database: OpaquePointer, agent: AgentKind, table: String, schema: OpencodeSchema) -> Bool {
        let cutoff = Int64(
            (Date().timeIntervalSince1970 - (opencodeRunningInactivityTimeout + 5 * 60)) * 1000
        )
        let activityMarker: String = schema == .v1
            ? "MAX(time_updated, COALESCE((SELECT MAX(time_updated) FROM message WHERE session_id = \(table).id), 0))"
            : "MAX(time_updated, COALESCE((SELECT MAX(time_updated) FROM session_message WHERE session_id = \(table).id), 0), COALESCE((SELECT MAX(seq) FROM session_message WHERE session_id = \(table).id), 0))"
        let sql = """
        SELECT id, parent_id, title, directory, agent, model, cost,
               tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
               time_updated, \(activityMarker)
        FROM \(table)
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
            let activityMarker = sqlite3_column_int64(statement, 13)
            let key = "\(agent.label):\(id)"
            guard opencodeLastUpdates[key] != activityMarker else { continue }
            opencodeLastUpdates[key] = activityMarker

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
                updatedAt: Date(timeIntervalSince1970: Double(updatedAtMs) / 1000),
                activityMarker: activityMarker
            )
            changed = applyOpencodeSession(row, database: database, agent: agent, schema: schema) || changed
        }
        return changed
    }

    private func applyOpencodeSession(
        _ row: OpencodeSessionRow,
        database: OpaquePointer,
        agent: AgentKind,
        schema: OpencodeSchema
    ) -> Bool {
        let messages: [(id: String, header: OpencodeMessageHeader, text: String?)] = schema == .v1
            ? opencodeRecentMessages(database, sessionID: row.id).map { ($0.id, $0.header, nil) }
            : opencodeRecentMessagesV2(database, sessionID: row.id)
        guard let event = opencodeTurnEvent(messages.first?.header) else { return false }

        func messageText(_ message: (id: String, header: OpencodeMessageHeader, text: String?)) -> String? {
            schema == .v1 ? opencodeTextParts(database, messageID: message.id) : message.text
        }

        var prompt: String?
        var response: String?
        var model: String?
        var contextTokens = 0
        if let userIndex = messages.firstIndex(where: { $0.header.role == "user" }) {
            prompt = messageText(messages[userIndex])
            for message in messages[..<userIndex] {
                if model == nil { model = opencodeModelLabel(modelID: message.header.modelID, variant: message.header.variant) }
                if contextTokens == 0 { contextTokens = message.header.contextTokens }
                if response == nil { response = messageText(message) }
            }
        }
        if model == nil, let modelJSON = row.modelJSON { model = opencodeSessionModel(modelJSON) }

        let key = "\(agent.label):\(row.id)"
        var phase: ThreadPhase
        switch event {
        case .started: phase = .running
        case .completed: phase = .ready
        case .cancelled: phase = .stopped
        }
        if phase == .running,
           agentPrompts[key] == nil,
           shouldMarkStopped(.running, updatedAt: row.updatedAt, timeout: opencodeRunningInactivityTimeout) {
            phase = .stopped
        }
        let previousPhase = activities[key]?.phase
        if previousPhase == .seen, phase == .ready { phase = .seen }

        let meta = SessionMeta(
            id: row.id,
            agent: agent,
            parentID: row.parentID,
            nickname: row.agentName == "build" ? nil : row.agentName,
            source: "cli",
            project: URL(fileURLWithPath: row.directory).lastPathComponent
        )

        if previousPhase == .running, phase == .ready, meta.parentID == nil {
            let completed = activity(for: meta, phase: .ready, at: row.updatedAt)
            pendingCompletions.insert(completed.key)
        }

        if phase != .running { agentPrompts.removeValue(forKey: key) }

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
        if !row.title.isEmpty, !isOpencodeDefaultTitle(row.title) { opencodeTitles[key] = row.title }

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

    private func opencodeRecentMessagesV2(
        _ database: OpaquePointer,
        sessionID: String
    ) -> [(id: String, header: OpencodeMessageHeader, text: String?)] {
        // v2 writes terminal outcomes as idle records, including failures before an assistant reply.
        let sql = "SELECT id, type, data FROM session_message WHERE session_id = ?1 AND type IN ('user','assistant','idle') ORDER BY seq DESC LIMIT 8"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient)

        var messages: [(id: String, header: OpencodeMessageHeader, text: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = opencodeColumnString(statement, 0),
              let type = opencodeColumnString(statement, 1),
              let data = opencodeColumnString(statement, 2),
              let message = parseOpencodeV2Message(id: id, role: type, data: Data(data.utf8)) {
            messages.append((message.id, message.header, message.text))
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

    // MARK: - agent prompt detection

    // Question and permission waits do not bump session.time_updated, so the
    // change-gated read above can stay quiet while an agent is parked on the
    // user. Refresh prompt state for running sessions every reconcile instead.
    private func refreshOpencodePrompts(_ database: OpaquePointer) -> Bool {
        var changed = false
        let now = Date()
        for (key, activity) in activities
        where activity.phase == .running && (activity.agent == .opencode || activity.agent == .opencode2) {
            if let native = opencodeNativePending(database, sessionID: activity.id) {
                let key = activity.key
                guard agentPrompts[key] != native else { continue }
                agentPrompts[key] = native
                var updated = activity
                updated.prompt = native
                activities[key] = updated
                changed = true
                if !promptedIDs.contains(native.callID) {
                    promptedIDs.insert(native.callID)
                    dispatchAsking(updated)
                }
                continue
            }
            let observations: [OpencodeToolObservation]
            if activity.agent == .opencode {
                guard let messageID = opencodeNewestAssistantMessageID(database, sessionID: activity.id) else { continue }
                observations = opencodeToolObservationsV1(database, messageID: messageID)
            } else {
                observations = opencodeToolObservationsV2(database, sessionID: activity.id)
            }
            let prompt = opencodePrompt(from: observations, askingEvents: opencodeAskingEvents, now: now)
            guard agentPrompts[key] != prompt else { continue }
            agentPrompts[key] = prompt
            var updated = activity
            updated.prompt = prompt
            activities[key] = updated
            changed = true
            if let prompt, !promptedIDs.contains(prompt.callID) {
                promptedIDs.insert(prompt.callID)
                dispatchAsking(updated)
            }
        }
        let liveIDs = Set(agentPrompts.values.map(\.callID))
        promptedIDs.formIntersection(liveIDs)
        return changed
    }

    private func opencodeNativePending(_ database: OpaquePointer, sessionID: String) -> AgentPrompt? {
        let sql = "SELECT id, type, data FROM session_pending WHERE session_id = ?1 ORDER BY time_created DESC LIMIT 8"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient)
        while sqlite3_step(statement) == SQLITE_ROW,
              let id = opencodeColumnString(statement, 0),
              let type = opencodeColumnString(statement, 1) {
            if let prompt = parseOpencodePending(id: id, type: type, data: opencodeColumnString(statement, 2)) { return prompt }
        }
        return nil
    }

    private func opencodeNewestAssistantMessageID(_ database: OpaquePointer, sessionID: String) -> String? {
        let sql = "SELECT id, substr(data,1,65536) FROM message WHERE session_id = ?1 ORDER BY time_created DESC, rowid DESC LIMIT 8"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient)

        while sqlite3_step(statement) == SQLITE_ROW,
              let id = opencodeColumnString(statement, 0) {
            let data = opencodeColumnString(statement, 1) ?? ""
            if parseOpencodeMessageHeader(Data(data.utf8))?.role == "assistant" { return id }
        }
        return nil
    }

    private func opencodeToolObservationsV1(_ database: OpaquePointer, messageID: String) -> [OpencodeToolObservation] {
        let sql = "SELECT substr(data,1,65536), time_created FROM part WHERE message_id = ?1 ORDER BY rowid"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, messageID, -1, sqliteTransient)

        var observations: [OpencodeToolObservation] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let data = opencodeColumnString(statement, 0),
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              (object["type"] as? String) == "tool" {
            let state = object["state"] as? [String: Any] ?? [:]
            observations.append(OpencodeToolObservation(
                callID: object["callID"] as? String ?? "",
                name: object["tool"] as? String ?? "",
                status: state["status"] as? String ?? "",
                input: state["input"] as? [String: Any] ?? [:],
                progressed: state["metadata"] != nil || state["title"] != nil,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
            ))
        }
        return observations
    }

    private func opencodeToolObservationsV2(_ database: OpaquePointer, sessionID: String) -> [OpencodeToolObservation] {
        let sql = "SELECT substr(data,1,262144), time_created FROM session_message WHERE session_id = ?1 AND type = 'assistant' ORDER BY seq DESC LIMIT 3"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient)

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowTime = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
            guard let data = opencodeColumnString(statement, 0),
                  let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                  let content = object["content"] as? [[String: Any]] else { continue }

            let tools = content.filter { ($0["type"] as? String) == "tool" }
            guard !tools.isEmpty else { continue }
            return tools.map { item in
                let state = item["state"] as? [String: Any] ?? [:]
                let time = item["time"] as? [String: Any] ?? [:]
                let contentText = ((state["content"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["text"] as? String }
                    .contains { !$0.isEmpty }
                return OpencodeToolObservation(
                    callID: item["id"] as? String ?? "",
                    name: item["name"] as? String ?? item["tool"] as? String ?? "",
                    status: state["status"] as? String ?? "",
                    input: state["input"] as? [String: Any] ?? [:],
                    progressed: contentText || ((state["structured"] as? [String: Any])?.isEmpty == false),
                    createdAt: (time["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? rowTime
                )
            }
        }
        return []
    }

    private func startEventStreams() {
        // codex home (not just sessions) so saved thread names arrive as events too.
        for root in [codexHome, piSessionsRoot, claudeProjectsRoot, opencodeDataDirectory]
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
        var sessionPaths = Set<String>()
        var titlesTouched = false
        var opencodeTouched = false
        for rawPath in paths {
            // resolve the parent: deleted files (sqlite journals) keep their /private prefix otherwise.
            let url = URL(fileURLWithPath: rawPath)
            let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
            if path.hasPrefix(watchedPaths.opencode) {
                opencodeTouched = true
            } else if path.hasSuffix(".jsonl"), watchedPaths.sessions.contains(where: { path.hasPrefix($0) }) {
                sessionPaths.insert(path)
            } else if (path as NSString).deletingLastPathComponent == watchedPaths.codexHome {
                let name = (path as NSString).lastPathComponent
                if name == "session_index.jsonl" || name.hasPrefix("state_") { titlesTouched = true }
            }
        }

        var changed = false
        if titlesTouched { changed = refreshCodexTitles() || changed }
        if opencodeTouched {
            changed = reconcileOpencode() || changed
            scheduleOpencodePromptRecheck()
        }
        if !sessionPaths.isEmpty {
            let visibleIDs = Set(activities.keys)
            sessionPaths.formUnion(cursors.compactMap { visibleIDs.contains($0.value.meta.key) ? $0.key : nil })
            for path in sessionPaths {
                if cursors[path] == nil {
                    changed = register(path) || changed
                } else {
                    changed = readAppendedEvents(from: path) || changed
                }
            }
        }

        if changed { publish() }
    }

    // a permission ask only counts after a quiet debounce, which no file event
    // marks, so re-check once it elapses after the latest opencode write.
    private func scheduleOpencodePromptRecheck() {
        opencodeRecheckWorkItem?.cancel()
        opencodeRecheckWorkItem = nil
        guard activities.values.contains(where: {
            $0.phase == .running && ($0.agent == .opencode || $0.agent == .opencode2)
        }) else { return }
        let callbackGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == callbackGeneration else { return }
            if self.reconcileOpencode() { self.publish() }
        }
        opencodeRecheckWorkItem = work
        queue.asyncAfter(deadline: .now() + opencodePromptDebounce + 0.5, execute: work)
    }

    private lazy var watchedPaths: (codexHome: String, sessions: [String], opencode: String) = {
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        return (
            resolved(codexHome),
            [sessionsRoot, piSessionsRoot, claudeProjectsRoot].map { resolved($0) + "/" },
            resolved(opencodeDataDirectory) + "/"
        )
    }()

    @discardableResult
    private func register(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let fileSize = values.fileSize,
              skipUntilGrowth[path] != UInt64(fileSize) else { return false }
        guard var meta = readMeta(at: path) else {
            skipUntilGrowth[path] = UInt64(fileSize)
            return false
        }
        skipUntilGrowth.removeValue(forKey: path)

        if meta.agent == .codex { meta.source = currentSource(for: meta) }
        if meta.agent == .claude {
            claudeSessions[meta.key] = ClaudeSessionState()
            cursors[path] = Cursor(offset: 0, meta: meta)
            let changed = readAppendedEvents(from: path, notify: false)
            if let activity = activities[meta.key], let prompt = activity.prompt {
                let id = "\(meta.key):\(prompt.callID)"
                if promptedIDs.insert(id).inserted { dispatchAsking(activity) }
            }
            return changed
        }
        cursors[path] = Cursor(offset: UInt64(fileSize), meta: meta)

        let key = meta.key
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let snapshot: SessionSnapshot?

        if meta.agent == .pi {
            guard let piSnapshot = latestPiSnapshot(at: path) else { return false }
            replayPiAsks(at: path, for: meta)
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
            replayCodexPrompts(at: path, for: meta)
            snapshot = latestCodexSnapshot(at: path)
        }

        guard let snapshot else { return false }
        if let response = snapshot.response { responses[key] = response }
        if let prompt = snapshot.prompt { prompts[key] = prompt }
        if let model = snapshot.model { models[key] = model }
        if let usage = snapshot.usage { usages[key] = usage }
        if meta.agent == .codex, let usage = snapshot.usage, modifiedAt > nativeUsageUpdatedAt {
            nativeUsage = usage
            nativeUsageUpdatedAt = modifiedAt
        }
        let phase: ThreadPhase
        switch snapshot.event {
        case .started: phase = .running
        case .completed: phase = .ready
        case .cancelled: phase = .stopped
        }
        activities[key] = activity(for: meta, phase: phase, at: modifiedAt)
        if let prompt = agentPrompts[key], !promptedIDs.contains(prompt.callID) {
            promptedIDs.insert(prompt.callID)
            dispatchAsking(activities[key]!)
        }
        return true
    }

    private func readAppendedEvents(from path: String, notify: Bool = true) -> Bool {
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
        var changed = false
        // a write proves the liveness check wrong; resume the turn until its own end event.
        if abandonedCodexKeys.remove(cursor.meta.key) != nil, activities[cursor.meta.key]?.phase == .stopped {
            activities[cursor.meta.key] = activity(for: cursor.meta, phase: .running, at: Date())
            changed = true
        }
        do {
            try handle.seek(toOffset: cursor.offset)
            // bounded chunks keep the first read of a multi-gigabyte session out of memory.
            while cursor.offset < size, let appended = try handle.read(upToCount: 4 * 1024 * 1024), !appended.isEmpty {
                cursor.offset += UInt64(appended.count)
                cursor.remainder.append(appended)

                let endsWithNewline = cursor.remainder.last == 0x0A
                let parts = cursor.remainder.split(separator: 0x0A, omittingEmptySubsequences: false)
                let completeCount = endsWithNewline ? parts.count : max(0, parts.count - 1)

                for part in parts.prefix(completeCount) {
                    let line = Data(part)
                    if cursor.meta.agent == .claude {
                        changed = applyClaudeLine(line, for: &cursor.meta, notify: notify) || changed
                        continue
                    }
                    if cursor.meta.agent == .pi {
                        changed = applyPiEvent(parsePiEvent(line), for: cursor.meta) || changed
                        let calls = parsePiToolCalls(line)
                        let resolved = parsePiToolResultID(line)
                        if calls != nil || resolved != nil {
                            changed = applyPiToolEvent(calls: calls, resolved: resolved, for: cursor.meta) || changed
                        }
                        continue
                    }
                    if cursor.meta.agent == .codex {
                        let key = cursor.meta.key
                        if let pending = parseCodexPendingPrompt(line) {
                            codexOpenPrompts[key, default: [:]][pending.callID] = pending
                            agentPrompts[key] = pending
                            changed = refreshActivity(for: cursor.meta) || changed
                            if let activity = activities[key], !promptedIDs.contains(pending.callID) {
                                promptedIDs.insert(pending.callID)
                                dispatchAsking(activity)
                            }
                        } else if let resolved = parseCodexResolvedCallID(line) {
                            codexOpenPrompts[key]?.removeValue(forKey: resolved)
                            let prompt = codexOpenPrompts[key]?.values.sorted { $0.callID < $1.callID }.first
                            agentPrompts[key] = prompt
                            changed = refreshActivity(for: cursor.meta) || changed
                        }
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
                        nativeUsage = usage
                        nativeUsageUpdatedAt = Date()
                        _ = refreshActivity(for: cursor.meta)
                        changed = true
                        continue
                    }
                    guard let event = parseTurnEvent(line) else { continue }
                    refreshCodexTitles()
                    switch event {
                    case .started:
                        cursor.meta.source = currentSource(for: cursor.meta)
                        responses.removeValue(forKey: cursor.meta.key)
                        prompts.removeValue(forKey: cursor.meta.key)
                        models.removeValue(forKey: cursor.meta.key)
                        usages.removeValue(forKey: cursor.meta.key)
                        codexOpenPrompts.removeValue(forKey: cursor.meta.key)
                        agentPrompts.removeValue(forKey: cursor.meta.key)
                        activities[cursor.meta.key] = activity(for: cursor.meta, phase: .running, at: Date())
                    case .completed:
                        codexOpenPrompts.removeValue(forKey: cursor.meta.key)
                        agentPrompts.removeValue(forKey: cursor.meta.key)
                        let completed = activity(for: cursor.meta, phase: .ready, at: Date())
                        if activities[cursor.meta.key]?.phase == .running, cursor.meta.parentID == nil {
                            pendingCompletions.insert(completed.key)
                        }
                        activities[cursor.meta.key] = completed
                    case .cancelled:
                        codexOpenPrompts.removeValue(forKey: cursor.meta.key)
                        agentPrompts.removeValue(forKey: cursor.meta.key)
                        activities[cursor.meta.key] = activity(for: cursor.meta, phase: .stopped, at: Date())
                    }
                    changed = true
                }

                cursor.remainder = endsWithNewline ? Data() : Data(parts.last ?? Data.SubSequence())
            }
        } catch {
            // keep whatever was consumed before the read failed.
        }
        cursors[path] = cursor
        return changed
    }

    private func applyClaudeLine(_ line: Data, for meta: inout SessionMeta, notify: Bool) -> Bool {
        let key = meta.key
        let previousEvent = claudeSessions[key]?.event
        let previousDate = claudeSessions[key]?.updatedAt
        let previousNames = claudeSessions[key]?.subagentNames ?? [:]
        guard claudeSessions[key, default: ClaudeSessionState()].consume(line),
              let state = claudeSessions[key] else { return false }
        if let source = state.source { meta.source = source }
        guard let event = state.event, let date = state.updatedAt else { return false }
        prompts[key] = state.prompt
        responses[key] = state.response
        models[key] = state.model
        usages[key] = state.usage
        agentPrompts[key] = state.pending.values.sorted { $0.callID < $1.callID }.first

        let previous = activities[key]
        let phase: ThreadPhase
        if let previous, previousEvent == event,
           previousDate == date || (previous.phase == .seen && event == .completed) {
            phase = previous.phase
        } else {
            switch event {
            case .started: phase = .running
            case .completed: phase = .ready
            case .cancelled: phase = .stopped
            }
        }
        let updated = activity(for: meta, phase: phase, at: date)
        activities[key] = updated
        if state.subagentNames != previousNames {
            for cursor in cursors.values where cursor.meta.agent == .claude && cursor.meta.parentID == meta.id {
                if let child = activities[cursor.meta.key] {
                    activities[child.key] = activity(for: cursor.meta, phase: child.phase, at: child.updatedAt)
                }
            }
        }
        if notify {
            if previous?.phase == .running, phase == .ready, meta.parentID == nil {
                pendingCompletions.insert(updated.key)
            }
            if let prompt = updated.prompt, promptedIDs.insert("\(key):\(prompt.callID)").inserted {
                dispatchAsking(updated)
            }
        }
        return previous != updated
    }

    @discardableResult
    private func applyPiEvent(_ event: PiEvent?, for meta: SessionMeta) -> Bool {
        guard let event else { return false }
        let key = meta.key

    switch event {
        case .userPrompt(let prompt):
            refreshCodexTitles()
            piContextWindows = loadPiContextWindows()
            piOpenAsks.removeValue(forKey: key)
            agentPrompts.removeValue(forKey: key)
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
                piOpenAsks.removeValue(forKey: key)
                agentPrompts.removeValue(forKey: key)
                let completed = activity(for: meta, phase: .ready, at: Date())
                if activities[key]?.phase == .running {
                    pendingCompletions.insert(completed.key)
                }
                activities[key] = completed
            case "aborted", "error":
                piOpenAsks.removeValue(forKey: key)
                agentPrompts.removeValue(forKey: key)
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

    // MARK: - pi ask tracking

    @discardableResult
    private func applyPiToolEvent(
         calls: [(id: String, name: String, text: String, permission: Bool)]?,
        resolved: String?,
        for meta: SessionMeta
    ) -> Bool {
        let key = meta.key
        var changed = false

        for call in calls ?? [] {
            guard isAskToolName(call.name) else { continue }
            if piOpenAsks[key]?[call.id] == nil {
            piOpenAsks[key, default: [:]][call.id] = PiOpenAsk(name: call.name, text: call.text, permission: call.permission)
                changed = true
            }
        }
        if let resolved, piOpenAsks[key]?.removeValue(forKey: resolved) != nil {
            changed = true
        }
        guard changed else { return false }
        updatePiPrompt(for: meta)
        return true
    }

    private func replayPiAsks(at path: String, for meta: SessionMeta) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let cap: UInt64 = 8 * 1024 * 1024
        guard size > 0,
              (try? handle.seek(toOffset: size > cap ? size - cap : 0)) != nil,
              let data = try? handle.read(upToCount: Int(min(size, cap))) else { return }

        for chunk in data.split(separator: 0x0A) {
            let line = Data(chunk)
            _ = applyPiToolEvent(calls: parsePiToolCalls(line), resolved: parsePiToolResultID(line), for: meta)
        }
        updatePiPrompt(for: meta)
    }

    private func updatePiPrompt(for meta: SessionMeta) {
        let key = meta.key
        let prompt = (piOpenAsks[key] ?? [:])
            .sorted { $0.key < $1.key }
            .first
            .map { AgentPrompt(kind: $0.value.permission ? .permission : .question, tool: $0.value.name, text: $0.value.text, callID: $0.key) }
        guard agentPrompts[key] != prompt, let current = activities[key] else {
            agentPrompts[key] = prompt
            return
        }
        agentPrompts[key] = prompt
        var updated = current
        updated.prompt = prompt
        activities[key] = updated
        if let prompt, !promptedIDs.contains(prompt.callID) {
            promptedIDs.insert(prompt.callID)
            dispatchAsking(updated)
        }
    }

    private func replayCodexPrompts(at path: String, for meta: SessionMeta) {
        let key = meta.key
        codexOpenPrompts.removeValue(forKey: key)
        // A turn boundary resolves protocol items that did not emit a result,
        // so only the lines after the newest boundary can still be open.
        for item in codexLinesAfterLastTurnBoundary(at: path) {
            if let pending = parseCodexPendingPrompt(item) {
                codexOpenPrompts[key, default: [:]][pending.callID] = pending
            } else if let resolved = parseCodexResolvedCallID(item) {
                codexOpenPrompts[key]?.removeValue(forKey: resolved)
            }
        }
        agentPrompts[key] = codexOpenPrompts[key]?.values.sorted { $0.callID < $1.callID }.first
    }

    // scans backward so long-lived rollouts (gigabytes) are never read whole.
    private func codexLinesAfterLastTurnBoundary(at path: String) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return [] }
        defer { try? handle.close() }

        let cap: UInt64 = 32 * 1024 * 1024
        let floor = size > cap ? size - cap : 0
        let chunkSize: UInt64 = 64 * 1024
        var position = size
        var carry = Data()
        var lines: [Data] = []
        while position > floor {
            let count = min(chunkSize, position - floor)
            position -= count
            guard (try? handle.seek(toOffset: position)) != nil,
                  var buffer = try? handle.read(upToCount: Int(count)) else { break }
            buffer.append(carry)
            let parts = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstComplete = position == 0 ? 0 : min(1, parts.count)
            for part in parts.dropFirst(firstComplete).reversed() where !part.isEmpty {
                let line = Data(part)
                if parseTurnEvent(line) != nil,
                   parseCodexPendingPrompt(line) == nil,
                   parseCodexResolvedCallID(line) == nil {
                    return lines.reversed()
                }
                lines.append(line)
            }
            carry = parts.first.map { Data($0) } ?? Data()
        }
        return lines.reversed()
    }

    private func latestCodexSnapshot(at path: String) -> SessionSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        // a turn longer than this is still summarized from its newest events.
        let cap: UInt64 = 64 * 1024 * 1024
        let floor = size > cap ? size - cap : 0
        var position = size
        var carry = Data()
        var latestEvent: TurnEvent?
        var response: String?
        var prompt: String?
        var model: String?
        var usage: UsageSnapshot?

        while position > floor {
            let count = min(chunkSize, position - floor)
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

        guard let prefix = try? handle.read(upToCount: 1_048_576) else { return nil }
        if URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(claudeProjectsRoot.path + "/") {
            // Metadata records can precede the first conversation message.
            for line in prefix.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let sessionID = object["sessionId"] as? String,
                      let cwd = object["cwd"] as? String else { continue }
                let file = URL(fileURLWithPath: path)
                let isChild = file.deletingLastPathComponent().lastPathComponent == "subagents"
                    || object["isSidechain"] as? Bool == true
                let agentID = object["agentId"] as? String
                    ?? file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "agent-", with: "")
                return SessionMeta(id: isChild ? "\(sessionID):agent:\(agentID)" : sessionID, agent: .claude,
                    parentID: isChild ? sessionID : nil, nickname: nil,
                    source: claudeSource(object["entrypoint"] as? String ?? "cli"),
                    project: URL(fileURLWithPath: cwd).lastPathComponent)
            }
            return nil
        }
        guard let firstLine = prefix.split(separator: 0x0A, maxSplits: 1).first,
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
        let indexStamp = FileStamp(index)
        var result: [String: String] = [:]
        if let cache = indexTitlesCache, cache.stamp == indexStamp {
            result = cache.titles
        } else {
            if let data = try? Data(contentsOf: index) {
                for line in data.split(separator: 0x0A) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let id = object["id"] as? String,
                          let title = object["thread_name"] as? String,
                          let name = condensedText(title) else { continue }
                    result[id] = name
                }
            }
            indexTitlesCache = (indexStamp, result)
        }
        guard let databaseURL = codexStateDatabaseURL else { return result }
        return withReadOnlyDatabase(databaseURL) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let filter = "FROM threads WHERE archived = 0 AND updated_at > ?"
            if sqlite3_prepare_v2(database, "SELECT id, name, title \(filter)", -1, &statement, nil) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                // Older Codex databases have a title but no separate manual name.
                guard sqlite3_prepare_v2(database, "SELECT id, NULL, title \(filter)", -1, &statement, nil) == SQLITE_OK else { return result }
            }
            sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970 - 2 * 86_400))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let id = String(cString: text)
                let name = sqlite3_column_text(statement, 1).flatMap { condensedText(String(cString: $0)) }
                let title = sqlite3_column_text(statement, 2).flatMap { condensedText(String(cString: $0)) }
                result[id] = name ?? result[id] ?? title
            }
            return result
        } ?? result
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
        let title: String?
        switch meta.agent {
        case .codex: title = titles[meta.id] ?? prompts[meta.key]
        case .claude:
            title = meta.parentID.flatMap { claudeSessions["claude:\($0)"]?.subagentNames[meta.id] }
                ?? claudeSessions[meta.key]?.name ?? prompts[meta.key]
        case .pi: title = prompts[meta.key] ?? piSessionNames[meta.key]
        case .opencode, .opencode2: title = opencodeTitles[meta.key] ?? prompts[meta.key]
        }
        return ThreadActivity(
            id: meta.id,
            agent: meta.agent,
            parentID: meta.parentID,
            nickname: meta.nickname,
            title: title ?? (meta.project.isEmpty ? "\(meta.agent.displayName) thread" : meta.project),
            detail: responses[meta.key] ?? "",
            source: meta.source,
            project: meta.project,
            model: models[meta.key] ?? "",
            usage: usages[meta.key],
            phase: phase,
            updatedAt: date,
            prompt: agentPrompts[meta.key]
        )
    }

    private func refreshCodexAccountUsageIfNeeded() {
        // Account limits are account-wide and must not depend on a retained
        // Codex session. Pi and OpenCode can consume the same Codex account.
        guard !accountUsageFetchInFlight,
        Date().timeIntervalSince(accountUsageFetchAttemptedAt) >= 60 else { return }
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else { return }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        accountUsageFetchInFlight = true
        accountUsageFetchAttemptedAt = Date()
        let callbackGeneration = generation
        accountUsageTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = parseCodexUsageResponse(data) else {
                self?.queue.async { [weak self] in
                    guard let self, self.active, self.generation == callbackGeneration else { return }
                    self.accountUsageFetchInFlight = false
                    self.accountUsageTask = nil
                }
                return
            }
            self.queue.async { [weak self] in
                guard let self else { return }
                guard self.active, self.generation == callbackGeneration else { return }
                self.accountUsageFetchInFlight = false
                self.accountUsageTask = nil
                guard parsed.primary != nil || parsed.secondary != nil else { return }
                self.remoteRateLimits = mergedRateLimits(self.remoteRateLimits, with: RemoteRateLimits(
                    primary: parsed.primary, secondary: parsed.secondary))
                self.publish()
            }
        }
        accountUsageTask?.resume()
    }

    private func refreshClaudeAccountUsageIfNeeded() {
        guard !claudeUsageFetchInFlight, Date() >= claudeUsageNextFetchAt else { return }
        claudeUsageFetchInFlight = true
        claudeUsageNextFetchAt = Date().addingTimeInterval(60)
        let callbackGeneration = generation
        let home = claudeHome
        // A Keychain read must not block the session watcher or app shutdown.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let credential = loadClaudeAccessToken(home: home)
            self?.queue.async { [weak self] in
                guard let self, self.active, self.generation == callbackGeneration else { return }
                let previousReason = self.claudeUsageUnavailableReason
                guard let token = credential.token else {
                    self.claudeUsageFetchInFlight = false
                    self.claudeUsageUnavailableReason = credential.unavailableReason
                    self.publish()
                    return
                }
                if self.claudeRateLimits == nil {
                    self.claudeUsageUnavailableReason = nil
                    if previousReason != nil { self.publish() }
                }
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
                request.httpMethod = "GET"
                request.timeoutInterval = 20
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                self.claudeUsageTask = self.claudeUsageSession.dataTask(with: request) { [weak self] data, response, _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.active, self.generation == callbackGeneration else { return }
                        self.claudeUsageFetchInFlight = false
                        self.claudeUsageTask = nil
                        let http = response as? HTTPURLResponse
                        if http?.statusCode == 429 {
                            let delay = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                            self.claudeUsageNextFetchAt = Date().addingTimeInterval(delay.isFinite ? max(60, delay) : 300)
                        }
                        let parsed = http?.statusCode == 200 ? data.flatMap(parseClaudeUsageResponse) : nil
                        self.claudeUsageUnavailableReason = claudeUsageFailure(statusCode: http?.statusCode, limits: parsed)
                        self.claudeRateLimits = mergedRateLimits(self.claudeRateLimits, with: parsed)
                        self.publish()
                    }
                }
                self.claudeUsageTask?.resume()
            }
        }
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
        let groups = groupActivities(Array(activities.values))
        for group in groups where !group.children.isEmpty && group.root.phase != .running {
            activities[group.root.key]?.updatedAt = group.updatedAt
            if group.phase == .delegating && group.root.phase == .ready { pendingCompletions.insert(group.root.key) }
        }
        let workingGroups = groups.filter { $0.phase == .running || $0.phase == .delegating || $0.asking }
        let workingKeys = Set(workingGroups.flatMap { [$0.root.key] + $0.children.map(\.key) })
        activities = activities.filter { workingKeys.contains($0.key) || shouldRetain($0.value.phase, updatedAt: $0.value.updatedAt, now: now) }
        let liveKeys = Set(activities.keys)
        agentPrompts = agentPrompts.filter { liveKeys.contains($0.key) }
        piOpenAsks = piOpenAsks.filter { liveKeys.contains($0.key) }
        refreshCodexAccountUsageIfNeeded()
        refreshClaudeAccountUsageIfNeeded()
        scheduleExpiry(excluding: workingKeys)
        pendingCompletions = pendingCompletions.filter { activities[$0]?.phase == .ready }
        let completed = groupActivities(Array(activities.values)).filter {
            $0.phase == .ready && pendingCompletions.remove($0.root.key) != nil
        }.map(\.root)
        let snapshot = activities.values.sorted {
            if ($0.prompt != nil) != ($1.prompt != nil) {
                return $0.prompt != nil
            }
            if phaseRank($0.phase) != phaseRank($1.phase) {
                return phaseRank($0.phase) < phaseRank($1.phase)
            }
            return $0.updatedAt > $1.updatedAt
        }
        let usage = effectiveUsage(local: nativeUsage, remote: remoteRateLimits)
        let claudeUsage = effectiveUsage(local: nil, remote: claudeRateLimits, unavailableReason: claudeUsageUnavailableReason)
        let callbackGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycle(callbackGeneration) else { return }
            self.onChange?(snapshot, usage, claudeUsage)
        }
        for activity in completed { dispatchCompletion(activity) }
        updateReconciliationCadence()
    }

    // Completion callbacks use the same lifecycle boundary as state updates.
    private func dispatchCompletion(_ completed: ThreadActivity) {
        let callbackGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycle(callbackGeneration) else { return }
            self.onCompletion?(completed)
        }
    }

    private func dispatchAsking(_ activity: ThreadActivity) {
        let callbackGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycle(callbackGeneration) else { return }
            self.onAsking?(activity)
        }
    }

    private func isCurrentLifecycle(_ callbackGeneration: UInt) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycleActive && lifecycleGeneration == callbackGeneration
    }

    private func scheduleExpiry(excluding workingKeys: Set<String>) {
        expiryWorkItem?.cancel()
        guard let nextExpiry = activities.values
            .filter({ $0.phase != .running && !workingKeys.contains($0.key) })
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
    let asking: Bool

    private var childCounts: [(label: String, count: Int)] {
        [
            ("running", children.filter { $0.phase == .running && $0.prompt == nil }.count),
            ("asking", children.filter { $0.prompt != nil }.count),
            ("done", children.filter { $0.phase == .ready || $0.phase == .seen }.count),
            ("stopped", children.filter { $0.phase == .stopped }.count),
        ].filter { $0.count > 0 }
    }

    var subagentSummary: String {
        (["\(children.count) subagent\(children.count == 1 ? "" : "s")"] + childCounts.map { "\($0.count) \($0.label)" })
            .joined(separator: " · ")
    }

    // the disclosure button carries the live count so the parent row keeps its own latest response.
    var subagentBadge: String {
        let running = children.filter { $0.phase == .running }.count
        return running > 0 ? "\(running)/\(children.count) running" : "\(children.count) agent\(children.count == 1 ? "" : "s")"
    }
}

private struct ActivityRow {
    let activity: ThreadActivity
    let phase: ThreadPhase
    let depth: Int
    let childCount: Int
    var subagentSummary: String? = nil
    var subagentBadge: String? = nil
    var subagentAsking = false
    // distance from the top of the row list; subagent rows are shorter than thread rows.
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var isFirstChild = false
    var isLastChild = false
    var parentModel: String? = nil
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
        let children = members.filter { $0.id != root.id }.sorted {
            if ($0.prompt != nil) != ($1.prompt != nil) { return $0.prompt != nil }
            if phaseRank($0.phase) != phaseRank($1.phase) { return phaseRank($0.phase) < phaseRank($1.phase) }
            return $0.updatedAt > $1.updatedAt
        }
        let childIsRunning = children.contains { $0.phase == .running }
        return ActivityGroup(
            root: root,
            children: children,
            phase: root.phase != .running && childIsRunning ? .delegating : root.phase,
            updatedAt: members.map(\.updatedAt).max() ?? root.updatedAt,
            asking: members.contains { $0.prompt != nil }
        )
    }.sorted {
        if $0.asking != $1.asking {
            return $0.asking
        }
        if phaseRank($0.phase) == phaseRank($1.phase) {
            return $0.updatedAt > $1.updatedAt
        }
        return phaseRank($0.phase) < phaseRank($1.phase)
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
    if minutes == 10_080 { return "weekly" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
}

private let resetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter
}()

private let resetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("dMMM")
    return formatter
}()

private func usageSummary(_ usage: UsageSnapshot?) -> String {
    guard let usage else { return "" }
    var parts: [String] = []
    if usage.contextWindow > 0 {
        parts.append("ctx \(Int((100 * Double(usage.contextTokens) / Double(usage.contextWindow)).rounded()))%")
    }
    parts.append("\(compactTokens(usage.totalTokens)) tok")
    return parts.joined(separator: " · ")
}

private func usageWindows(_ usage: UsageSnapshot?, agent: AgentKind) -> [(label: String, minutes: Int, limit: RateLimitUsage?)] {
    if agent == .claude { return [("5h", 300, usage?.primaryLimit), ("weekly", 10_080, usage?.secondaryLimit)] }
    return [usage?.primaryLimit, usage?.secondaryLimit].compactMap { $0 }
        .sorted { $0.windowMinutes < $1.windowMinutes }
        .map { (rateWindowLabel($0.windowMinutes), $0.windowMinutes, $0) }
}

private func resetLabel(_ limit: RateLimitUsage) -> String? {
    guard let date = limit.resetsAt else { return nil }
    // Provider timestamps can land just before or after a minute boundary.
    let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    let day = limit.windowMinutes >= 24 * 60 ? "\(resetDateFormatter.string(from: minute)) " : ""
    return "\(day)\(resetTimeFormatter.string(from: minute))"
}

private func remainingUsageSummary(_ usage: UsageSnapshot?, agent: AgentKind = .codex) -> String {
    let windows = usageWindows(usage, agent: agent)
    var parts = [agent.displayName]
    parts += windows.isEmpty ? ["usage unavailable"] : windows.map { label, _, limit in
        guard let limit else { return "\(label) unavailable" }
        var text = "\(label) \(compactPercent(max(0, 100 - limit.usedPercent)))% left"
        if let reset = resetLabel(limit) { text += " ↻ \(reset)" }
        return text
    }
    if let warning = usage?.refreshWarning { parts.append(warning) }
    return parts.joined(separator: " · ")
}

// one footer cell per usage window; a nil remainingPercent marks an unavailable window.
private struct LimitCell: Equatable {
    let label: String
    let windowMinutes: Int
    let remainingPercent: Double?
    let reset: String?
}

private func limitCells(_ usage: UsageSnapshot?, agent: AgentKind) -> [LimitCell] {
    usageWindows(usage, agent: agent).map { label, minutes, limit in
        LimitCell(
            label: label == "weekly" ? "7d" : label,
            windowMinutes: minutes,
            remainingPercent: limit.map { max(0, 100 - $0.usedPercent) },
            reset: limit.flatMap(resetLabel)
        )
    }
}

private func limitStatusSymbol(_ usage: UsageSnapshot?) -> String? {
    guard let reason = usage?.unavailableReason else { return nil }
    return reason.hasPrefix("Keychain") ? "🔒" : "⚠"
}

private enum LimitLevel: Equatable {
    case normal
    case low
    case critical
}

private func limitLevel(remainingPercent: Double) -> LimitLevel {
    if remainingPercent <= 10 { return .critical }
    if remainingPercent <= 25 { return .low }
    return .normal
}

// draw() runs on every animation frame; creating system fonts there churns
// CoreText's font cache; crash reports show CoreText aborting in this path after hours of uptime.
private enum Typeface {
    static let count = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    static let title = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let childTitle = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    static let body = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let badge = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .bold)
    static let caption = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let footer = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    static let disclosure = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    static let tag = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
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
    static let claudeCoral = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.35, alpha: 1)
    static let askPink = NSColor(srgbRed: 1.0, green: 0.35, blue: 0.66, alpha: 1)
    static let phosphor = NSColor(white: 0.94, alpha: 1)
    // muted text sits near the 4.5:1 contrast floor on black; the old 0.29 grey was ~2.3:1 and unreadable at 9pt.
    static let tertiaryInk = NSColor(white: 0.64, alpha: 1)
    static let mutedInk = NSColor(white: 0.47, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.1)
    static let treeGuide = NSColor(white: 1, alpha: 0.2)
    static let tagFill = NSColor(white: 1, alpha: 0.09)
}

private func notificationWarning(
    authorization: UNAuthorizationStatus,
    alerts: UNNotificationSetting,
    style: UNAlertStyle
) -> String? {
    switch authorization {
    case .notDetermined, .denied:
        return "Notifications off"
    case .provisional:
        return "Banners off"
    case .authorized:
        return alerts != .enabled || style == .none ? "Banners off" : nil
    @unknown default:
        return nil
    }
}

private enum FooterPiece {
    case text(String, NSColor)
    case meter(Double, NSColor)
    case dashes(CGFloat, NSColor)
    case space(CGFloat)
}

// footer pieces measured once per data change, then drawn left to right on every frame.
private struct FooterRun {
    private(set) var pieces: [(piece: FooterPiece, width: CGFloat)] = []
    private(set) var width: CGFloat = 0

    mutating func append(_ piece: FooterPiece) {
        let pieceWidth: CGFloat
        switch piece {
        case let .text(text, _): pieceWidth = Self.width(of: text)
        case .meter: pieceWidth = 20
        case let .dashes(dashes, _): pieceWidth = dashes
        case let .space(space): pieceWidth = space
        }
        pieces.append((piece, pieceWidth))
        width += pieceWidth
    }

    static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Typeface.footer]).width)
    }

    var text: String {
        pieces.compactMap { piece, _ -> String? in
            guard case let .text(text, _) = piece else { return nil }
            return text
        }.joined(separator: " ")
    }
}

private struct FooterLayout {
    struct LimitLine {
        let agent: AgentKind
        // keyed by window length, so each window lines up with the same window on the other provider's row.
        let cells: [Int: (label: String, run: FooterRun)]
        // shown in the first column when the provider reports no windows at all.
        let placeholder: FooterRun?
        let status: FooterRun?
    }

    struct Column {
        let minutes: Int
        // stands in for a window the plan doesn't have, e.g. the 5h limit on ChatGPT Pro.
        let absent: FooterRun
        var width: CGFloat
    }

    let limitLines: [LimitLine]
    let columns: [Column]

    // "no limit" means the plan lacks the window; the dash means nothing loaded at all.
    func run(for line: LimitLine, column index: Int) -> FooterRun? {
        let column = columns[index]
        if let cell = line.cells[column.minutes] { return cell.run }
        if let placeholder = line.placeholder { return index == 0 ? placeholder : nil }
        return column.absent
    }
}

private func limitColor(_ level: LimitLevel) -> NSColor {
    switch level {
    case .normal: return Palette.tertiaryInk
    case .low: return Palette.pacYellow
    case .critical: return Palette.stoppedOrange
    }
}

private func footerRun(for cell: LimitCell) -> FooterRun {
    var run = FooterRun()
    run.append(.text(cell.label, Palette.tertiaryInk))
    run.append(.space(5))
    guard let remaining = cell.remainingPercent else {
        run.append(.text("—", Palette.mutedInk))
        return run
    }
    let color = limitColor(limitLevel(remainingPercent: remaining))
    run.append(.meter(remaining / 100, color))
    run.append(.space(5))
    run.append(.text("\(compactPercent(remaining))%", color))
    if let reset = cell.reset {
        run.append(.space(6))
        run.append(.text("↻ \(reset)", Palette.mutedInk))
    }
    return run
}

private func footerLimitLine(_ usage: UsageSnapshot?, agent: AgentKind) -> FooterLayout.LimitLine {
    let cells = Dictionary(
        limitCells(usage, agent: agent).map { ($0.windowMinutes, (label: $0.label, run: footerRun(for: $0))) },
        uniquingKeysWith: { first, _ in first }
    )
    var placeholder: FooterRun?
    if cells.isEmpty {
        var unavailable = FooterRun()
        unavailable.append(.text("—", Palette.mutedInk))
        placeholder = unavailable
    }
    let status = limitStatusSymbol(usage).map { symbol -> FooterRun in
        var run = FooterRun()
        run.append(.text(symbol, Palette.pacYellow))
        return run
    }
    return FooterLayout.LimitLine(agent: agent, cells: cells, placeholder: placeholder, status: status)
}

// a dashed track stretches between the label and a right-aligned note, so the cell spans its column
// exactly like a real window does, whatever width the neighbouring reset times give that column.
private func absentFooterRun(label: String, filling width: CGFloat) -> FooterRun {
    let note = "no limit"
    let fixedWidth = FooterRun.width(of: label) + 5 + 6 + FooterRun.width(of: note)
    var run = FooterRun()
    run.append(.text(label, Palette.mutedInk))
    run.append(.space(5))
    run.append(.dashes(max(20, width - fixedWidth), Palette.mutedInk.withAlphaComponent(0.55)))
    run.append(.space(6))
    run.append(.text(note, Palette.mutedInk))
    return run
}

private func footerColumns(for lines: [FooterLayout.LimitLine]) -> [FooterLayout.Column] {
    let labels = Dictionary(lines.flatMap { $0.cells.map { ($0.key, $0.value.label) } }, uniquingKeysWith: { first, _ in first })
    var columns = labels.keys.sorted().map { minutes -> FooterLayout.Column in
        let width = lines.compactMap { $0.cells[minutes]?.run.width }.max() ?? 0
        let absent = absentFooterRun(label: labels[minutes]!, filling: width)
        let missing = lines.contains { $0.cells[minutes] == nil && $0.placeholder == nil }
        return FooterLayout.Column(minutes: minutes, absent: absent, width: missing ? max(width, absent.width) : width)
    }
    if let placeholderWidth = lines.compactMap({ $0.placeholder?.width }).max() {
        if columns.isEmpty { columns = [FooterLayout.Column(minutes: 0, absent: FooterRun(), width: 0)] }
        columns[0].width = max(columns[0].width, placeholderWidth)
    }
    return columns
}

private final class IslandView: NSView {
    var onExpansionChange: ((Bool) -> Void)?
    private(set) var expanded = false
    // rows and footer are read many times per animation frame; derive them once per change.
    private var activities: [ThreadActivity] = [] { didSet { invalidateLayout() } }
    private var accountUsage: UsageSnapshot? { didSet { invalidateLayout() } }
    private var claudeUsage: UsageSnapshot? { didSet { invalidateLayout() } }
    private var cachedRows: [ActivityRow]?
    private var cachedHiddenRowCount = 0
    private var cachedFooterLayout: FooterLayout?
    private var topBandHeight: CGFloat = 32
    private var physicalNotchWidth: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var hoverWorkItem: DispatchWorkItem?
    private var disclosureButtons: [String: NSButton] = [:]
    private let notificationButton = NSButton()
    private var notificationWarning: String? { didSet { invalidateLayout() } }
    private var expandedGroupIDs = Set<String>() { didSet { invalidateLayout() } }
    private var mouthOpen = true
    private var pacmanProgress: CGFloat = 0
    private let rowHeight: CGFloat = 58
    private let childRowHeight: CGFloat = 40
    private var maxRowsHeight: CGFloat { 8 * rowHeight }
    // a pointer passing over the notch on its way to the menu bar should not unfold the island.
    private let hoverIntentDelay: TimeInterval = 0.15
    private func invalidateLayout() {
        cachedRows = nil
        cachedFooterLayout = nil
    }

    private var footerLayout: FooterLayout {
        if let cachedFooterLayout { return cachedFooterLayout }
        let limitLines = [footerLimitLine(accountUsage, agent: .codex), footerLimitLine(claudeUsage, agent: .claude)]
        let layout = FooterLayout(limitLines: limitLines, columns: footerColumns(for: limitLines))
        cachedFooterLayout = layout
        return layout
    }
    private var notificationWarningHeight: CGFloat { notificationWarning == nil ? 0 : 26 }
    private var footerHeight: CGFloat { CGFloat(footerLayout.limitLines.count) * 15 + 11 + notificationWarningHeight }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent status")
        setAccessibilityHelp("Hover or click to show Codex, Pi, opencode, opencode2 and Claude session details, including pending questions and permission asks")
        notificationButton.target = self
        notificationButton.action = #selector(openNotificationSettings(_:))
        notificationButton.isBordered = false
        notificationButton.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        notificationButton.contentTintColor = Palette.pacYellow
        notificationButton.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)
        notificationButton.imageHugsTitle = true
        notificationButton.isHidden = true
        addSubview(notificationButton)
    }

    required init?(coder: NSCoder) { nil }

    func setNotificationWarning(_ warning: String?) {
        guard notificationWarning != warning else { return }
        notificationWarning = warning
        layoutNotificationButton()
        updateAccessibilityValue()
        needsDisplay = true
    }

    func update(activities: [ThreadActivity], accountUsage: UsageSnapshot?, claudeUsage: UsageSnapshot? = nil) {
        let previousGroups = Set(groupActivities(self.activities).filter { !$0.children.isEmpty }.map { $0.root.key })
        let previouslyAsking = Set(self.activities.filter { $0.prompt != nil }.map(\.key))
        self.activities = activities
        self.accountUsage = accountUsage
        self.claudeUsage = claudeUsage
        toolTip = claudeUsage?.refreshWarning
        expandedGroupIDs.formIntersection(groupActivities(activities).map { activityUIIdentity($0.root) })
        // a subagent that starts asking reopens its group even if it was collapsed by hand.
        expandedGroupIDs.formUnion(groupActivities(activities).filter { group in
            (!previousGroups.contains(group.root.key) && group.children.contains { $0.phase == .running })
                || group.children.contains { $0.prompt != nil && !previouslyAsking.contains($0.key) }
        }.map { $0.root.key })
        syncDisclosureButtons()
        layoutNotificationButton()
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
        layoutNotificationButton()
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
        cancelHoverIntent()
        schedulePointerCheck()
    }

    private func updateExpansion(for event: NSEvent) {
        guard islandPath().contains(convert(event.locationInWindow, from: nil)) else {
            cancelHoverIntent()
            schedulePointerCheck()
            return
        }
        guard !expanded else {
            setExpanded(true)
            return
        }
        guard hoverWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hoverWorkItem = nil
            if pointerIsInsideIsland { setExpanded(true) }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverIntentDelay, execute: work)
    }

    private func cancelHoverIntent() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
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
        cancelHoverIntent()
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
        layoutNotificationButton()
    }

    // the collapsed island only has room for one indicator per ear; agent status outranks the settings warning.
    private var collapsedIslandIsIdle: Bool {
        !activities.contains { $0.prompt != nil }
            && !groupActivities(activities).contains { [.running, .delegating, .stopped, .ready].contains($0.phase) }
    }

    private func layoutNotificationButton() {
        notificationButton.isHidden = notificationWarning == nil || (!expanded && !collapsedIslandIsIdle)
        guard let warning = notificationWarning else { return }
        notificationButton.title = "\(warning) · Open settings ↗"
        notificationButton.imagePosition = expanded ? .imageLeft : .imageOnly
        notificationButton.setAccessibilityLabel("\(warning). Open notification settings")
        notificationButton.toolTip = "Enable notifications and banners for notchtail in System Settings to receive task and attention alerts."
        notificationButton.frame = expanded
            ? NSRect(x: bounds.minX + bodyInset + 12, y: footerHeight - notificationWarningHeight,
                width: bounds.width - 2 * bodyInset - 24, height: notificationWarningHeight)
            : NSRect(x: bounds.minX + bodyInset + collapsedEarInset - 12, y: bounds.maxY - topBandHeight / 2 - 12, width: 24, height: 24)
    }

    @objc private func openNotificationSettings(_ sender: Any?) {
        let identifier = Bundle.main.bundleIdentifier ?? "app.notchtail"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)")!
        if !NSWorkspace.shared.open(url) {
            NSLog("Unable to open notification settings")
            NSSound.beep()
        }
    }

    private var rowsHeight: CGFloat { visibleRows.last.map { $0.offset + $0.height } ?? rowHeight }
    private var overflowHeight: CGFloat { hiddenRowCount > 0 ? 16 : 0 }
    var expandedContentHeight: CGFloat {
        rowsHeight + overflowHeight + footerHeight + 10
    }

    private var visibleRows: [ActivityRow] {
        if let cachedRows { return cachedRows }
        var rows: [ActivityRow] = []
        var used: CGFloat = 0
        var hidden = 0
        func fits(_ height: CGFloat) -> Bool { used + height <= maxRowsHeight }
        for (index, group) in groupActivities(activities).enumerated() {
            guard index < 5, fits(rowHeight) else {
                hidden += 1
                continue
            }
            rows.append(ActivityRow(
                activity: group.root,
                phase: group.phase,
                depth: 0,
                childCount: group.children.count,
                subagentSummary: group.children.isEmpty ? nil : group.subagentSummary,
                subagentBadge: group.children.isEmpty ? nil : group.subagentBadge,
                subagentAsking: group.children.contains { $0.prompt != nil },
                offset: used,
                height: rowHeight
            ))
            used += rowHeight
            guard expandedGroupIDs.contains(activityUIIdentity(group.root)) else { continue }
            let firstChildIndex = rows.count
            for child in group.children {
                guard fits(childRowHeight) else {
                    hidden += 1
                    continue
                }
                rows.append(ActivityRow(
                    activity: child,
                    phase: child.phase,
                    depth: 1,
                    childCount: 0,
                    offset: used,
                    height: childRowHeight,
                    isFirstChild: rows.count == firstChildIndex,
                    parentModel: group.root.model
                ))
                used += childRowHeight
            }
            if rows.count > firstChildIndex { rows[rows.count - 1].isLastChild = true }
        }
        cachedRows = rows
        cachedHiddenRowCount = hidden
        return rows
    }

    private var hiddenRowCount: Int {
        _ = visibleRows
        return cachedHiddenRowCount
    }

    private func rowStatus(_ row: ActivityRow) -> (text: String, color: NSColor) {
        row.activity.prompt != nil
            ? ("ASKING", Palette.askPink)
            : (statusText(for: row.phase), statusColor(for: row.phase))
    }

    // every face is monospaced, so one advance measures any string without per-frame text layout.
    private static let badgeCharacterWidth = ("M" as NSString).size(withAttributes: [.font: Typeface.badge]).width
    private static let footerCharacterWidth = ("M" as NSString).size(withAttributes: [.font: Typeface.footer]).width
    private static let tagCharacterWidth = ("M" as NSString).size(withAttributes: [.font: Typeface.tag]).width

    private func statusPillWidth(_ text: String) -> CGFloat {
        (CGFloat(text.count) * Self.badgeCharacterWidth + 12).rounded(.up)
    }

    private var statusPillRight: CGFloat { bounds.maxX - bodyInset - 10 }

    private func syncDisclosureButtons() {
        let rows = visibleRows
        let groupIDs = Set(groupActivities(activities).filter { !$0.children.isEmpty }.map { activityUIIdentity($0.root) })
        for id in disclosureButtons.keys.filter({ !groupIDs.contains($0) }) {
            disclosureButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in groupIDs where disclosureButtons[id] == nil {
            let button = NSButton(title: "", target: self, action: #selector(toggleGroup(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.isBordered = false
            button.focusRingType = .none
            button.font = Typeface.disclosure
            button.contentTintColor = Palette.vscodeBlue
            addSubview(button)
            disclosureButtons[id] = button
        }
        for button in disclosureButtons.values { button.isHidden = true }
        guard expanded else { return }
        for row in rows where row.depth == 0 && row.childCount > 0 {
            let identity = activityUIIdentity(row.activity)
            let button = disclosureButtons[identity]!
            let isExpanded = expandedGroupIDs.contains(identity)
            let title = "\(isExpanded ? "▾" : "▸") \(row.subagentBadge ?? "\(row.childCount) agents")"
            button.title = title
            button.toolTip = row.subagentSummary ?? "\(row.childCount) subagents"
            button.contentTintColor = row.subagentAsking ? Palette.askPink : Palette.vscodeBlue
            button.setAccessibilityLabel("\(isExpanded ? "Hide" : "Show") \(row.subagentSummary ?? "\(row.childCount) subagents")")
            let width = ceil((title as NSString).size(withAttributes: [.font: Typeface.disclosure]).width) + 10
            button.frame = NSRect(
                x: statusPillRight - statusPillWidth(rowStatus(row).text) - 6 - width,
                y: bounds.maxY - topBandHeight - row.offset - 24,
                width: width,
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
        let launchAtLogin = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let notifications = menu.addItem(
            withTitle: "Notification Settings…",
            action: #selector(openNotificationSettings(_:)),
            keyEquivalent: ""
        )
        notifications.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit notchtail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Unable to change launch at login: %@", error.localizedDescription)
            NSSound.beep()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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

    private static let checkGlyph: [UInt8] = [
        0b0000000,
        0b0000001,
        0b0000010,
        0b1000100,
        0b0101000,
        0b0010000,
        0b0000000,
    ]

    private static let crossGlyph: [UInt8] = [
        0b0000000,
        0b0100010,
        0b0010100,
        0b0001000,
        0b0010100,
        0b0100010,
        0b0000000,
    ]

    // the ears beside the hardware notch mirror each other: the left says who (or how many), the right says what.
    private var collapsedEarInset: CGFloat { 18 }

    private func drawCollapsed() {
        let centerY = bounds.maxY - topBandHeight / 2
        let bodyRight = bounds.maxX - bodyInset
        let leftEar = NSPoint(x: bounds.minX + bodyInset + collapsedEarInset, y: centerY)
        let rightEar = NSPoint(x: bodyRight - collapsedEarInset, y: centerY)
        let groups = groupActivities(activities)
        let runningCount = groups.filter { $0.phase == .running || $0.phase == .delegating }.count

        if let prompting = activities.first(where: { $0.prompt != nil }) {
            drawAgentSprite(agent: prompting.agent, at: leftEar, pixel: 2, color: Palette.askPink, running: false)
            drawQuestionMark(at: rightEar, pixel: 2, color: Palette.askPink, blink: mouthOpen)
            updateAccessibilityHelp("\(prompting.agent.displayName) is asking: \(prompting.prompt?.line ?? "")")
            return
        }

        if runningCount > 0 {
            drawText(
                String(runningCount),
                in: NSRect(x: leftEar.x - 14, y: centerY - 8, width: 28, height: 16),
                font: Typeface.count,
                color: Palette.phosphor,
                alignment: .center
            )
            let runningAgents = Set(groups.filter { $0.phase == .running || $0.phase == .delegating }.map(\.root.agent))
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
            let agentOrder: [AgentKind] = [.codex, .pi, .claude, .opencode, .opencode2]
            let lead = agentOrder.first { runningAgents.contains($0) } ?? .codex
            drawAgentSprite(agent: lead, at: NSPoint(x: pacmanX, y: centerY), pixel: 2, color: Palette.pacYellow, running: true)
            var trailX = pacmanX - 16
            for agent in agentOrder
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
            updateAccessibilityHelp("Agent is working")
        } else if let stopped = groups.first(where: { $0.phase == .stopped }) {
            drawAgentSprite(agent: stopped.root.agent, at: leftEar, pixel: 2, color: Palette.stoppedOrange, running: false)
            drawPixelSprite(Self.crossGlyph, at: rightEar, pixel: 2, color: Palette.stoppedOrange, bob: false)
            updateAccessibilityHelp("\(stopped.root.title) stopped")
        } else if let ready = groups.first(where: { $0.phase == .ready }) {
            drawAgentSprite(agent: ready.root.agent, at: leftEar, pixel: 2, color: Palette.readyGreen, running: false)
            drawPixelSprite(Self.checkGlyph, at: rightEar, pixel: 2, color: Palette.readyGreen, bob: false)
            updateAccessibilityHelp("\(ready.root.title) is complete")
        } else if let warning = notificationWarning {
            // the bell button sits in the left ear.
            drawText(
                "OFF",
                in: capCenteredRect(x: rightEar.x - 14, width: 28, centerY: centerY, font: Typeface.badge),
                font: Typeface.badge,
                color: Palette.pacYellow,
                alignment: .center
            )
            updateAccessibilityHelp("\(warning). Expand the island to open notification settings")
        } else {
            Palette.ghostPurple.withAlphaComponent(0.7).setFill()
            for ear in [leftEar, rightEar] {
                NSBezierPath(ovalIn: NSRect(x: ear.x - 2, y: centerY - 2, width: 4, height: 4)).fill()
            }
            updateAccessibilityHelp("No active agent turns")
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
                in: NSRect(x: bodyLeft + 16, y: footerHeight + 40, width: bodyRight - bodyLeft - 32, height: 14),
                font: Typeface.body,
                color: Palette.tertiaryInk,
                alignment: .center
            )
            drawText(
                "Codex, Claude, Pi and opencode turns appear here",
                in: NSRect(x: bodyLeft + 16, y: footerHeight + 24, width: bodyRight - bodyLeft - 32, height: 13),
                font: Typeface.footer,
                color: Palette.mutedInk,
                alignment: .center
            )
            return
        }

        for row in rows {
            let rowTop = bounds.maxY - topBandHeight - row.offset
            if row.depth == 0 {
                drawThreadRow(row, top: rowTop, bodyLeft: bodyLeft, bodyRight: bodyRight)
            } else {
                drawSubagentRow(row, top: rowTop, bodyLeft: bodyLeft, bodyRight: bodyRight)
            }
        }

        if hiddenRowCount > 0 {
            drawText(
                "+\(hiddenRowCount) more",
                in: NSRect(x: bodyLeft + 16, y: footerHeight + 9, width: bodyRight - bodyLeft - 32, height: 13),
                font: Typeface.footer,
                color: Palette.mutedInk,
                alignment: .center
            )
        }
    }

    private func drawThreadRow(_ row: ActivityRow, top rowTop: CGFloat, bodyLeft: CGFloat, bodyRight: CGFloat) {
        let activity = row.activity
        let centerY = rowTop - 18
        let prompt = activity.prompt
        let status = rowStatus(row)
        let textX = bodyLeft + 35
        let pillLeft = drawStatusPill(status.text, color: status.color, centerY: rowTop - 15)
        let disclosure = row.childCount > 0 ? disclosureButtons[activityUIIdentity(activity)] : nil
        let titleRight = (disclosure?.isHidden == false ? disclosure!.frame.minX : pillLeft) - 8
        let metadata = [
            activity.agent == .claude ? nil : agentRowLabel(activity.agent),
            surfaceLabel(activity.agent, source: activity.source),
            String(activity.project.prefix(18)),
            activity.model,
            usageSummary(activity.usage),
            relativeAge(activity.updatedAt),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        drawAgentSprite(
            agent: activity.agent,
            at: NSPoint(x: bodyLeft + 16, y: centerY),
            pixel: 2,
            color: status.color,
            running: row.phase == .running
        )
        drawText(
            activity.title,
            in: NSRect(x: textX, y: rowTop - 24, width: max(60, titleRight - textX), height: 16),
            font: Typeface.title,
            color: Palette.phosphor
        )
        drawText(
            prompt?.line ?? (activity.detail.isEmpty ? row.subagentSummary ?? "" : activity.detail),
            in: NSRect(x: textX, y: rowTop - 42, width: bodyRight - textX - 10, height: 14),
            font: Typeface.caption,
            color: prompt != nil ? Palette.askPink : Palette.tertiaryInk
        )
        drawSourceMarker(agent: activity.agent, source: activity.source, in: NSRect(x: textX, y: rowTop - 53, width: 8, height: 8))
        drawText(
            metadata,
            in: NSRect(x: textX + 13, y: rowTop - 57, width: bodyRight - textX - 23, height: 13),
            font: Typeface.footer,
            color: Palette.mutedInk
        )
    }

    // subagents get two lines: role, task, usage and status, then the current action.
    private func drawSubagentRow(_ row: ActivityRow, top rowTop: CGFloat, bodyLeft: CGFloat, bodyRight: CGFloat) {
        let activity = row.activity
        let prompt = activity.prompt
        let status = rowStatus(row)
        let finished = prompt == nil && (row.phase == .ready || row.phase == .seen)
        let lineY = rowTop - 12
        let textX = bodyLeft + 46
        drawTreeGuide(for: row, top: rowTop, elbowY: lineY, x: bodyLeft + 16)
        drawAgentSprite(
            agent: activity.agent,
            at: NSPoint(x: bodyLeft + 34, y: lineY),
            pixel: 1.5,
            color: status.color,
            running: row.phase == .running
        )

        // plain status text keeps the parent's filled pill the strongest mark in the group.
        let statusWidth = CGFloat(status.text.count) * Self.badgeCharacterWidth
        let statusX = statusPillRight - 6 - statusWidth
        drawText(
            status.text,
            in: capCenteredRect(x: statusX, width: statusWidth + 1, centerY: lineY, font: Typeface.badge),
            font: Typeface.badge,
            color: status.color
        )

        let usage = [
            modelDelta(activity.model, parent: row.parentModel),
            activity.usage.map { "\(compactTokens($0.totalTokens)) tok" },
            relativeAge(activity.updatedAt),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let usageWidth = CGFloat(usage.count) * Self.footerCharacterWidth
        let usageX = statusX - 10 - usageWidth
        drawText(
            usage,
            in: capCenteredRect(x: usageX, width: usageWidth + 1, centerY: lineY, font: Typeface.footer),
            font: Typeface.footer,
            color: Palette.mutedInk
        )

        var titleX = textX
        if let nickname = activity.nickname, !nickname.isEmpty {
            titleX = drawRoleTag(String(nickname.prefix(14)), x: textX, centerY: lineY) + 6
        }
        drawText(
            activity.title,
            in: capCenteredRect(x: titleX, width: max(40, usageX - 10 - titleX), centerY: lineY, font: Typeface.childTitle),
            font: Typeface.childTitle,
            color: finished ? Palette.tertiaryInk : Palette.phosphor
        )
        drawText(
            prompt?.line ?? activity.detail,
            in: NSRect(x: textX, y: rowTop - 35, width: bodyRight - textX - 10, height: 14),
            font: Typeface.caption,
            color: prompt != nil ? Palette.askPink : finished ? Palette.mutedInk : Palette.tertiaryInk
        )
    }

    // one continuous guide runs from under the parent's sprite to the last visible subagent.
    private func drawTreeGuide(for row: ActivityRow, top rowTop: CGFloat, elbowY: CGFloat, x: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: row.isFirstChild ? rowTop + 29 : rowTop))
        if row.isLastChild {
            path.line(to: NSPoint(x: x, y: elbowY + 4))
            path.curve(
                to: NSPoint(x: x + 4, y: elbowY),
                controlPoint1: NSPoint(x: x, y: elbowY + 1.8),
                controlPoint2: NSPoint(x: x + 1.8, y: elbowY)
            )
        } else {
            path.line(to: NSPoint(x: x, y: rowTop - row.height))
            path.move(to: NSPoint(x: x, y: elbowY))
        }
        path.line(to: NSPoint(x: x + 10, y: elbowY))
        Palette.treeGuide.setStroke()
        path.stroke()
    }

    // returns the tag's right edge so the title can follow it.
    private func drawRoleTag(_ text: String, x: CGFloat, centerY: CGFloat) -> CGFloat {
        let width = (CGFloat(text.count) * Self.tagCharacterWidth + 8).rounded(.up)
        let tag = NSRect(x: x, y: centerY - 6.5, width: width, height: 13)
        Palette.tagFill.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
        drawText(
            text,
            in: capCenteredRect(x: tag.minX, width: width, centerY: centerY, font: Typeface.tag),
            font: Typeface.tag,
            color: Palette.tertiaryInk,
            alignment: .center
        )
        return tag.maxX
    }

    // a text rect whose capitals sit centered on centerY, so text lines up with sprites, tags and pills.
    private func capCenteredRect(x: CGFloat, width: CGFloat, centerY: CGFloat, font: NSFont) -> NSRect {
        let top = (centerY - font.capHeight / 2 + font.ascender).rounded()
        let height = ceil(font.ascender - font.descender) + 2
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    // returns the pill's left edge so the title can stop short of it.
    private func drawStatusPill(_ text: String, color: NSColor, centerY: CGFloat) -> CGFloat {
        let width = statusPillWidth(text)
        let pill = NSRect(x: statusPillRight - width, y: centerY - 7, width: width, height: 14)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        drawText(
            text,
            in: capCenteredRect(x: pill.minX, width: width, centerY: centerY, font: Typeface.badge),
            font: Typeface.badge,
            color: color,
            alignment: .center
        )
        return pill.minX
    }

    private func drawFooter(bodyLeft: CGFloat, bodyRight: CGFloat) {
        Palette.hairline.setFill()
        NSRect(x: bodyLeft + 12, y: footerHeight + 5, width: bodyRight - bodyLeft - 24, height: 1).fill()

        let layout = footerLayout
        let iconWidth: CGFloat = 18
        let columnGap: CGFloat = 16
        let columnsWidth = layout.columns.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, layout.columns.count - 1))
        let statusWidth = layout.limitLines.compactMap { $0.status?.width }.max().map { $0 + 8 } ?? 0
        let tableWidth = iconWidth + columnsWidth + statusWidth
        // both providers share one centered table so their 5h and 7d columns line up.
        let tableX = max(bodyLeft + 12, (bodyLeft + bodyRight - tableWidth) / 2).rounded(.down)
        for (index, line) in layout.limitLines.enumerated() {
            let y = footerHeight - notificationWarningHeight - CGFloat(index + 1) * 15
            drawAgentSprite(agent: line.agent, at: NSPoint(x: tableX + 5.25, y: y + 6.75), pixel: 1.5,
                color: line.agent == .claude ? Palette.claudeCoral : Palette.tertiaryInk, running: false)
            var x = tableX + iconWidth
            for (index, column) in layout.columns.enumerated() {
                if let run = layout.run(for: line, column: index) { drawFooterRun(run, x: x, y: y) }
                x += column.width + columnGap
            }
            if let status = line.status {
                drawFooterRun(status, x: tableX + iconWidth + columnsWidth + 8, y: y)
            }
        }
    }

    private func drawFooterRun(_ run: FooterRun, x startX: CGFloat, y: CGFloat) {
        let font = Typeface.footer
        var x = startX
        for (piece, width) in run.pieces {
            switch piece {
            case let .text(text, color):
                drawText(text, in: NSRect(x: x, y: y, width: width + 1, height: 13), font: font, color: color)
            case let .meter(fraction, color):
                // sit the bar on the text's x-height so it reads as part of the line.
                let midY = y + 13 - font.ascender + font.xHeight / 2
                let track = NSRect(x: x, y: (midY - 1.5).rounded(), width: width, height: 3)
                Palette.hairline.setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                color.setFill()
                let filled = NSRect(x: track.minX, y: track.minY, width: max(1.5, track.width * CGFloat(min(1, fraction))), height: track.height)
                NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
            case let .dashes(_, color):
                let midY = (y + 13 - font.ascender + font.xHeight / 2).rounded()
                let dashes = NSBezierPath()
                dashes.move(to: NSPoint(x: x, y: midY))
                dashes.line(to: NSPoint(x: x + width, y: midY))
                dashes.lineWidth = 1
                dashes.setLineDash([2, 3], count: 2, phase: 0)
                color.setStroke()
                dashes.stroke()
            case .space:
                break
            }
            x += width
        }
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

    private func drawCodexLogo(at center: NSPoint, pixel: CGFloat, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = pixel * 7 / 24
        context.translateBy(x: center.x - 12 * scale, y: center.y + 12 * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // The circular terminal mark from OpenAI's official Codex IDE extension.
        context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        context.move(to: CGPoint(x: 8.5, y: 9.5))
        context.addLine(to: CGPoint(x: 10, y: 12))
        context.addLine(to: CGPoint(x: 8.5, y: 14.5))
        context.move(to: CGPoint(x: 13, y: 14.5))
        context.addLine(to: CGPoint(x: 16, y: 14.5))
        context.strokePath()
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

    private func drawQuestionMark(at center: NSPoint, pixel: CGFloat, color: NSColor, blink: Bool) {
        let rows: [UInt8] = [
            0b0011100,
            0b0100010,
            0b0000010,
            0b0001100,
            0b0001000,
            0b0000000,
            0b0001000,
        ]
        drawPixelSprite(
            rows,
            at: center,
            pixel: pixel,
            color: blink ? color : color.withAlphaComponent(0.45),
            bob: false
        )
    }

    private func drawPixelSprite<Row: BinaryInteger>(_ rows: [Row], width: Int = 7, at center: NSPoint, pixel: CGFloat, color: NSColor, bob: Bool) {
        let origin = NSPoint(
            x: center.x - pixel * CGFloat(width) / 2,
            y: center.y - pixel * CGFloat(rows.count) / 2 + (bob ? pixel : 0)
        )
        color.setFill()
        let path = NSBezierPath()
        for (y, row) in rows.enumerated() {
            for x in 0..<width where row & (1 << (width - 1 - x)) != 0 {
                path.appendRect(NSRect(
                    x: origin.x + CGFloat(x) * pixel,
                    y: origin.y + CGFloat(rows.count - 1 - y) * pixel,
                    width: pixel,
                    height: pixel
                ))
            }
        }
        path.fill()
    }

    private func drawAgentSprite(agent: AgentKind, at center: NSPoint, pixel: CGFloat, color: NSColor, running: Bool) {
        switch agent {
        case .codex:
            drawCodexLogo(at: center, pixel: pixel, color: color)
        case .pi:
            drawPiSymbol(at: center, pixel: pixel, color: color, bob: running && mouthOpen)
        case .opencode, .opencode2:
            drawOpencodeLogo(at: center, pixel: pixel, color: color, bob: running && mouthOpen)
        case .claude:
            let rows: [UInt16] = [
                0b001111111100,
                0b001011110100,
                0b111111111111,
                0b111111111111,
                0b001111111100,
                0b001111111100,
                0b001010010100,
                0b001010010100,
            ]
            drawPixelSprite(rows, width: 12, at: center, pixel: pixel * 7 / 12, color: color, bob: running && mouthOpen)
        }
    }

    private func statusColor(for phase: ThreadPhase) -> NSColor {
        switch phase {
        case .running: return Palette.pacYellow
        case .delegating: return Palette.vscodeBlue
        case .ready: return Palette.readyGreen
        case .stopped: return Palette.stoppedOrange
        case .seen: return Palette.tertiaryInk
        }
    }

    private func statusText(for phase: ThreadPhase) -> String {
        switch phase {
        case .running: return "RUNNING"
        case .delegating: return "AGENTS"
        case .ready: return "DONE"
        case .stopped: return "STOPPED"
        case .seen: return "DONE"
        }
    }

    private func drawSourceMarker(agent: AgentKind, source: String, in rect: NSRect) {
        let color: NSColor
        switch agent {
        case .pi:
            color = Palette.piCyan
        case .opencode, .opencode2:
            color = Palette.ocSilver
        case .claude:
            color = Palette.claudeCoral
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
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: Self.truncatingParagraphs[alignment] ?? Self.truncatingParagraphs[.left]!,
        ])
    }

    private static let truncatingParagraphs: [NSTextAlignment: NSParagraphStyle] = Dictionary(
        uniqueKeysWithValues: [NSTextAlignment.left, .center, .right].map { alignment in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            return (alignment, paragraph)
        }
    )

    // drawCollapsed runs per animation frame; only touch accessibility when the text changes.
    private func updateAccessibilityHelp(_ help: String) {
        if accessibilityHelp() != help { setAccessibilityHelp(help) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        updateAnimationTimer()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        updateAnimationTimer()
        if window?.occlusionState.contains(.visible) == true { needsDisplay = true }
    }

    private func updateAnimationTimer() {
        // a locked screen, sleeping display or hidden island cannot show the animation.
        let visible = window?.occlusionState.contains(.visible) ?? false
        let shouldAnimate = visible && activities.contains { $0.phase == .running || $0.prompt != nil }
        if shouldAnimate, animationTimer == nil {
            // ~6 fps is enough for a 2px sprite; the step keeps a ~3s lap across the notch.
            let frameInterval: TimeInterval = 0.16
            let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                mouthOpen.toggle()
                pacmanProgress += CGFloat(frameInterval / 3)
                if pacmanProgress >= 1 { pacmanProgress = 0 }
                needsDisplay = true
            }
            // lets the system coalesce frame wakeups with other timers.
            timer.tolerance = 0.04
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
        let groups = groupActivities(activities)
        let running = groups.filter { $0.phase == .running }.count
        let delegating = groups.filter { $0.phase == .delegating }.count
        let ready = groups.filter { $0.phase == .ready }.count
        let stopped = groups.filter { $0.phase == .stopped }.count
        let seen = groups.filter { $0.phase == .seen }.count
        let asking = groups.filter(\.asking).count
        let agentCounts = [AgentKind.opencode, .opencode2, .claude].compactMap { agent -> String? in
            let count = activities.filter { $0.agent == agent }.count
            guard count > 0, let label = agentRowLabel(agent) else { return nil }
            return "\(label) \(count)"
        }.joined(separator: ", ")
        let notificationSummary = notificationWarning.map { ", \($0). Open notification settings to enable banners" } ?? ""
        setAccessibilityValue(
            "\(asking) asking, \(running) running, \(delegating) delegating, \(ready) ready, \(stopped) stopped, \(seen) seen"
                + (agentCounts.isEmpty ? "" : ", \(agentCounts)")
                + groups.filter { !$0.children.isEmpty }.map { ", \($0.root.title): \($0.subagentSummary)" }.joined()
                + ", \(remainingUsageSummary(accountUsage).replacingOccurrences(of: "↻", with: "resets"))"
                + ", \(remainingUsageSummary(claudeUsage, agent: .claude).replacingOccurrences(of: "↻", with: "resets"))"
                + notificationSummary
        )
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandController {
    var onExpansion: (() -> Void)?
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

        island.onExpansionChange = { [weak self] expanded in
            self?.resize(animated: true)
            if expanded { self?.onExpansion?() }
        }
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

    func update(_ activities: [ThreadActivity], accountUsage: UsageSnapshot?, claudeUsage: UsageSnapshot?) {
        island.update(activities: activities, accountUsage: accountUsage, claudeUsage: claudeUsage)
        resize(animated: true)
    }

    func setNotificationWarning(_ warning: String?) {
        island.setNotificationWarning(warning)
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
    var claudeSources: Set<String> = []

    var isEmpty: Bool { codexSources.isEmpty && piSources.isEmpty && opencodeSources.isEmpty && claudeSources.isEmpty }
}

private func acknowledgementPlan(for application: NSRunningApplication) -> AcknowledgementPlan {
    let identifier = application.bundleIdentifier?.lowercased() ?? ""
    let name = application.localizedName?.lowercased() ?? ""
    if identifier.contains("codex") || name == "codex" { return AcknowledgementPlan(codexSources: ["codex"]) }
    if identifier.contains("claude") || name == "claude" { return AcknowledgementPlan(claudeSources: ["desktop"]) }
    if identifier.contains("vscode") || identifier.contains("cursor") || name.contains("visual studio code") {
        return AcknowledgementPlan(codexSources: ["extension", "cli"], piSources: ["cli"], opencodeSources: ["cli"], claudeSources: ["extension", "cli"])
    }
    let terminals = ["terminal", "ghostty", "iterm", "kitty", "warp", "alacritty", "wezterm"]
    return terminals.contains(where: { identifier.contains($0) || name.contains($0) })
        ? AcknowledgementPlan(codexSources: ["cli"], piSources: ["cli"], opencodeSources: ["cli"], claudeSources: ["cli"])
        : AcknowledgementPlan()
}

private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let monitor = SessionMonitor()
    private var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { NSLog("Notification authorization failed: %@", error.localizedDescription) }
            self?.refreshNotificationSettings()
        }

        let island = IslandController()
        self.island = island
        island.onExpansion = { [weak self] in self?.refreshNotificationSettings() }
        refreshNotificationSettings()
        monitor.onChange = { [weak island] activities, usage, claudeUsage in
            island?.update(activities, accountUsage: usage, claudeUsage: claudeUsage)
        }
        monitor.onCompletion = { activity in
            let content = UNMutableNotificationContent()
            content.title = "\(activity.agent.displayName) task complete"
            let marker: String
            switch activity.agent {
            case .pi:
                marker = "🟦"
            case .opencode, .opencode2:
                marker = "⬜"
            case .claude:
                marker = "🟧"
             case .codex:
                 marker = ["extension": "🟦", "cli": "🟩", "codex": "🟪"][activity.source] ?? "⬜"
             }
             content.subtitle = "\(marker) \(activity.project.prefix(18))"
             content.body = activity.title
             content.sound = .default
             NSSound(named: "Blow")?.play()
            notifications.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                withCompletionHandler: { error in
                    if let error { NSLog("Notification delivery failed: %@", error.localizedDescription) }
                }
            )
        }
        monitor.onAsking = { activity in
            guard let prompt = activity.prompt else { return }
            let content = UNMutableNotificationContent()
             content.title = "\(activity.agent.displayName) needs you"
             content.subtitle = "❓ \(activity.project.prefix(18))"
             content.body = "\(prompt.verb) — \(prompt.line)"
             content.sound = .default
             NSSound(named: "Ping")?.play()
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
            self.refreshNotificationSettings()
            let plan = acknowledgementPlan(for: application)
            if !plan.isEmpty {
                self.monitor.acknowledge(
                    codexSources: plan.codexSources,
                    piSources: plan.piSources,
                    opencodeSources: plan.opencodeSources,
                    claudeSources: plan.claudeSources
                )
            }
        }
        monitor.start()
    }

    private func refreshNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let warning = notificationWarning(
                authorization: settings.authorizationStatus,
                alerts: settings.alertSetting,
                style: settings.alertStyle
            )
            DispatchQueue.main.async { self?.island?.setNotificationWarning(warning) }
        }
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
    let heldFile = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-held-\(UUID().uuidString).jsonl")
    try! Data("{}\n".utf8).write(to: heldFile)
    let heldHandle = try! FileHandle(forReadingFrom: heldFile)
    assert(filesHeldOpen([heldFile.path]) == [heldFile.path], "An open rollout must count as held")
    try! heldHandle.close()
    assert(filesHeldOpen([heldFile.path]).isEmpty, "A closed rollout must not count as held")
    try? FileManager.default.removeItem(at: heldFile)

    assert(notificationWarning(authorization: .denied, alerts: .disabled, style: .none) == "Notifications off")
    assert(notificationWarning(authorization: .notDetermined, alerts: .disabled, style: .none) == "Notifications off")
    assert(notificationWarning(authorization: .authorized, alerts: .disabled, style: .banner) == "Banners off")
    assert(notificationWarning(authorization: .authorized, alerts: .enabled, style: .none) == "Banners off")
    assert(notificationWarning(authorization: .provisional, alerts: .enabled, style: .banner) == "Banners off")
    assert(notificationWarning(authorization: .authorized, alerts: .enabled, style: .banner) == nil)
    assert(notificationWarning(authorization: .authorized, alerts: .enabled, style: .alert) == nil)
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
    let currentCodexPrompt = Data(##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nIgnore this context as a title."},{"type":"input_text","text":"Restore the thread names"}]}}"##.utf8)
    let currentCodexResponse = Data(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Names restored."}]}}"#.utf8)
    assert(parsePrompt(currentCodexPrompt) == "Restore the thread names", "Current Codex user messages must supply the session label")
    assert(parseResponse(currentCodexResponse) == "Names restored.")
    let codexContextOnly = Data(##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nContext"},{"type":"input_text","text":"<environment_context>Context</environment_context>"}]}}"##.utf8)
    assert(parsePrompt(codexContextOnly) == nil, "Injected context must not become a session label")
    let codexTypedContent = Data(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Injected context"},{"type":"input_text","text":"Actual request"},{"type":"input_image","image_url":"unused"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["agents_md.instructions","user.text","user.image"]}}}"#.utf8)
    assert(parsePrompt(codexTypedContent) == "Actual request")
    assert(parsePrompt(currentCodexResponse) == nil && parseResponse(currentCodexPrompt) == nil)
    assert(parseModel(context) == "gpt-5.6-sol/high")
    assert(parseUsage(usage)?.contextTokens == 50_000)
    assert(surfaceLabel(.codex, source: "codex") == "desktop" && surfaceLabel(.codex, source: "extension") == "extension")
    assert(surfaceLabel(.claude, source: "cli") == "cli" && surfaceLabel(.pi, source: "cli") == nil)
    assert(modelDelta("gpt-5.5-codex/medium", parent: "gpt-5.5-codex/high") == "/medium")
    assert(modelDelta("gpt-5.5-codex/high", parent: "gpt-5.5-codex/high") == nil)
    assert(modelDelta("haiku-5.5", parent: "opus-5.5") == "haiku-5.5" && modelDelta("", parent: "opus-5.5") == nil)
    assert(agentRowLabel(.opencode) == "oc")
    assert(agentRowLabel(.opencode2) == "oc2")
    assert(agentRowLabel(.codex) == nil && agentRowLabel(.pi) == nil)
    let accountResponse = Data(#"{"rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":null}}"#.utf8)
    assert(parseCodexUsageResponse(accountResponse)?.primary?.windowMinutes == 300)
    assert(parseCodexUsageResponse(accountResponse)?.secondary == nil)
    let claudeResponse = Data(#"{"five_hour":{"utilization":12.5,"resets_at":"2026-10-20T18:00:00.123Z"},"seven_day":{"utilization":43.25,"resets_at":"2026-10-26T18:00:00Z"}}"#.utf8)
    let claudeLimits = parseClaudeUsageResponse(claudeResponse)
    var retainedClaudeLimits = mergedRateLimits(nil, with: claudeLimits)
    retainedClaudeLimits = mergedRateLimits(retainedClaudeLimits,
        with: parseClaudeUsageResponse(Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8)))
    assert(retainedClaudeLimits == claudeLimits,
           "A failed Claude refresh must keep both percentages and reset times")
    let staleClaudeUsage = effectiveUsage(local: nil, remote: retainedClaudeLimits,
        unavailableReason: claudeUsageFailure(statusCode: 429, limits: nil))
    assert(limitCells(staleClaudeUsage, agent: .claude)
        == limitCells(effectiveUsage(local: nil, remote: claudeLimits), agent: .claude))
    assert(limitStatusSymbol(staleClaudeUsage) == "⚠")
    assert(limitStatusSymbol(effectiveUsage(local: nil, remote: claudeLimits)) == nil)
    assert(staleClaudeUsage?.refreshWarning?.contains("last known limits") == true)
    assert(remainingUsageSummary(staleClaudeUsage, agent: .claude).contains("last known limits"))
    let emptyLimits = parseClaudeUsageResponse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
    assert(mergedRateLimits(retainedClaudeLimits, with: emptyLimits) == claudeLimits)
    assert(mergedRateLimits(nil, with: emptyLimits) == nil)
    assert(mergedRateLimits(nil, with: nil) == nil)
    let refreshedFiveHour = parseClaudeUsageResponse(Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-10-21T00:00:00Z"},"seven_day":null}"#.utf8))
    retainedClaudeLimits = mergedRateLimits(retainedClaudeLimits, with: refreshedFiveHour)
    assert(retainedClaudeLimits?.primary == refreshedFiveHour?.primary)
    assert(retainedClaudeLimits?.secondary == claudeLimits?.secondary,
           "A partial response must retain the other window and its reset time")
    let recoveredClaudeLimits = mergedRateLimits(retainedClaudeLimits, with: claudeLimits)
    let recoveredClaudeUsage = effectiveUsage(local: nil, remote: recoveredClaudeLimits,
        unavailableReason: claudeUsageFailure(statusCode: 200, limits: claudeLimits))
    assert(recoveredClaudeUsage?.refreshWarning == nil && recoveredClaudeLimits == claudeLimits)
    assert(claudeLimits?.primary?.usedPercent == 12.5 && claudeLimits?.primary?.windowMinutes == 300)
    assert(claudeLimits?.secondary?.usedPercent == 43.25 && claudeLimits?.secondary?.windowMinutes == 10_080)
    assert(claudeLimits?.primary?.resetsAt != nil && claudeLimits?.secondary?.resetsAt != nil)
    let claudeAccountUsage = effectiveUsage(local: nil, remote: claudeLimits)
    assert(remainingUsageSummary(claudeAccountUsage, agent: .claude).components(separatedBy: "↻").count == 3,
           "Each Claude usage window must show its own reset")
    let claudeWindowLabels = remainingUsageSummary(claudeAccountUsage, agent: .claude).components(separatedBy: " · ")
    let fiveHourMinute = claudeTimestampWithoutFraction.date(from: "2026-10-20T18:00:00Z")!
    let weeklyMinute = claudeTimestampWithoutFraction.date(from: "2026-10-26T18:00:00Z")!
    assert(claudeWindowLabels == ["Claude",
        "5h 87.5% left ↻ \(resetTimeFormatter.string(from: fiveHourMinute))",
        "weekly 56.75% left ↻ \(resetDateFormatter.string(from: weeklyMinute)) \(resetTimeFormatter.string(from: weeklyMinute))"])
    assert(limitCells(claudeAccountUsage, agent: .claude) == [
        LimitCell(label: "5h", windowMinutes: 300, remainingPercent: 87.5, reset: resetTimeFormatter.string(from: fiveHourMinute)),
        LimitCell(label: "7d", windowMinutes: 10_080, remainingPercent: 56.75,
            reset: "\(resetDateFormatter.string(from: weeklyMinute)) \(resetTimeFormatter.string(from: weeklyMinute))"),
    ])
    assert(limitLevel(remainingPercent: 56.75) == .normal)
    assert(limitLevel(remainingPercent: 25) == .low && limitLevel(remainingPercent: 11) == .low)
    assert(limitLevel(remainingPercent: 10) == .critical && limitLevel(remainingPercent: 0) == .critical)
    let weeklyOnly = parseClaudeUsageResponse(Data(#"{"five_hour":null,"seven_day":{"utilization":35}}"#.utf8))
    assert(remainingUsageSummary(effectiveUsage(local: nil, remote: weeklyOnly), agent: .claude)
        == "Claude · 5h unavailable · weekly 65% left")
    assert(remainingUsageSummary(nil, agent: .claude) == "Claude · 5h unavailable · weekly unavailable")
    let unavailableClaudeCells = [
        LimitCell(label: "5h", windowMinutes: 300, remainingPercent: nil, reset: nil),
        LimitCell(label: "7d", windowMinutes: 10_080, remainingPercent: nil, reset: nil),
    ]
    assert(limitCells(nil, agent: .claude) == unavailableClaudeCells)
    let lockedClaudeUsage = UsageSnapshot(totalTokens: 0, contextTokens: 0, contextWindow: 0,
        primaryLimit: nil, secondaryLimit: nil, costTotal: nil, unavailableReason: "Keychain approval needed")
    assert(limitCells(lockedClaudeUsage, agent: .claude) == unavailableClaudeCells)
    assert(limitStatusSymbol(lockedClaudeUsage) == "🔒", "Unavailable Claude usage must identify the Keychain blocker")
    assert(remainingUsageSummary(lockedClaudeUsage, agent: .claude).contains("Keychain approval needed"))
    assert(effectiveUsage(local: nil, remote: nil, unavailableReason: "Keychain approval needed") == lockedClaudeUsage)
    assert(claudeUsageFailure(statusCode: 200, limits: claudeLimits) == nil)
    assert(claudeUsageFailure(statusCode: 200, limits: nil)?.contains("no usable limits") == true)
    assert(claudeUsageFailure(statusCode: 401, limits: nil)?.contains("sign in again") == true)
    assert(claudeUsageFailure(statusCode: 403, limits: nil)?.contains("sign in again") == true)
    assert(claudeUsageFailure(statusCode: 429, limits: nil)?.contains("rate limited") == true)
    assert(claudeUsageFailure(statusCode: 503, limits: nil)?.contains("HTTP 503") == true)
    assert(claudeUsageFailure(statusCode: nil, limits: nil)?.contains("connection") == true)
    let failedClaudeUsage = effectiveUsage(local: nil, remote: nil,
        unavailableReason: claudeUsageFailure(statusCode: 429, limits: nil))
    assert(limitCells(failedClaudeUsage, agent: .claude) == unavailableClaudeCells)
    assert(limitStatusSymbol(failedClaudeUsage) == "⚠")

    assert(limitCells(nil, agent: .codex).isEmpty)
    // pro plans report only a weekly window, in the primary slot.
    let weeklyOnlyCodex = effectiveUsage(local: nil, remote: RemoteRateLimits(
        primary: RateLimitUsage(usedPercent: 57, windowMinutes: 10_080, resetsAt: nil), secondary: nil))
    assert(limitCells(weeklyOnlyCodex, agent: .codex) == [LimitCell(label: "7d", windowMinutes: 10_080, remainingPercent: 43, reset: nil)])
    assert(remainingUsageSummary(weeklyOnlyCodex) == "Codex · weekly 43% left")
    let proLines = [footerLimitLine(weeklyOnlyCodex, agent: .codex), footerLimitLine(claudeAccountUsage, agent: .claude)]
    let proFooter = FooterLayout(limitLines: proLines, columns: footerColumns(for: proLines))
    assert(proFooter.columns.map(\.minutes) == [300, 10_080], "Windows must line up by length, not position")
    assert(proFooter.run(for: proLines[0], column: 0)?.text == "5h no limit")
    assert(abs((proFooter.run(for: proLines[0], column: 0)?.width ?? 0) - proFooter.columns[0].width) < 0.5,
           "A missing window must fill its column instead of leaving a gap")
    assert(proFooter.run(for: proLines[0], column: 1)?.text == "7d 43%")
    assert(proFooter.run(for: proLines[1], column: 0)?.text.hasPrefix("5h 87.5%") == true)
    let unloadedLines = [footerLimitLine(nil, agent: .codex), footerLimitLine(claudeAccountUsage, agent: .claude)]
    let unloadedFooter = FooterLayout(limitLines: unloadedLines, columns: footerColumns(for: unloadedLines))
    assert(unloadedFooter.run(for: unloadedLines[0], column: 0)?.text == "—")
    assert(unloadedFooter.run(for: unloadedLines[0], column: 1) == nil)
    assert(parseClaudeUsageResponse(Data(#"{"error":"unauthorized"}"#.utf8)) == nil)
    assert(parseClaudeUsageResponse(Data("broken json".utf8)) == nil)
    let invalidWindows = parseClaudeUsageResponse(Data(#"{"five_hour":{"utilization":true},"seven_day":{"utilization":"35"}}"#.utf8))
    assert(invalidWindows?.primary == nil && invalidWindows?.secondary == nil)
    assert(parseClaudeUsageResponse(Data(#"{"five_hour":{"utilization":-1},"seven_day":{"utilization":40}}"#.utf8))?.primary == nil)
    assert(parseClaudeAccessToken(Data(#"{"claudeAiOauth":{"accessToken":"test-token"}}"#.utf8)) == "test-token")
    assert(parseClaudeAccessToken(Data(#"{"claudeAiOauth":{"accessToken":" "}}"#.utf8)) == nil)
    assert(parseClaudeAccessToken(Data(#"{"mcpOAuth":{"accessToken":"test-token"}}"#.utf8)) == nil)
    let nativeRateLimits = RemoteRateLimits(
        primary: RateLimitUsage(usedPercent: 10, windowMinutes: 60, resetsAt: nil),
        secondary: RateLimitUsage(usedPercent: 20, windowMinutes: 120, resetsAt: nil)
    )
    let remoteRateLimits = RemoteRateLimits(
        primary: RateLimitUsage(usedPercent: 30, windowMinutes: 300, resetsAt: nil),
        secondary: RateLimitUsage(usedPercent: 40, windowMinutes: 10080, resetsAt: nil)
    )
    let nativeUsage = UsageSnapshot(
        totalTokens: 1_000,
        contextTokens: 800,
        contextWindow: 4_000,
        primaryLimit: nativeRateLimits.primary,
        secondaryLimit: nativeRateLimits.secondary,
        costTotal: 0.25
    )
    let laterNativeUsage = UsageSnapshot(
        totalTokens: 2_000,
        contextTokens: 1_600,
        contextWindow: 4_000,
        primaryLimit: RateLimitUsage(usedPercent: 11, windowMinutes: 60, resetsAt: nil),
        secondaryLimit: RateLimitUsage(usedPercent: 21, windowMinutes: 120, resetsAt: nil),
        costTotal: 0.5
    )
    assert(effectiveUsage(local: nil, remote: nil) == nil)
    assert(effectiveUsage(local: nativeUsage, remote: nil) == nativeUsage)
    let remoteOnlyUsage = effectiveUsage(local: nil, remote: remoteRateLimits)
    assert(remoteOnlyUsage == UsageSnapshot(
        totalTokens: 0,
        contextTokens: 0,
        contextWindow: 0,
        primaryLimit: remoteRateLimits.primary,
        secondaryLimit: remoteRateLimits.secondary,
        costTotal: nil
    ))
    assert(remainingUsageSummary(remoteOnlyUsage).hasPrefix("Codex"), "Account limits must identify Codex separately from Claude")
    assert(!remainingUsageSummary(remoteOnlyUsage).contains("usage unavailable"))
    assert(remainingUsageSummary(remoteOnlyUsage).contains("5h 70% left"))
    assert(remainingUsageSummary(remoteOnlyUsage).contains("weekly 60% left"))
    let mergedUsage = effectiveUsage(local: nativeUsage, remote: remoteRateLimits)
    assert(mergedUsage?.primaryLimit == remoteRateLimits.primary)
    assert(mergedUsage?.secondaryLimit == remoteRateLimits.secondary)
    assert(mergedUsage?.totalTokens == nativeUsage.totalTokens)
    assert(mergedUsage?.contextTokens == nativeUsage.contextTokens)
    assert(mergedUsage?.contextWindow == nativeUsage.contextWindow)
    assert(mergedUsage?.costTotal == nativeUsage.costTotal)
    let updatedMergedUsage = effectiveUsage(local: laterNativeUsage, remote: remoteRateLimits)
    assert(updatedMergedUsage?.totalTokens == laterNativeUsage.totalTokens)
    assert(updatedMergedUsage?.contextTokens == laterNativeUsage.contextTokens)
    assert(updatedMergedUsage?.primaryLimit == remoteRateLimits.primary)
    assert(updatedMergedUsage?.secondaryLimit == remoteRateLimits.secondary)
    assert(usageSummary(parseUsage(usage)) == "ctx 20% · 120k tok")
    assert(remainingUsageSummary(parseUsage(usage)).contains("5h 87.66% left"))
    assert(remainingUsageSummary(parseUsage(usage)).contains("↻"))
    assert(relativeAge(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 3600)) == "1h")
    assert(parseResponse(unrelated) == nil)
    let codexEscalation = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_escalate","arguments":"{\"cmd\":\"rm -rf /tmp/x\",\"sandbox_permissions\":\"require_escalated\"}"}}"#.utf8)
    let codexQuestion = Data(#"{"type":"response_item","payload":{"type":"request_user_input","call_id":"call_question","questions":[{"question":"Deploy now?"}]}}"#.utf8)
    let codexFunctionQuestion = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_function_question","arguments":"{\"questions\":[{\"question\":\"Use the new config?\"}]}"}}"#.utf8)
    let codexResult = Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_escalate","output":"ok"}}"#.utf8)
    assert(parseCodexPendingPrompt(codexEscalation)?.kind == .permission)
    assert(parseCodexPendingPrompt(codexEscalation)?.text == "rm -rf /tmp/x")
    assert(parseCodexPendingPrompt(codexQuestion)?.kind == .question)
    assert(parseCodexPendingPrompt(codexQuestion)?.text == "Deploy now?")
    assert(parseCodexPendingPrompt(codexFunctionQuestion)?.kind == .question)
    assert(parseCodexPendingPrompt(codexFunctionQuestion)?.text == "Use the new config?")
    assert(parseCodexResolvedCallID(codexResult) == "call_escalate")
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
    let piAskEntry = Data(#"{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-15T19:10:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_pi_ask1","name":"ask_user_question","arguments":{"question":"Deploy to production?"}}],"provider":"zai","model":"glm-5.3","stopReason":"toolUse","timestamp":1786821000000}}"#.utf8)
    let piAskResultEntry = Data(#"{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-15T19:10:05.000Z","message":{"role":"toolResult","toolCallId":"call_pi_ask1","toolName":"ask_user_question","isError":false,"timestamp":1786821005000}}"#.utf8)
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
    assert(parsePiToolCalls(piAskEntry)?.first?.name == "ask_user_question")
    assert(parsePiToolCalls(piAskEntry)?.first?.text == "Deploy to production?")
    let piPermissionEntry = Data(#"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_pi_permission","name":"request_permission","arguments":{"path":"/tmp/x"}}]}}"#.utf8)
    assert(parsePiToolCalls(piPermissionEntry)?.first?.permission == true)
    assert(parsePiToolCalls(piAskResultEntry) == nil)
    assert(parsePiToolResultID(piAskResultEntry) == "call_pi_ask1")
    assert(parsePiToolResultID(piAskEntry) == nil)
    let ocUserHeader = parseOpencodeMessageHeader(Data(#"{"role":"user","time":{"created":1786825803000}}"#.utf8))
    let ocStreamingHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","modelID":"glm-5.3","providerID":"zai-coding-plan","variant":"high","agent":"build","time":{"created":1786825803000}}"#.utf8))
    let ocDoneHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":1786825803000,"completed":1786825806000},"finish":"stop","tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":300,"write":10}},"cost":0.01}"#.utf8))
    let ocAbortHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","time":{"created":1786825803000,"completed":1786825806000},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}"#.utf8))
    let ocAbortingHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","time":{"created":1786825803000,"completed":null},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}"#.utf8))
    let ocNullCompletionHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","time":{"created":1786825803000,"completed":null},"finish":"stop"}"#.utf8))
    let ocToolCallHeader = parseOpencodeMessageHeader(Data(#"{"role":"assistant","time":{"created":1786825803000,"completed":1786825806000},"finish":"tool-calls"}"#.utf8))
    let ocV2Message = parseOpencodeV2Message(
        id: "v2",
        role: "assistant",
        data: Data(#"{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"reasoning","text":"skip"},{"type":"tool","state":{"status":"completed"}},{"type":"text","text":"v2 reply"}],"time":{"created":1,"completed":2},"finish":"stop","tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":1,"write":1}}}"#.utf8)
    )
    let ocV2UserMessage = parseOpencodeV2Message(id: "v2u", role: "user", data: Data(#"{"text":"v2 prompt","time":{"created":1}}"#.utf8))
    assert(ocUserHeader?.role == "user")
    assert(ocStreamingHeader?.completed == false)
    assert(ocDoneHeader?.contextTokens == 460)
    assert(ocAbortHeader?.stopped == true)
    assert(ocNullCompletionHeader?.completed == false)
    assert(opencodeTurnEvent(ocUserHeader) == .started)
    assert(opencodeTurnEvent(ocStreamingHeader) == .started)
    assert(opencodeTurnEvent(ocDoneHeader) == .completed)
    assert(opencodeTurnEvent(ocAbortHeader) == .cancelled)
    assert(opencodeTurnEvent(ocAbortingHeader) == .cancelled)
    assert(opencodeTurnEvent(ocNullCompletionHeader) == .started)
    assert(opencodeTurnEvent(ocToolCallHeader) == .started)
    assert(opencodeTurnEvent(nil) == nil)
    assert(ocV2Message?.header.modelID == "glm-5.3")
    assert(ocV2Message?.header.variant == "high")
    assert(ocV2Message?.header.contextTokens == 17)
    assert(opencodeTurnEvent(ocV2Message?.header) == .completed)
    assert(ocV2Message?.text == "v2 reply")
    assert(ocV2UserMessage?.text == "v2 prompt")
    assert(opencodeTurnEvent(ocV2UserMessage?.header) == .started)
    let ocProviderFailure = Data(#"{"role":"assistant","time":{"created":1,"completed":2},"finish":"error","error":{"type":"provider.free-limit","message":"Free usage limit reached.","status":429}}"#.utf8)
    assert(opencodeTurnEvent(parseOpencodeMessageHeader(ocProviderFailure)) == .cancelled)
    assert(opencodeTurnEvent(parseOpencodeV2Message(id: "v2error", role: "assistant", data: ocProviderFailure)?.header) == .cancelled)
    for (json, expected) in [
        (#"{"time":{"created":2},"outcome":"failed","error":{"type":"provider.free-limit","status":429}}"#, TurnEvent.cancelled),
        (#"{"time":{"created":2},"outcome":"failed"}"#, .cancelled),
        (#"{"time":{"created":2},"outcome":"interrupted"}"#, .cancelled),
        (#"{"time":{"created":2},"outcome":"succeeded"}"#, .completed)
    ] {
        let message = parseOpencodeV2Message(id: "v2idle", role: "idle", data: Data(json.utf8))
        assert(opencodeTurnEvent(message?.header) == expected, "v2 idle outcomes must end the turn")
    }
    assert(opencodeModelLabel(modelID: "glm-5.3", variant: "high") == "glm-5.3/high")
    assert(opencodeModelLabel(modelID: "glm-5.3", variant: nil) == "glm-5.3")
    assert(opencodeSessionModel(#"{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}"#) == "glm-5.3/high")
    assert(isAskToolName("ask_user_question") && isAskToolName("Ask") && isAskToolName("question"))
    assert(!isAskToolName("bash") && !isAskToolName("task"))
    let questionObservation = OpencodeToolObservation(
        callID: "q1",
        name: "question",
        status: "running",
        input: ["questions": [["question": "Ship it?"]]],
        progressed: false,
        createdAt: Date()
    )
    assert(opencodePrompt(from: [questionObservation], askingEvents: [])?.kind == .question)
    assert(opencodePrompt(from: [questionObservation], askingEvents: [])?.text == "Ship it?")
    let freshBash = OpencodeToolObservation(
        callID: "b1", name: "bash", status: "running", input: ["command": "ls"],
        progressed: false, createdAt: Date()
    )
    assert(opencodePrompt(from: [freshBash], askingEvents: []) == nil)
    let stalledBash = OpencodeToolObservation(
        callID: "b2", name: "bash", status: "running", input: ["command": "ls"],
        progressed: false, createdAt: Date().addingTimeInterval(-opencodePromptDebounce - 1)
    )
    // a stalled tool alone is just a silent command: the run log must confirm an ask
    assert(opencodePrompt(from: [stalledBash], askingEvents: []) == nil)
    let matchedAsk = OpencodeAskingEvent(id: "per_1", permission: "bash", at: stalledBash.createdAt.addingTimeInterval(1))
    let staleAsk = OpencodeAskingEvent(id: "per_2", permission: "bash", at: stalledBash.createdAt.addingTimeInterval(-60))
    assert(opencodePrompt(from: [stalledBash], askingEvents: [matchedAsk])?.kind == .permission)
    assert(opencodePrompt(from: [stalledBash], askingEvents: [staleAsk]) == nil)
    assert(opencodePrompt(from: [stalledBash], askingEvents: [matchedAsk])?.line == "bash: ls")
    let pendingRead = OpencodeToolObservation(
        callID: "b-pending", name: "read", status: "pending", input: ["filePath": "/tmp/file"],
        progressed: false, createdAt: stalledBash.createdAt
    )
    let externalDirectoryAsk = OpencodeAskingEvent(
        id: "per-external", permission: "external_directory", at: pendingRead.createdAt.addingTimeInterval(1)
    )
    assert(opencodePrompt(from: [pendingRead], askingEvents: [externalDirectoryAsk])?.kind == .permission)
    let progressingBash = OpencodeToolObservation(
        callID: "b3", name: "bash", status: "running", input: ["command": "ls"],
        progressed: true, createdAt: Date().addingTimeInterval(-opencodePromptDebounce - 1)
    )
    assert(opencodePrompt(from: [progressingBash], askingEvents: [matchedAsk]) == nil)
    let completedBash = OpencodeToolObservation(
        callID: "b4", name: "bash", status: "completed", input: [:],
        progressed: true, createdAt: Date().addingTimeInterval(-opencodePromptDebounce - 1)
    )
    assert(opencodePrompt(from: [completedBash], askingEvents: [matchedAsk]) == nil)
    let taskObservation = OpencodeToolObservation(
        callID: "t1", name: "task", status: "running", input: [:],
        progressed: false, createdAt: Date().addingTimeInterval(-opencodePromptDebounce - 1)
    )
    assert(opencodePrompt(from: [taskObservation], askingEvents: [matchedAsk]) == nil)
    let askLogLine = "timestamp=2026-08-16T06:03:32.310Z level=INFO run=49983bf6 message=asking id=per_0092b10560019BBvJr2ITQriAG permission=external_directory patterns=\"[\\\"/Users/parag/codebase/projects/caregiving/*\\\"]\""
    assert(parseOpencodeAskingLine(askLogLine)?.id == "per_0092b10560019BBvJr2ITQriAG")
    assert(parseOpencodeAskingLine(askLogLine)?.permission == "external_directory")
    assert(parseOpencodeAskingLine(askLogLine)?.at == Date(timeIntervalSince1970: 1786860212.31))
    assert(parseOpencodeAskingLine("timestamp=2026-08-16T06:05:13.279Z level=INFO run=49983bf6 message=evaluated permission=bash action.action=allow") == nil)
    assert(parseOpencodeAskingLine("timestamp=2026-08-16T06:03:32.310Z level=INFO run=49983bf6 message=asking id=que_0092b10560019BBvJr2ITQriAG questions=2") == nil)
    assert(parseOpencodePending(id: "pending-1", type: "external_directory", data: #"{"path":"/tmp"}"#)?.kind == .permission)
    assert(parseOpencodePending(id: "pending-2", type: "question", data: #"{"questions":[{"question":"Continue?"}]}"#)?.kind == .question)
    assert(parseOpencodePending(id: "pending-3", type: "pending", data: #"{"request":{"type":"permission","action":"allow","resources":["/tmp"]}}"#)?.kind == .permission)
    assert(parseOpencodePending(id: "pending-4", type: "pending", data: #"{"type":"compaction_barrier"}"#) == nil)
    assert(parseOpencodePending(id: "pending-5", type: "pending", data: #"{"input":"ordinary user input"}"#) == nil)
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
    try! Data("\(childMeta)\n\(String(decoding: started, as: UTF8.self))\n\(String(decoding: currentCodexPrompt, as: UTF8.self))\n".utf8).write(to: childSession)
    try! Data(#"{"id":"self-test","thread_name":"Saved Codex name"}"#.utf8)
        .write(to: root.appendingPathComponent("session_index.jsonl"))
    setenv("CODEX_HOME", root.path, 1)
    // isolate opencode from the machine's real ~/.local/share/opencode during monitor tests
    let emptyDataHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-status-xdg-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: emptyDataHome, withIntermediateDirectories: true)
    setenv("XDG_DATA_HOME", emptyDataHome.path, 1)
    setenv("CLAUDE_CONFIG_DIR", emptyDataHome.appendingPathComponent("claude").path, 1)

    let monitor = SessionMonitor()
    var latest: [ThreadActivity] = []
    var completions: [ThreadActivity] = []
    var askings: [ThreadActivity] = []
    monitor.onChange = { activities, _, _ in latest = activities }
    monitor.onCompletion = { completions.append($0) }
    monitor.onAsking = { askings.append($0) }
    monitor.start()
    assert(waitUntil {
        latest.contains { $0.id == "self-test" && $0.phase == .running }
            && latest.contains { $0.id == "child" && $0.phase == .running }
    })
    let parent = latest.first { $0.id == "self-test" }
    let child = latest.first { $0.id == "child" }
    assert(parent?.title == "Saved Codex name", "Codex names must be found by thread ID and shown before prompt fallbacks")
    assert(child?.title == "Restore the thread names")
    assert(parent?.model == "gpt-5.6-sol/high")
    assert(parent?.usage?.totalTokens == 120_000)
    assert(child?.parentID == "self-test" && child?.nickname == "guardian")
    assert(groupActivities(latest).first(where: { $0.root.id == "self-test" })?.children.map(\.id) == ["child"])
    assert(completions.isEmpty)

    let handle = try! FileHandle(forWritingTo: session)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: completed + Data("\n".utf8))
    try! handle.close()
    assert(waitUntil(timeout: 3) { latest.first(where: { $0.id == "self-test" })?.phase == .ready })
    assert(completions.isEmpty, "Completion must wait for the subagents")
    assert(groupActivities(latest).first { $0.root.id == "self-test" }?.phase == .delegating,
           "A parent must stay active while a subagent is running")
    let childHandle = try! FileHandle(forWritingTo: childSession)
    try! childHandle.seekToEnd()
    try! childHandle.write(contentsOf: currentCodexResponse + Data("\n".utf8) + completed + Data("\n".utf8))
    try! childHandle.close()
    assert(waitUntil(timeout: 3) { latest.first(where: { $0.id == "child" })?.phase == .ready })
    assert(latest.first(where: { $0.id == "child" })?.detail == "Names restored.")
    assert(waitUntil { completions.count == 1 } && completions.first?.id == "self-test")
    monitor.acknowledge(codexSources: ["extension"], piSources: [], opencodeSources: [])
    assert(waitUntil { latest.first(where: { $0.id == "self-test" })?.phase == .seen })
    let phaseBeforeTitleUpdates = latest.first { $0.id == "self-test" }?.phase

    // The VS Code extension resumes threads whose rollouts live in old date
    // directories; the state_N.sqlite threads index must surface them.
    let oldDay = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
    try! FileManager.default.createDirectory(at: oldDay, withIntermediateDirectories: true)
    let oldSession = oldDay.appendingPathComponent("rollout-old.jsonl")
    let oldMeta = #"{"type":"session_meta","payload":{"id":"self-test-old","source":"vscode","originator":"codex_vscode","cwd":"/tmp/workspace"}}"#
    try! Data("\(oldMeta)\n\(String(decoding: started, as: UTF8.self))\n".utf8).write(to: oldSession)
    var indexDB: OpaquePointer?
    assert(sqlite3_open_v2(root.appendingPathComponent("state_1.sqlite").path, &indexDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    guard let indexDB else { fatalError("sqlite open failed") }
    assert(sqlite3_exec(indexDB, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL, archived INTEGER NOT NULL, title TEXT)", nil, nil, nil) == SQLITE_OK)
    assert(sqlite3_exec(indexDB, "INSERT INTO threads VALUES ('self-test-old', '\(oldSession.path)', \(Int(Date().timeIntervalSince1970)), 0, 'Database generated title')", nil, nil, nil) == SQLITE_OK)
    assert(waitUntil(timeout: 3) {
        latest.contains { $0.id == "self-test-old" && $0.phase == .running && $0.source == "extension" }
    })
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "self-test-old" }?.title == "Database generated title" },
           "Codex titles stored in the state database must precede prompt fallbacks")
    let titleDate = latest.first { $0.id == "self-test-old" }?.updatedAt
    assert(sqlite3_exec(indexDB, "ALTER TABLE threads ADD COLUMN name TEXT; UPDATE threads SET name = 'Database manual name' WHERE id = 'self-test-old'", nil, nil, nil) == SQLITE_OK)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "self-test-old" }?.title == "Database manual name" },
           "Saved Codex names must refresh without another turn event")
    assert(latest.first { $0.id == "self-test-old" }?.updatedAt == titleDate)
    assert(sqlite3_exec(indexDB, "INSERT INTO threads VALUES ('self-test', '\(session.path)', \(Int(Date().timeIntervalSince1970)), 0, 'Database automatic title', 'Current database name')", nil, nil, nil) == SQLITE_OK)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "self-test" }?.title == "Current database name" },
           "The current database name must override a stale session-index name")
    assert(latest.first { $0.id == "self-test" }?.phase == phaseBeforeTitleUpdates,
           "Title refresh changed phase from \(String(describing: phaseBeforeTitleUpdates)) to \(String(describing: latest.first { $0.id == "self-test" }?.phase))")
    assert(sqlite3_exec(indexDB, "UPDATE threads SET name = '  ' WHERE id = 'self-test-old'", nil, nil, nil) == SQLITE_OK)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "self-test-old" }?.title == "Database generated title" })
    try! FileManager.default.removeItem(at: root.appendingPathComponent("session_index.jsonl"))
    assert(sqlite3_exec(indexDB, "UPDATE threads SET name = 'Database-only saved name' WHERE id = 'self-test-old'", nil, nil, nil) == SQLITE_OK)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "self-test-old" }?.title == "Database-only saved name" },
           "Codex database names must work when session_index.jsonl is missing")
    sqlite3_close(indexDB)

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
    piMonitor.onChange = { activities, _, _ in latest = activities }
    piMonitor.onCompletion = { completions.append($0) }
    piMonitor.onAsking = { askings.append($0) }
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
    piMonitor.acknowledge(codexSources: ["cli"], piSources: ["cli"], opencodeSources: [])
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.phase == .seen })

    let secondTurn = try! FileHandle(forWritingTo: piSession)
    try! secondTurn.seekToEnd()
    try! secondTurn.write(contentsOf: piUserEntry + Data("\n".utf8))
    try! secondTurn.write(contentsOf: piAbortedEntry + Data("\n".utf8))
    try! secondTurn.close()
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.phase == .stopped })

    // ask flow: an ask-type tool parks the turn on the user until it is answered
    let askTurn = try! FileHandle(forWritingTo: piSession)
    try! askTurn.seekToEnd()
    try! askTurn.write(contentsOf: piUserEntry + Data("\n".utf8))
    try! askTurn.write(contentsOf: piAskEntry + Data("\n".utf8))
    try! askTurn.close()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "pi-test" }.map {
            $0.phase == .running && $0.prompt?.kind == .question && $0.prompt?.text == "Deploy to production?"
        } ?? false
    })
    assert(askings.filter { $0.id == "pi-test" && $0.agent == .pi }.count == 1)
    assert(groupActivities(latest).first { $0.root.id == "pi-test" }?.asking == true)
    let answerTurn = try! FileHandle(forWritingTo: piSession)
    try! answerTurn.seekToEnd()
    try! answerTurn.write(contentsOf: piAskResultEntry + Data("\n".utf8))
    try! answerTurn.close()
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.prompt == nil })
    let cancelledAskTurn = try! FileHandle(forWritingTo: piSession)
    try! cancelledAskTurn.seekToEnd()
    try! cancelledAskTurn.write(contentsOf: piUserEntry + Data("\n".utf8))
    try! cancelledAskTurn.write(contentsOf: piAskEntry + Data("\n".utf8))
    try! cancelledAskTurn.write(contentsOf: piAbortedEntry + Data("\n".utf8))
    try! cancelledAskTurn.close()
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "pi-test" }?.prompt == nil })
    piMonitor.stop()
    try? FileManager.default.removeItem(at: piRoot)

    // opencode monitor: sqlite lifecycle, titles, model/usage labels, aborts, subagent grouping.
    // one database holds both the legacy (v1) tables and the v2 tables the opencode2 binary writes.
    let ocRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-status-oc-\(UUID().uuidString)", isDirectory: true)
    let ocData = ocRoot.appendingPathComponent("opencode", isDirectory: true)
    try! FileManager.default.createDirectory(at: ocData, withIntermediateDirectories: true)
    let ocDB = ocData.appendingPathComponent("opencode.db")

    func opencodeExecute(_ sql: String, at databaseURL: URL = ocDB) {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            assertionFailure()
            return
        }
        // the monitor reads on every change event; without wal its shared lock can briefly block writers.
        sqlite3_busy_timeout(database, 2000)
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            assertionFailure()
            return
        }
    }

    opencodeExecute("CREATE TABLE session (id text PRIMARY KEY, parent_id text, title text NOT NULL, directory text NOT NULL, agent text, model text, cost real DEFAULT 0 NOT NULL, tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL, tokens_reasoning integer DEFAULT 0 NOT NULL, tokens_cache_read integer DEFAULT 0 NOT NULL, tokens_cache_write integer DEFAULT 0 NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer); CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL); CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);")
    opencodeExecute("CREATE TABLE session_v2 (id text PRIMARY KEY, parent_id text, title text, directory text NOT NULL, agent text, model text, cost real DEFAULT 0 NOT NULL, tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL, tokens_reasoning integer DEFAULT 0 NOT NULL, tokens_cache_read integer DEFAULT 0 NOT NULL, tokens_cache_write integer DEFAULT 0 NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer); CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);")
    setenv("XDG_DATA_HOME", ocRoot.path, 1)

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    opencodeExecute("""
    INSERT INTO session (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-1', NULL, 'Ship the widget', '/tmp/workspace', 'build', '{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}', 0.0123, 1000, 200, 50, 3000, 0, \(nowMs - 8000), \(nowMs - 1000), NULL);
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m1', 'ses_oc-1', \(nowMs - 8000), \(nowMs - 8000), '{"role":"user","time":{"created":\(nowMs - 8000)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p1', 'm1', 'ses_oc-1', \(nowMs - 8000), \(nowMs - 8000), '{"type":"text","text":"add opencode support please"}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m2', 'ses_oc-1', \(nowMs - 1000), \(nowMs - 1000), '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs - 1000)}}');
    INSERT INTO session_v2 (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_v2-1', NULL, 'Port to v2', '/tmp/workspace', 'build', '{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}', 0.02, 10, 20, 0, 0, 0, \(nowMs - 8000), \(nowMs - 1000), NULL);
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m1', 'ses_v2-1', 'user', 1, \(nowMs - 8000), \(nowMs - 8000), '{"text":"add v2 support please","time":{"created":\(nowMs - 8000)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m2', 'ses_v2-1', 'assistant', 2, \(nowMs - 1000), \(nowMs - 1000), '{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"reasoning","text":"thinking"},{"type":"text","text":""}],"time":{"created":\(nowMs - 1000)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2x1', 'ses_v2-1', 'model-switched', 3, \(nowMs - 900), \(nowMs - 900), '{"model":{"id":"ignored"}}');
    """)

    let ocMonitor = SessionMonitor()
    ocMonitor.onChange = { activities, _, _ in latest = activities }
    ocMonitor.onCompletion = { completions.append($0) }
    ocMonitor.onAsking = { askings.append($0) }
    ocMonitor.start()
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-1" }.map { $0.agent == .opencode && $0.phase == .running } ?? false
            && latest.first { $0.id == "ses_v2-1" }.map { $0.agent == .opencode2 && $0.phase == .running } ?? false
    })
    let ocActivity = latest.first { $0.id == "ses_oc-1" }
    assert(ocActivity?.title == "Ship the widget")
    assert(ocActivity?.model == "glm-5.3/high")
    assert(ocActivity?.project == "workspace")
    assert(ocActivity?.source == "cli")
    assert(ocActivity?.detail == "")
    let oc2Activity = latest.first { $0.id == "ses_v2-1" }
    assert(oc2Activity?.title == "Port to v2")
    assert(oc2Activity?.model == "glm-5.3/high")
    assert(oc2Activity?.detail == "")

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

    opencodeExecute("""
    UPDATE session_message SET data = '{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"reasoning","text":"thinking"},{"type":"tool","state":{"status":"completed"}},{"type":"text","text":"Done. v2 shipped."}],"time":{"created":\(nowMs - 1000),"completed":\(nowMs + 2000)},"finish":"stop","tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":300,"write":10}},"cost":0.01}', time_updated = \(nowMs + 2000) WHERE id = 'v2m2';
    UPDATE session_v2 SET time_updated = \(nowMs + 2000) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_v2-1" }.map { $0.phase == .ready && $0.detail == "Done. v2 shipped." } ?? false
            && completions.contains { $0.id == "ses_v2-1" && $0.agent == .opencode2 }
    })
    let oc2Finished = latest.first { $0.id == "ses_v2-1" }
    assert(oc2Finished?.usage?.totalTokens == 30)
    assert(oc2Finished?.usage?.contextTokens == 460)
    assert(oc2Finished?.usage?.costTotal == 0.02)
    ocMonitor.acknowledge(codexSources: [], piSources: [], opencodeSources: ["cli"])
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_oc-1" }?.phase == .seen })
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .seen })

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
    assert(groupActivities(latest).first { $0.root.id == "ses_oc-1" }?.phase == .delegating)

    // v1 ask flow: a bash tool parks on a permission dialog, then clears on approval
    let ocLogDir = ocData.appendingPathComponent("log", isDirectory: true)
    try! FileManager.default.createDirectory(at: ocLogDir, withIntermediateDirectories: true)
    let askStamp = ISO8601DateFormatter()
    askStamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ocAskLogLine = "timestamp=\(askStamp.string(from: Date(timeIntervalSince1970: Double(nowMs - 12000) / 1000))) level=INFO run=selftest message=asking id=per_test0001 permission=bash patterns=\"[\\\"rm -rf /tmp/precious\\\"]\"\n"
    let ocLogFile = ocLogDir.appendingPathComponent("opencode.log")
    if !FileManager.default.fileExists(atPath: ocLogFile.path) {
        try! Data().write(to: ocLogFile)
    }
    let ocLogHandle = try! FileHandle(forWritingTo: ocLogFile)
    try! ocLogHandle.seekToEnd()
    try! ocLogHandle.write(contentsOf: Data(ocAskLogLine.utf8))
    try! ocLogHandle.close()
    opencodeExecute("""
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m8', 'ses_oc-1', \(nowMs + 7000), \(nowMs + 7000), '{"role":"user","time":{"created":\(nowMs + 7000)}}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m9', 'ses_oc-1', \(nowMs + 7200), \(nowMs + 7200), '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs + 7200)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p_ask', 'm9', 'ses_oc-1', \(nowMs - 12000), \(nowMs - 12000), '{"type":"tool","tool":"bash","callID":"call_oc_ask1","state":{"status":"running","input":{"command":"rm -rf /tmp/precious"},"time":{"start":\(nowMs - 12000)}}}');
    UPDATE session SET time_updated = \(nowMs + 7200) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 4) {
        latest.first { $0.id == "ses_oc-1" }.map { $0.phase == .running && $0.prompt?.kind == .permission } ?? false
    })
    assert(latest.first { $0.id == "ses_oc-1" }?.prompt?.line == "bash: rm -rf /tmp/precious")
    assert(askings.filter { $0.id == "ses_oc-1" && $0.prompt?.callID == "call_oc_ask1" }.count == 1)
    assert(groupActivities(latest).first { $0.root.id == "ses_oc-1" }?.asking == true)
    opencodeExecute("""
    UPDATE part SET data = '{"type":"tool","tool":"bash","callID":"call_oc_ask1","state":{"status":"completed","input":{"command":"rm -rf /tmp/precious"},"output":"done","metadata":{"output":"done"},"title":"bash","time":{"start":\(nowMs - 12000),"end":\(nowMs + 7300)}}}', time_updated = \(nowMs + 7300) WHERE id = 'p_ask';
    UPDATE message SET data = '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs + 7200),"completed":\(nowMs + 7400)},"finish":"stop"}', time_updated = \(nowMs + 7400) WHERE id = 'm9';
    UPDATE session SET time_updated = \(nowMs + 7400) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 4) {
        let oc1 = latest.first { $0.id == "ses_oc-1" }
        return oc1?.prompt == nil && oc1?.phase == .ready
    })

    // v2 second turn: a tool-call segment must keep the turn running instead of flashing ready
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m3', 'ses_v2-1', 'user', 4, \(nowMs + 8000), \(nowMs + 8000), '{"text":"go again","time":{"created":\(nowMs + 8000)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m4', 'ses_v2-1', 'assistant', 5, \(nowMs + 8100), \(nowMs + 8100), '{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"tool","state":{"status":"completed"}}],"time":{"created":\(nowMs + 8100),"completed":\(nowMs + 8200)},"finish":"tool-calls"}');
    UPDATE session_v2 SET time_updated = \(nowMs + 8200) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .running })
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m5', 'ses_v2-1', 'assistant', 6, \(nowMs + 8300), \(nowMs + 8300), '{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"text","text":"All done."}],"time":{"created":\(nowMs + 8300),"completed":\(nowMs + 8400)},"finish":"stop"}');
    UPDATE session_v2 SET time_updated = \(nowMs + 8400) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .ready })

    // v2 subagent: null title falls back to its prompt text
    opencodeExecute("""
    INSERT INTO session_v2 (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_v2-2', 'ses_v2-1', NULL, '/tmp/workspace', 'explore', NULL, 0, 100, 20, 0, 0, 0, \(nowMs + 8500), \(nowMs + 8700), NULL);
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m6', 'ses_v2-2', 'user', 1, \(nowMs + 8600), \(nowMs + 8600), '{"text":"explore the repo","time":{"created":\(nowMs + 8600)}}');
    UPDATE session_v2 SET time_updated = \(nowMs + 8800) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_v2-2" }.map { $0.agent == .opencode2 && $0.phase == .running && $0.parentID == "ses_v2-1" } ?? false
    })
    assert(latest.first { $0.id == "ses_v2-2" }?.nickname == "explore")
    assert(latest.first { $0.id == "ses_v2-2" }?.title == "explore the repo")
    assert(
        groupActivities(latest).first { $0.root.id == "ses_v2-1" }?.children.map(\.id) == ["ses_v2-2"]
    )

    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m7', 'ses_v2-1', 'assistant', 7, \(nowMs + 8900), \(nowMs + 8900), '{"model":{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"},"content":[{"type":"text","text":"stopping"}],"time":{"created":\(nowMs + 8900),"completed":\(nowMs + 9000)},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}');
    UPDATE session_v2 SET time_updated = \(nowMs + 9000) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .stopped })

    // v2 ask flow: the question tool parks the turn on the user, then clears on answer
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m8', 'ses_v2-1', 'user', 8, \(nowMs + 9200), \(nowMs + 9200), '{"text":"one more thing","time":{"created":\(nowMs + 9200)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m9', 'ses_v2-1', 'assistant', 9, \(nowMs + 9300), \(nowMs + 9300), '{"model":{"id":"glm-5.3"},"content":[{"type":"tool","id":"call_v2_ask1","name":"question","time":{"created":\(nowMs - 8000),"ran":\(nowMs - 8000)},"state":{"status":"running","input":{"questions":[{"question":"Ship to prod?"}]}}}],"time":{"created":\(nowMs + 9300)}}');
    UPDATE session_v2 SET time_updated = \(nowMs + 9300) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 4) {
        latest.first { $0.id == "ses_v2-1" }.map {
            $0.phase == .running && $0.prompt?.kind == .question && $0.prompt?.text == "Ship to prod?"
        } ?? false
    })
    assert(askings.filter { $0.id == "ses_v2-1" && $0.prompt?.callID == "call_v2_ask1" }.count == 1)
    opencodeExecute("""
    UPDATE session_message SET data = '{"model":{"id":"glm-5.3"},"content":[{"type":"tool","id":"call_v2_ask1","name":"question","time":{"created":\(nowMs - 8000),"ran":\(nowMs - 8000),"completed":\(nowMs + 9400)},"state":{"status":"completed","input":{"questions":[{"question":"Ship to prod?"}]},"content":[{"type":"text","text":"yes"}],"output":"User has answered your questions."}}],"time":{"created":\(nowMs + 9300),"completed":\(nowMs + 9400)},"finish":"stop"}', time_updated = \(nowMs + 9400) WHERE id = 'v2m9';
    UPDATE session_v2 SET time_updated = \(nowMs + 9400) WHERE id = 'ses_v2-1';
    """)
    assert(waitUntil(timeout: 4) {
        let v2 = latest.first { $0.id == "ses_v2-1" }
        return v2?.prompt == nil && v2?.phase == .ready
    })

    // v2 can update messages without advancing session_v2.time_updated.
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m10', 'ses_v2-1', 'user', 10, \(nowMs + 10000), \(nowMs + 10000), '{"text":"stale session row","time":{"created":\(nowMs + 10000)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2m11', 'ses_v2-1', 'assistant', 11, \(nowMs + 10100), \(nowMs + 10100), '{"model":{"id":"glm-5.3"},"content":[{"type":"text","text":"working"}],"time":{"created":\(nowMs + 10100)}}');
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .running })
    opencodeExecute("""
    UPDATE session_message SET data = '{"model":{"id":"glm-5.3"},"content":[{"type":"text","text":"finished"}],"time":{"created":\(nowMs + 10100),"completed":\(nowMs + 10200)},"finish":"stop"}', time_updated = \(nowMs + 10200) WHERE id = 'v2m11';
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .ready })

    // A provider limit can end a v2 turn before an assistant message is written.
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2limit-user', 'ses_v2-1', 'user', 12, \(nowMs + 10300), \(nowMs + 10300), '{"text":"continue","time":{"created":\(nowMs + 10300)}}');
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .running })
    let completionsBeforeLimit = completions.count
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2limit-idle', 'ses_v2-1', 'idle', 13, \(nowMs + 10400), \(nowMs + 10400), '{"time":{"created":\(nowMs + 10400)},"outcome":"failed","error":{"type":"provider.free-limit","message":"Free usage limit reached.","status":429}}');
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .stopped },
           "A v2 provider free-limit idle event must stop the thread")
    assert(completions.count == completionsBeforeLimit, "Provider failures must not notify successful completion")
    opencodeExecute("""
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('v2limit-resume', 'ses_v2-1', 'user', 14, \(nowMs + 10500), \(nowMs + 10500), '{"text":"try another model","time":{"created":\(nowMs + 10500)}}');
    """)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "ses_v2-1" }?.phase == .running },
           "A new user message must start a turn after a failed idle outcome")

    // the same session id in both schema generations stays distinct
    opencodeExecute("""
    INSERT INTO session_v2 (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-1', NULL, 'Duplicate ID', '/tmp/workspace', 'build', '{"id":"gpt-5.1"}', 0, 0, 0, 0, 0, 0, \(nowMs + 9500), \(nowMs + 9500), NULL);
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('oc2dup1', 'ses_oc-1', 'user', 1, \(nowMs + 9500), \(nowMs + 9500), '{"text":"dup","time":{"created":\(nowMs + 9500)}}');
    INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('oc2dup2', 'ses_oc-1', 'assistant', 2, \(nowMs + 9600), \(nowMs + 9600), '{"model":{"id":"gpt-5.1"},"content":[{"type":"text","text":""}],"time":{"created":\(nowMs + 9600)}}');
    UPDATE session_v2 SET time_updated = \(nowMs + 9600) WHERE id = 'ses_oc-1';
    """)
    assert(waitUntil(timeout: 3) {
        let duplicate = latest.filter { $0.id == "ses_oc-1" }
        return duplicate.contains { $0.agent == .opencode } && duplicate.contains { $0.agent == .opencode2 }
    })
    let duplicateGroups = groupActivities(latest).filter { $0.root.id == "ses_oc-1" }
    assert(Set(duplicateGroups.map { activityUIIdentity($0.root) }) == Set(["opencode:ses_oc-1", "opencode2:ses_oc-1"]))

    // channel-specific database from a local build (e.g. `ocfix` writing
    // opencode-<channel>.db) is picked up without a restart.
    let ocChannelDB = ocData.appendingPathComponent("opencode-pr-48918.db")
    opencodeExecute("CREATE TABLE session (id text PRIMARY KEY, parent_id text, title text NOT NULL, directory text NOT NULL, agent text, model text, cost real DEFAULT 0 NOT NULL, tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL, tokens_reasoning integer DEFAULT 0 NOT NULL, tokens_cache_read integer DEFAULT 0 NOT NULL, tokens_cache_write integer DEFAULT 0 NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer); CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL); CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);", at: ocChannelDB)
    opencodeExecute("""
    INSERT INTO session (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-fix', NULL, 'Local build turn', '/tmp/workspace', 'build', '{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"high"}', 0, 10, 5, 0, 0, 0, \(nowMs + 11000), \(nowMs + 11100), NULL);
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('mfix1', 'ses_oc-fix', \(nowMs + 11000), \(nowMs + 11000), '{"role":"user","time":{"created":\(nowMs + 11000)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('pfix1', 'mfix1', 'ses_oc-fix', \(nowMs + 11000), \(nowMs + 11000), '{"type":"text","text":"fix from the local build"}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('mfix2', 'ses_oc-fix', \(nowMs + 11100), \(nowMs + 11100), '{"role":"assistant","modelID":"glm-5.3","variant":"high","time":{"created":\(nowMs + 11100)}}');
    """, at: ocChannelDB)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-fix" }.map { $0.agent == .opencode && $0.phase == .running } ?? false
    })
    assert(latest.first { $0.id == "ses_oc-fix" }?.title == "Local build turn")

    // auto "New session - <timestamp>" titles fall back to the user message.
    opencodeExecute("""
    INSERT INTO session (id, parent_id, title, directory, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived)
    VALUES ('ses_oc-auto', NULL, 'New session - 2026-09-15T07:44:54.967Z', '/tmp/workspace', 'build', NULL, 0, 10, 5, 0, 0, 0, \(nowMs + 12000), \(nowMs + 12100), NULL);
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('mauto1', 'ses_oc-auto', \(nowMs + 12000), \(nowMs + 12000), '{"role":"user","time":{"created":\(nowMs + 12000)}}');
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('pauto1', 'mauto1', 'ses_oc-auto', \(nowMs + 12000), \(nowMs + 12000), '{"type":"text","text":"how do titles work here"}');
    INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('mauto2', 'ses_oc-auto', \(nowMs + 12100), \(nowMs + 12100), '{"role":"assistant","modelID":"glm-5.3","time":{"created":\(nowMs + 12100)}}');
    """)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "ses_oc-auto" }.map { $0.title == "how do titles work here" } ?? false
    })
    ocMonitor.stop()
    try? FileManager.default.removeItem(at: ocRoot)
    try? FileManager.default.removeItem(at: emptyDataHome)
    runClaudeSelfTest()
    print("Session monitor: OK")
}

private func runClaudeSelfTest() {
    func record(_ fields: [String: Any], sessionID: String = "claude-test", entrypoint: String = "cli") -> Data {
        let defaults: [String: Any] = ["sessionId": sessionID, "cwd": "/tmp/workspace",
            "entrypoint": entrypoint, "timestamp": claudeTimestamp.string(from: Date())]
        return try! JSONSerialization.data(withJSONObject: defaults.merging(fields) { _, value in value }) + Data([0x0A])
    }
    let user = record(["type": "user", "message": ["role": "user", "content": "hello from Claude"]])
    let tool = record(["type": "assistant", "message": ["id": "msg-1", "model": "claude-sonnet-4-6",
        "stop_reason": "tool_use", "content": [["type": "tool_use", "id": "read-1", "name": "Read", "input": [:]]],
        "usage": ["input_tokens": 100, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 10, "output_tokens": 5]]])
    let toolUpdated = record(["type": "assistant", "message": ["id": "msg-1", "model": "claude-sonnet-4-6",
        "stop_reason": "tool_use", "content": [["type": "text", "text": "Reading files."]],
        "usage": ["input_tokens": 100, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 10, "output_tokens": 8]]])
    let done = record(["type": "assistant", "message": ["id": "msg-2", "model": "claude-sonnet-4-6",
        "stop_reason": "end_turn", "content": [["type": "text", "text": "All done."]],
        "usage": ["input_tokens": 200, "cache_read_input_tokens": 30, "output_tokens": 10]]])
    let thinking = record(["type": "assistant", "message": ["id": "msg-2", "model": "claude-sonnet-4-6",
        "stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""]],
        "usage": ["input_tokens": 200, "cache_read_input_tokens": 30, "output_tokens": 10]]])
    let duration = record(["type": "system", "subtype": "turn_duration", "durationMs": 100])
    let ask = record(["type": "assistant", "message": ["id": "msg-ask", "stop_reason": "tool_use",
        "content": [["type": "tool_use", "id": "ask-1", "name": "AskUserQuestion",
                     "input": ["questions": [["question": "Which framework?"]]]]]]])
    let answer = record(["type": "user", "message": ["role": "user",
        "content": [["type": "tool_result", "tool_use_id": "ask-1", "content": "SwiftUI"]]]])
    let plan = record(["type": "assistant", "message": ["stop_reason": "tool_use",
        "content": [["type": "tool_use", "id": "plan-1", "name": "ExitPlanMode", "input": ["plan": "Build it."]]]]])
    let interrupted = record(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
    let cost = record(["type": "cost-state", "totalCostUSD": 0.04])
    let generatedTitle = record(["type": "ai-title", "aiTitle": "Generated session title"])
    let taskNotification = record(["type": "user", "origin": ["kind": "task-notification"],
        "turnOrigin": "task_notification", "message": ["content": "<task-notification><task-id>background-task</task-id></task-notification>"]])

    var titleState = ClaudeSessionState()
    titleState.consume(user)
    let promptDate = titleState.updatedAt
    assert(titleState.consume(generatedTitle) && titleState.name == "Generated session title",
           "Claude's saved generated title must take precedence over the prompt fallback")
    assert(titleState.event == .started && titleState.updatedAt == promptDate)
    assert(!titleState.consume(record(["type": "ai-title", "aiTitle": "  "])) && titleState.name == "Generated session title")
    titleState.consume(record(["type": "custom-title", "customTitle": "Manually renamed session"]))
    titleState.consume(record(["type": "ai-title", "aiTitle": "Later generated title"]))
    assert(titleState.name == "Manually renamed session", "Generated titles must not overwrite manual names")

    var notificationState = ClaudeSessionState()
    notificationState.consume(user)
    notificationState.consume(done)
    notificationState.consume(taskNotification)
    assert(notificationState.prompt == "hello from Claude" && notificationState.event == .started,
           "Task notifications start background turns without replacing the actual prompt fallback")
    notificationState.consume(record(["type": "user", "message": ["content": [
        ["type": "text", "text": "<task-notification>Task finished</task-notification>"]]]]))
    assert(notificationState.prompt == "hello from Claude")
    notificationState.consume(record(["type": "user", "origin": ["kind": "task-notification"],
        "message": ["content": "Background task finished"]]))
    assert(notificationState.prompt == "hello from Claude")

    var state = ClaudeSessionState()
    assert(!state.consume(Data("broken json".utf8)))
    assert(!state.consume(record(["type": "file-history-snapshot"])))
    assert(state.consume(user) && state.event == .started && state.prompt == "hello from Claude")
    assert(!state.consume(record(["type": "user", "isMeta": true, "message": ["content": "system reminder"]])))
    assert(!state.consume(record(["type": "user", "isCompactSummary": true, "message": ["content": "old summary"]])))
    assert(!state.consume(record(["type": "user", "message": ["content": "<local-command-stdout>model changed</local-command-stdout>"]])))
    assert(state.prompt == "hello from Claude")
    state.consume(tool)
    state.consume(toolUpdated)
    state.consume(toolUpdated)
    assert(state.event == .started && state.pending.isEmpty && state.usage?.totalTokens == 138)
    state.consume(ask)
    assert(state.pending["ask-1"]?.text == "Which framework?" && state.pending["ask-1"]?.kind == .question)
    state.consume(answer)
    assert(state.pending.isEmpty && state.event == .started && state.prompt == "hello from Claude")
    state.consume(plan)
    assert(state.pending["plan-1"]?.kind == .permission)
    state.consume(interrupted)
    state.consume(duration)
    assert(state.event == .cancelled && state.pending.isEmpty)
    state.consume(user)
    state.consume(thinking)
    assert(state.event == .started && state.response == nil)
    state.consume(record(["type": "assistant", "message": ["content": [["type": "text", "text": "Finished."]], "stop_reason": NSNull()]]))
    assert(state.event == .started)
    state.consume(duration)
    assert(state.event == .completed)
    state.consume(done)
    assert(!state.consume(cost), "Claude API cost estimates must be ignored")
    assert(state.usage?.totalTokens == 378 && state.usage?.contextTokens == 240 && state.usage?.costTotal == nil)
    assert(state.model == "claude-sonnet-4-6")
    state.consume(record(["type": "assistant", "isApiErrorMessage": true, "message": ["model": "<synthetic>", "content": "API error"]]))
    assert(state.event == .cancelled && state.model == "claude-sonnet-4-6")
    assert(claudeSource("claude-desktop") == "desktop" && claudeSource("claude-vscode") == "extension")
    assert(agentRowLabel(.claude) == "claude")
    let handback = record(["type": "assistant", "message": ["stop_reason": NSNull(),
        "content": [["type": "tool_use", "id": "handback-1", "name": "SubagentHandback", "input": ["message": "Pipeline mapped."]]]]])
    let handbackResult = record(["type": "user", "message": ["content": [
        ["type": "tool_result", "tool_use_id": "handback-1", "content": [["type": "text", "text": "{\"success\":true}"]]]]]])
    state.consume(user)
    state.consume(handback)
    assert(state.event == .started)
    state.consume(handbackResult)
    assert(state.event == .completed && state.response == "Pipeline mapped.", "Claude handback results must finish the subagent")
    state.consume(user)
    state.consume(handback)
    state.consume(record(["type": "user", "message": ["content": [
        ["type": "tool_result", "tool_use_id": "handback-1", "content": "{\"success\":false}"]]]]))
    assert(state.event == .started, "A failed handback must not finish the subagent")
    state.consume(record(["type": "assistant", "message": ["content": [
        ["type": "tool_use", "id": "bash-progress", "name": "Bash", "input": ["description": "Compare HEAD routes and refresh job"]]]]]))
    assert(state.response == "Bash: Compare HEAD routes and refresh job")
    assert(shouldMarkStopped(.running, updatedAt: Date().addingTimeInterval(-claudeRunningInactivityTimeout - 1), timeout: claudeRunningInactivityTimeout))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-claude-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    setenv("CLAUDE_CONFIG_DIR", root.path, 1)
    let project = root.appendingPathComponent("projects/-tmp-workspace", isDirectory: true)
    let children = project.appendingPathComponent("claude-test/subagents", isDirectory: true)
    try! FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
    let cliFile = project.appendingPathComponent("claude-test.jsonl")
    let desktopFile = project.appendingPathComponent("desktop-test.jsonl")
    let childFile = children.appendingPathComponent("agent-child.jsonl")
    let secondChildFile = children.appendingPathComponent("agent-second.jsonl")
    let split = tool.count / 2
    let header = Data(#"{"type":"mode","mode":"normal","sessionId":"claude-test"}"#.utf8) + Data([0x0A])
    try! (header + generatedTitle + user + tool.prefix(split)).write(to: cliFile)
    let desktopUser = record(["type": "user", "message": ["role": "user", "content": "Desktop task"]], sessionID: "desktop-test", entrypoint: "claude-desktop")
    let desktopDone = record(["type": "assistant", "message": ["stop_reason": "end_turn", "content": "Desktop done."]], sessionID: "desktop-test", entrypoint: "claude-desktop")
    try! (desktopUser + desktopDone).write(to: desktopFile)
    try! record(["type": "user", "isSidechain": true, "agentId": "child", "message": ["content": "Explore files"]]).write(to: childFile)
    try! record(["type": "user", "isSidechain": true, "agentId": "second", "message": ["content": "Explore integration"]]).write(to: secondChildFile)
    let stale = record(["type": "assistant", "timestamp": claudeTimestamp.string(from: Date().addingTimeInterval(-activityRetention - 10)), "message": ["stop_reason": "end_turn"]], sessionID: "stale")
    try! (record(["type": "user", "timestamp": claudeTimestamp.string(from: Date().addingTimeInterval(-activityRetention - 20)), "message": ["content": "Old task"]], sessionID: "stale") + stale)
        .write(to: project.appendingPathComponent("stale.jsonl"))
    let oldChildren = project.appendingPathComponent("old-parent/subagents", isDirectory: true)
    try! FileManager.default.createDirectory(at: oldChildren, withIntermediateDirectories: true)
    try! record(["type": "assistant", "timestamp": claudeTimestamp.string(from: Date().addingTimeInterval(-activityRetention - 10)),
        "message": ["stop_reason": "end_turn", "content": "Waiting for a long subagent"]], sessionID: "old-parent")
        .write(to: project.appendingPathComponent("old-parent.jsonl"))
    try! record(["type": "user", "isSidechain": true, "agentId": "long", "message": ["content": "Long analysis"]], sessionID: "old-parent")
        .write(to: oldChildren.appendingPathComponent("agent-long.jsonl"))

    var latest: [ThreadActivity] = []
    var completions: [ThreadActivity] = []
    var askings: [ThreadActivity] = []
    let monitor = SessionMonitor()
    monitor.onChange = { activities, _, _ in latest = activities }
    monitor.onCompletion = { completions.append($0) }
    monitor.onAsking = { askings.append($0) }
    monitor.start()
    assert(waitUntil(timeout: 3) {
        latest.contains { $0.id == "claude-test" && $0.phase == .running && $0.usage == nil }
            && latest.contains { $0.id == "desktop-test" && $0.phase == .ready && $0.source == "desktop" }
            && latest.contains { $0.parentID == "claude-test" }
    }, "Claude bootstrap: \(latest.map { "\($0.key) \($0.phase) \($0.source) parent=\($0.parentID ?? "none")" })")
    assert(!latest.contains { $0.id == "stale" })
    assert(groupActivities(latest).first { $0.root.id == "old-parent" }?.phase == .delegating,
           "A completed parent must not expire while its subagent is active")
    assert(completions.isEmpty && askings.isEmpty)
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.children.count == 2)
    assert(latest.first { $0.id == "claude-test" }?.project == "workspace")
    assert(latest.first { $0.id == "claude-test" }?.title == "Generated session title")

    func append(_ data: Data, to file: URL = cliFile) {
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
        try! handle.close()
    }
    append(Data(tool.dropFirst(split)) + toolUpdated + toolUpdated + ask)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }?.prompt?.text == "Which framework?" })
    assert(latest.first { $0.id == "claude-test" }?.usage?.totalTokens == 138)
    assert(askings.filter { $0.id == "claude-test" }.count == 1)
    append(answer + thinking)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }?.usage?.totalTokens == 378 })
    assert(latest.first { $0.id == "claude-test" }?.phase == .running && completions.isEmpty)
    append(done + duration + cost)
    assert(waitUntil(timeout: 3) { groupActivities(latest).first { $0.root.id == "claude-test" }?.phase == .delegating })
    assert(completions.isEmpty)
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.subagentSummary == "2 subagents · 2 running")
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.subagentBadge == "2/2 running")
    monitor.acknowledge(codexSources: [], piSources: [], opencodeSources: [], claudeSources: ["cli"])
    append(record(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "spawn-child", "content": "Started"]]],
        "toolUseResult": ["agentId": "child", "description": "Map preparation/publication pipeline"]]))
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test:agent:child" }?.title == "Map preparation/publication pipeline" })
    append(done + duration + cost)
    append(handback + handbackResult, to: childFile)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test:agent:child" }?.phase == .ready })
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.subagentSummary == "2 subagents · 1 running · 1 done")
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.subagentBadge == "1/2 running")
    assert(groupActivities(latest).first { $0.root.id == "claude-test" }?.children.first?.phase == .running,
           "Active subagents must stay above completed children")
    assert(completions.isEmpty)
    append(handback + handbackResult, to: secondChildFile)
    assert(waitUntil(timeout: 3) {
        latest.first { $0.id == "claude-test" }?.phase == .ready
            && latest.filter { $0.parentID == "claude-test" }.allSatisfy { $0.phase == .ready }
            && completions.count == 1
    })
    let finished = latest.first { $0.id == "claude-test" }
    assert(finished?.agent == .claude && finished?.source == "cli" && finished?.detail == "All done.")
    assert(finished?.prompt == nil && finished?.usage?.totalTokens == 378)
    monitor.acknowledge(codexSources: [], piSources: [], opencodeSources: [], claudeSources: ["cli"])
    assert(waitUntil { latest.first { $0.id == "claude-test" }?.phase == .seen })
    assert(latest.first { $0.id == "desktop-test" }?.phase == .ready)
    append(record(["type": "ai-title", "aiTitle": "Updated generated title"]))
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }?.title == "Updated generated title" })
    assert(latest.first { $0.id == "claude-test" }?.phase == .seen)
    append(record(["type": "custom-title", "customTitle": "Named session"]) + cost)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }?.title == "Named session" })
    assert(latest.first { $0.id == "claude-test" }?.phase == .seen)
    monitor.acknowledge(codexSources: [], piSources: [], opencodeSources: [], claudeSources: ["desktop"])
    assert(waitUntil { latest.first { $0.id == "desktop-test" }?.phase == .seen })
    let desktopAsk = record(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "desktop-ask", "name": "AskUserQuestion", "input": [:]]]]], sessionID: "desktop-test", entrypoint: "claude-desktop")
    let desktopInterrupted = record(["type": "user", "message": ["content": "[Request interrupted by user]"]], sessionID: "desktop-test", entrypoint: "claude-desktop")
    append(desktopUser + desktopAsk + desktopInterrupted, to: desktopFile)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "desktop-test" }?.phase == .stopped })
    assert(latest.first { $0.id == "desktop-test" }?.prompt == nil)
    assert(latest.first { $0.id == "desktop-test" }?.source == "desktop")
    append(record(["type": "assistant", "message": ["stop_reason": "end_turn", "content": "Long analysis complete"]], sessionID: "old-parent"),
        to: oldChildren.appendingPathComponent("agent-long.jsonl"))
    assert(waitUntil(timeout: 3) {
        groupActivities(latest).first { $0.root.id == "old-parent" }?.phase == .ready
            && completions.filter { $0.id == "old-parent" }.count == 1
    }, "A long-running subagent must finish its retained parent and notify once")
    monitor.stop()

    let replay = SessionMonitor()
    replay.onChange = { activities, _, _ in latest = activities }
    replay.onCompletion = { _ in assertionFailure("Historical completion notified") }
    replay.onAsking = { _ in assertionFailure("Resolved historical question notified") }
    latest = []
    replay.start()
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }?.usage?.totalTokens == 378 })
    try! (header + user).write(to: cliFile)
    assert(waitUntil(timeout: 3) { latest.first { $0.id == "claude-test" }.map { $0.phase == .running && $0.usage == nil } ?? false })
    let newFile = project.appendingPathComponent("new-session.jsonl")
    try! record(["type": "user", "message": ["content": "New session"]], sessionID: "new-test").write(to: newFile)
    assert(waitUntil(timeout: 3) { latest.contains { $0.id == "new-test" && $0.phase == .running } })
    // a session whose metadata is still being written must register once it grows.
    let partialFile = project.appendingPathComponent("partial-session.jsonl")
    let partialRecord = record(["type": "user", "message": ["content": "Partial session"]], sessionID: "partial-test")
    try! partialRecord.prefix(12).write(to: partialFile)
    _ = waitUntil(timeout: 1) { false }
    assert(!latest.contains { $0.id == "partial-test" })
    let partialHandle = try! FileHandle(forWritingTo: partialFile)
    try! partialHandle.seekToEnd()
    try! partialHandle.write(contentsOf: partialRecord.dropFirst(12))
    try! partialHandle.close()
    assert(waitUntil(timeout: 3) { latest.contains { $0.id == "partial-test" && $0.phase == .running } })
    replay.stop()
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
