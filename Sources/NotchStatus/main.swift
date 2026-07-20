import AppKit
import CoreServices
import Darwin
import Foundation
import UserNotifications

private enum ThreadPhase: Equatable {
    case running
    case ready
    case stopped
}

private let activityRetention: TimeInterval = 15 * 60

private func shouldRetain(_ phase: ThreadPhase, updatedAt: Date, now: Date = Date()) -> Bool {
    phase == .running || now.timeIntervalSince(updatedAt) < activityRetention
}

private func visiblePacmanTrack(
    in bounds: NSRect,
    bodyInset: CGFloat,
    physicalNotchWidth: CGFloat
) -> ClosedRange<CGFloat> {
    let bodyRight = bounds.maxX - bodyInset
    let end = bodyRight - 16
    let start = physicalNotchWidth > 0
        ? bounds.midX + physicalNotchWidth / 2 + 10
        : bounds.minX + bodyInset + 58
    return min(start, end)...end
}

private struct ThreadActivity: Equatable {
    let id: String
    let title: String
    let detail: String
    let source: String
    let project: String
    let phase: ThreadPhase
    let updatedAt: Date
}

private struct SessionMeta {
    let id: String
    let source: String
    let project: String
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
}

private let taskNeedle = Data("\"payload\":{\"type\":\"task_".utf8)
private let abortedNeedle = Data("\"payload\":{\"type\":\"turn_aborted\"".utf8)
private let responseNeedle = Data("\"payload\":{\"type\":\"agent_message\"".utf8)
private let promptNeedle = Data("\"payload\":{\"type\":\"user_message\"".utf8)

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

    let condensed = message.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    return condensed.isEmpty ? nil : String(condensed.prefix(240))
}

private func parseResponse(_ line: Data) -> String? {
    parseMessage(line, needle: responseNeedle, type: "agent_message")
}

private func parsePrompt(_ line: Data) -> String? {
    parseMessage(line, needle: promptNeedle, type: "user_message")
}

private final class SessionMonitor {
    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        let meta: SessionMeta
    }

    var onChange: (([ThreadActivity]) -> Void)?
    var onCompletion: ((ThreadActivity) -> Void)?

    private let queue = DispatchQueue(label: "app.notchstatus.sessions", qos: .utility)
    private let codexHome: URL
    private let sessionsRoot: URL
    private var stream: FSEventStreamRef?
    private var cursors: [String: Cursor] = [:]
    private var activities: [String: ThreadActivity] = [:]
    private var titles: [String: String] = [:]
    private var responses: [String: String] = [:]
    private var prompts: [String: String] = [:]
    private var expiryWorkItem: DispatchWorkItem?
    private var reconciliationTimer: DispatchSourceTimer?

    init() {
        let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        codexHome = environmentHome.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    func start() {
        queue.async { [self] in
            titles = loadTitles()
            bootstrap()
            startEventStream()
            startReconciliationTimer()
            publish()
        }
    }

    func stop() {
        queue.sync { [self] in
            expiryWorkItem?.cancel()
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func bootstrap() {
        for path in recentSessionPaths() {
            _ = register(path)
        }
    }

    private func recentSessionPaths() -> [String] {
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
        if changed { publish() }
    }

    private func startEventStream() {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else { return }

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

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [sessionsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func consume(_ paths: [String]) {
        var changed = false
        let visibleIDs = Set(activities.keys)
        let pathsToRefresh = Set(paths.filter { $0.hasSuffix(".jsonl") }).union(
            cursors.compactMap { visibleIDs.contains($0.value.meta.id) ? $0.key : nil }
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
        guard let meta = readMeta(at: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let fileSize = values.fileSize else { return false }

        cursors[path] = Cursor(offset: UInt64(fileSize), meta: meta)

        guard let snapshot = latestSnapshot(at: path) else { return false }
        if let response = snapshot.response { responses[meta.id] = response }
        if let prompt = snapshot.prompt { prompts[meta.id] = prompt }
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let phase: ThreadPhase
        switch snapshot.event {
        case .started: phase = .running
        case .completed: phase = .ready
        case .cancelled: phase = .stopped
        }
        guard shouldRetain(phase, updatedAt: modifiedAt) else { return false }

        activities[meta.id] = activity(for: meta, phase: phase, at: modifiedAt)
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
                if let prompt = parsePrompt(line) {
                    prompts[cursor.meta.id] = prompt
                    if let current = activities[cursor.meta.id] {
                        activities[cursor.meta.id] = activity(
                            for: cursor.meta,
                            phase: current.phase,
                            at: current.updatedAt
                        )
                        changed = true
                    }
                    continue
                }
                if let response = parseResponse(line) {
                    responses[cursor.meta.id] = response
                    if let current = activities[cursor.meta.id] {
                        activities[cursor.meta.id] = activity(
                            for: cursor.meta,
                            phase: current.phase,
                            at: current.updatedAt
                        )
                        changed = true
                    }
                    continue
                }
                guard let event = parseTurnEvent(line) else { continue }
                titles = loadTitles()
                switch event {
                case .started:
                    responses.removeValue(forKey: cursor.meta.id)
                    prompts.removeValue(forKey: cursor.meta.id)
                    activities[cursor.meta.id] = activity(for: cursor.meta, phase: .running, at: Date())
                case .completed:
                    let completed = activity(for: cursor.meta, phase: .ready, at: Date())
                    if activities[cursor.meta.id]?.phase == .running {
                        DispatchQueue.main.async { [weak self] in self?.onCompletion?(completed) }
                    }
                    activities[cursor.meta.id] = completed
                case .cancelled:
                    activities[cursor.meta.id] = activity(for: cursor.meta, phase: .stopped, at: Date())
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

    private func latestSnapshot(at path: String) -> SessionSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        var position = size
        var carry = Data()
        var latestEvent: TurnEvent?
        var response: String?
        var prompt: String?

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
                    if let event = parseTurnEvent(line) {
                        if latestEvent == nil { latestEvent = event }
                        if event == .started, let latestEvent {
                            return SessionSnapshot(event: latestEvent, response: response, prompt: prompt)
                        }
                    }
                    if let latestEvent, response != nil, prompt != nil {
                        return SessionSnapshot(event: latestEvent, response: response, prompt: prompt)
                    }
                }
                carry = parts.first.map { Data($0) } ?? Data()
            } catch {
                return nil
            }
        }
        return latestEvent.map { SessionSnapshot(event: $0, response: response, prompt: prompt) }
    }

    private func readMeta(at path: String) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: 1_048_576),
              let firstLine = prefix.split(separator: 0x0A, maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let source = payload["source"] as? String else { return nil }

        let cwd = payload["cwd"] as? String ?? ""
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let originator = payload["originator"] as? String ?? ""
        return SessionMeta(id: id, source: sourceLabel(source, originator: originator), project: project)
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

    private func activity(for meta: SessionMeta, phase: ThreadPhase, at date: Date) -> ThreadActivity {
        ThreadActivity(
            id: meta.id,
            title: titles[meta.id] ?? prompts[meta.id] ?? (meta.project.isEmpty ? "Codex thread" : meta.project),
            detail: responses[meta.id] ?? "",
            source: meta.source,
            project: meta.project,
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
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    private func phaseRank(_ phase: ThreadPhase) -> Int {
        switch phase {
        case .running: return 0
        case .stopped: return 1
        case .ready: return 2
        }
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

private enum Palette {
    static let notchBlack = NSColor.black
    static let pacYellow = NSColor(srgbRed: 1, green: 0.82, blue: 0.18, alpha: 1)
    static let readyGreen = NSColor(srgbRed: 0.37, green: 0.88, blue: 0.38, alpha: 1)
    static let stoppedOrange = NSColor(srgbRed: 0.96, green: 0.32, blue: 0.16, alpha: 1)
    static let ghostPurple = NSColor(srgbRed: 0.64, green: 0.48, blue: 0.92, alpha: 1)
    static let vscodeBlue = NSColor(srgbRed: 0, green: 0.48, blue: 0.80, alpha: 1)
    static let phosphor = NSColor(white: 0.94, alpha: 1)
    static let tertiaryInk = NSColor(white: 0.46, alpha: 1)
    static let mutedInk = NSColor(white: 0.29, alpha: 1)
}

private final class IslandView: NSView {
    var onExpansionChange: ((Bool) -> Void)?
    private(set) var expanded = false
    private var activities: [ThreadActivity] = []
    private var topBandHeight: CGFloat = 32
    private var physicalNotchWidth: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var mouthOpen = true
    private var pacmanProgress: CGFloat = 0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Codex agent status")
    }

    required init?(coder: NSCoder) { nil }

    func update(activities: [ThreadActivity]) {
        self.activities = activities
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
        needsDisplay = true
        onExpansionChange?(value)
    }

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

    private func updateExpansion(for event: NSEvent) {
        guard islandPath().contains(convert(event.locationInWindow, from: nil)) else {
            schedulePointerCheck()
            return
        }
        setExpanded(true)
    }

    override func mouseExited(with event: NSEvent) {
        schedulePointerCheck()
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

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "Quit Notch Status", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        Palette.notchBlack.setFill()
        islandPath().fill()
        if expanded { drawExpanded() } else { drawCollapsed() }
    }

    private func drawCollapsed() {
        let centerY = bounds.maxY - topBandHeight / 2
        let bodyLeft = bounds.minX + bodyInset
        let bodyRight = bounds.maxX - bodyInset
        let runningCount = activities.filter { $0.phase == .running }.count
        drawText(
            String(runningCount),
            in: NSRect(x: bodyLeft + 14, y: centerY - 8, width: 28, height: 16),
            font: .monospacedSystemFont(ofSize: 13, weight: .bold),
            color: runningCount > 0 ? Palette.phosphor : Palette.tertiaryInk
        )

        if activities.contains(where: { $0.phase == .running }) {
            let track = visiblePacmanTrack(
                in: bounds,
                bodyInset: bodyInset,
                physicalNotchWidth: physicalNotchWidth
            )
            let pacmanX = track.lowerBound + (track.upperBound - track.lowerBound) * pacmanProgress
            drawDots(after: pacmanX, from: track.lowerBound + 18, through: track.upperBound, y: centerY)
            drawPacman(at: NSPoint(x: pacmanX, y: centerY), pixel: 2, color: Palette.pacYellow, open: mouthOpen)
            setAccessibilityHelp("Codex is working")
        } else if let stopped = activities.first(where: { $0.phase == .stopped }) {
            drawPacman(at: NSPoint(x: bodyRight - 16, y: centerY), pixel: 2, color: Palette.stoppedOrange, open: false)
            setAccessibilityHelp("\(stopped.title) stopped")
        } else if let ready = activities.first(where: { $0.phase == .ready }) {
            drawPacman(at: NSPoint(x: bodyRight - 16, y: centerY), pixel: 2, color: Palette.readyGreen, open: false)
            setAccessibilityHelp("\(ready.title) is complete")
        } else {
            Palette.ghostPurple.setFill()
            NSBezierPath(ovalIn: NSRect(x: bodyRight - 18, y: centerY - 2, width: 4, height: 4)).fill()
            setAccessibilityHelp("No active Codex turns")
        }
    }

    private func drawExpanded() {
        let bodyLeft = bounds.minX + bodyInset
        let bodyRight = bounds.maxX - bodyInset
        if activities.isEmpty {
            drawText(
                "No active Codex turns",
                in: NSRect(x: bodyLeft + 16, y: 15, width: bodyRight - bodyLeft - 32, height: 14),
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                color: Palette.mutedInk
            )
            return
        }

        for (index, activity) in activities.prefix(5).enumerated() {
            let rowTop = bounds.maxY - topBandHeight - CGFloat(index * 46)
            let centerY = rowTop - 24
            let color = statusColor(for: activity.phase)
            let project = String(activity.project.prefix(18))
            let projectFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            let projectWidth = ceil((project as NSString).size(withAttributes: [.font: projectFont]).width)
            let projectX = bodyRight - 16 - projectWidth
            let sourceMarkerX = projectX - 15
            let textX = bodyLeft + 35
            drawPacman(
                at: NSPoint(x: bodyLeft + 16, y: centerY),
                pixel: 2,
                color: color,
                open: activity.phase == .running && mouthOpen
            )
            drawText(
                activity.title,
                in: NSRect(x: textX, y: rowTop - 22, width: max(60, sourceMarkerX - textX - 8), height: 16),
                font: .monospacedSystemFont(ofSize: 12, weight: .bold),
                color: Palette.phosphor
            )
            drawSourceMarker(activity.source, in: NSRect(x: sourceMarkerX, y: rowTop - 19, width: 11, height: 11))
            drawText(
                project,
                in: NSRect(x: projectX, y: rowTop - 22, width: projectWidth, height: 16),
                font: projectFont,
                color: Palette.tertiaryInk
            )
            drawText(
                activity.detail,
                in: NSRect(x: textX, y: rowTop - 39, width: bodyRight - textX - 16, height: 12),
                font: .monospacedSystemFont(ofSize: 9, weight: .medium),
                color: Palette.tertiaryInk
            )
        }
    }

    private var bodyInset: CGFloat { expanded ? 30 : 24 }

    private func islandPath() -> NSBezierPath {
        let neckHeight: CGFloat = expanded ? 10 : 8
        let neckInset = neckHeight * 0.55
        let bottomRadius: CGFloat = expanded ? 22 : 13
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
            if x > pacmanX + 9 {
                NSRect(x: x - 1, y: y - 1, width: 2, height: 2).fill()
            }
            x += 18
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

    private func statusColor(for phase: ThreadPhase) -> NSColor {
        switch phase {
        case .running: return Palette.pacYellow
        case .ready: return Palette.readyGreen
        case .stopped: return Palette.stoppedOrange
        }
    }

    private func drawSourceMarker(_ source: String, in rect: NSRect) {
        ([
            "extension": Palette.vscodeBlue,
            "cli": Palette.readyGreen,
            "codex": Palette.ghostPurple,
        ][source] ?? Palette.phosphor).setFill()
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
                pacmanProgress += 0.02
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
        setAccessibilityValue("\(running) running, \(ready) complete, \(stopped) stopped")
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandController {
    private let panel: IslandPanel
    private let island: IslandView
    private var activities: [ThreadActivity] = []

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
        panel.acceptsMouseMovedEvents = true
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
    }

    func update(_ activities: [ThreadActivity]) {
        self.activities = activities
        island.update(activities: activities)
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

        let collapsedWidth = physicalNotchWidth > 0 ? physicalNotchWidth + 144 : 252
        island.setTopBandHeight(collapsedHeight)
        island.setPhysicalNotchWidth(physicalNotchWidth)
        let rowCount = max(1, min(activities.count, 5))
        let width = island.expanded ? max(458, collapsedWidth) : collapsedWidth
        let height = island.expanded
            ? collapsedHeight + CGFloat(rowCount * 46) + 10
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
        monitor.onChange = { [weak island] activities in island?.update(activities) }
        monitor.onCompletion = { activity in
            let content = UNMutableNotificationContent()
            content.title = "Codex task complete"
            let marker = ["extension": "🟦", "cli": "🟩", "codex": "🟪"][activity.source] ?? "⬜"
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
    let unrelated = Data(#"{"type":"event_msg","payload":{"type":"token_count"}}"#.utf8)
    assert(parseTurnEvent(started) == .started)
    assert(parseTurnEvent(completed) == .completed)
    assert(parseTurnEvent(cancelled) == .cancelled)
    assert(parseTurnEvent(unrelated) == nil)
    assert(parseResponse(response) == "Done. Ready now.")
    assert(parsePrompt(prompt) == "whats this codebase about?")
    assert(parseResponse(unrelated) == nil)
    assert(shouldRetain(.running, updatedAt: .distantPast))
    assert(shouldRetain(.ready, updatedAt: Date().addingTimeInterval(-activityRetention + 1)))
    assert(!shouldRetain(.stopped, updatedAt: Date().addingTimeInterval(-activityRetention - 1)))
    let track = visiblePacmanTrack(
        in: NSRect(x: 0, y: 0, width: 360, height: 37),
        bodyInset: 24,
        physicalNotchWidth: 180
    )
    assert(track.lowerBound > 270 && track.upperBound <= 332)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-status-\(UUID().uuidString)")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let sessions = root.appendingPathComponent("sessions/\(formatter.string(from: Date()))")
    let session = sessions.appendingPathComponent("rollout.jsonl")
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let meta = #"{"type":"session_meta","payload":{"id":"self-test","source":"vscode","originator":"codex_vscode","cwd":"/tmp/workspace"}}"#
    try! Data("\(meta)\n\(String(decoding: started, as: UTF8.self))\n\(String(decoding: prompt, as: UTF8.self))\n".utf8).write(to: session)
    setenv("CODEX_HOME", root.path, 1)

    let monitor = SessionMonitor()
    var latest: [ThreadActivity] = []
    var completions: [ThreadActivity] = []
    monitor.onChange = { latest = $0 }
    monitor.onCompletion = { completions.append($0) }
    monitor.start()
    assert(waitUntil { latest.first?.phase == .running && latest.first?.title == "whats this codebase about?" })
    assert(completions.isEmpty)

    let handle = try! FileHandle(forWritingTo: session)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: completed + Data("\n".utf8))
    try! handle.close()
    assert(waitUntil(timeout: 3) { latest.first?.phase == .ready && completions.count == 1 })
    assert(completions.first?.id == "self-test")
    monitor.stop()
    try? FileManager.default.removeItem(at: root)
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
