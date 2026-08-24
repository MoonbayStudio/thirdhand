import Darwin
import Foundation

protocol ProviderUsageProviding: Sendable {
    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot]
}

actor ProviderUsageService: ProviderUsageProviding {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 15) {
        self.timeout = min(max(timeout, 0.1), 20)
    }

    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot] {
        await withTaskGroup(
            of: (AgentKind, ProviderUsageSnapshot).self,
            returning: [AgentKind: ProviderUsageSnapshot].self
        ) { group in
            for installation in installations {
                group.addTask {
                    (
                        installation.kind,
                        await self.snapshot(for: installation)
                    )
                }
            }

            var result: [AgentKind: ProviderUsageSnapshot] = [:]
            for await (kind, snapshot) in group {
                result[kind] = snapshot
            }
            return result
        }
    }

    func snapshot(for installation: AgentInstallation) async -> ProviderUsageSnapshot {
        guard let executablePath = installation.executablePath else {
            return .unknown(
                for: installation.kind,
                detail: "\(installation.kind.displayName) не найден на этом Mac."
            )
        }

        switch installation.kind {
        case .codex:
            return await codexSnapshot(executablePath: executablePath)
        case .antigravity:
            return await antigravitySnapshot(executablePath: executablePath)
        case .claudeCode:
            return .unknown(for: installation.kind)
        case .deepSeek:
            return .unknown(
                for: installation.kind,
                detail: "DeepSeek Harness не сообщает остаток лимита через headless CLI."
            )
        }
    }

    private func codexSnapshot(executablePath: String) async -> ProviderUsageSnapshot {
        let timeout = timeout
        let probeResult = await Task.detached(priority: .utility) {
            CodexUsageProbe.run(
                executablePath: executablePath,
                timeout: timeout
            )
        }.value

        switch probeResult {
        case let .success(snapshot):
            return snapshot
        case let .failure(error):
            return .unknown(
                for: .codex,
                detail: "Не удалось получить лимит через Codex CLI: \(error.localizedDescription)"
            )
        }
    }

    private func antigravitySnapshot(
        executablePath: String
    ) async -> ProviderUsageSnapshot {
        let result = await AntigravityUsageProbe.run(
            executablePath: executablePath,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            timeout: timeout
        )

        switch result {
        case let .success(snapshot):
            return snapshot
        case let .failure(error):
            return .unknown(
                for: .antigravity,
                detail: "Не удалось получить лимит через Antigravity /usage: \(error.localizedDescription)"
            )
        }
    }
}

enum CodexRateLimitParser {
    static func parseResponseLine(
        _ data: Data,
        now: Date = .now
    ) -> ProviderUsageSnapshot? {
        guard
            let envelope = jsonObject(from: data),
            integer(envelope["id"]) == 2,
            let result = envelope["result"] as? [String: Any],
            let limits = preferredRateLimits(in: result)
        else {
            return nil
        }

        let reachedType = (limits["rateLimitReachedType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var windows: [ProviderUsageWindow] = []

        if let primary = limits["primary"] as? [String: Any],
           let window = parseWindow(primary, id: "primary", fallbackTitle: "Основной") {
            windows.append(window)
        }

        if let secondary = limits["secondary"] as? [String: Any],
           let window = parseWindow(secondary, id: "secondary", fallbackTitle: "Дополнительный") {
            windows.append(window)
        }

        let isExhausted = reachedType?.isEmpty == false

        if windows.isEmpty, !isExhausted {
            return .unknown(
                for: .codex,
                detail: "Codex CLI не вернул окна лимита."
            )
        }

        if windows.isEmpty {
            windows = [
                ProviderUsageWindow(
                    id: "exhausted",
                    title: "Лимит",
                    remainingFraction: 0
                )
            ]
        }

        let state: ProviderUsageState = isExhausted ? .exhausted : .available
        let detail: String
        if let reachedType, !reachedType.isEmpty {
            detail = "Codex сообщил об исчерпанном лимите: \(reachedType)."
        } else if isExhausted {
            detail = "Лимит Codex исчерпан."
        } else {
            detail = "Лимиты обновлены через официальный Codex CLI."
        }

        return ProviderUsageSnapshot(
            agent: .codex,
            state: state,
            windows: windows,
            detail: detail,
            updatedAt: now,
            source: .officialCLI
        )
    }

    static func responseID(in data: Data) -> Int? {
        guard let envelope = jsonObject(from: data) else { return nil }
        return integer(envelope["id"])
    }

    static func responseError(in data: Data) -> String? {
        guard
            let envelope = jsonObject(from: data),
            let error = envelope["error"] as? [String: Any]
        else {
            return nil
        }

        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return "Codex app-server вернул ошибку."
    }

    private static func preferredRateLimits(
        in result: [String: Any]
    ) -> [String: Any]? {
        if
            let byLimitID = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = byLimitID["codex"] as? [String: Any],
            codex["primary"] != nil || codex["secondary"] != nil
                || codex["rateLimitReachedType"] != nil
        {
            return codex
        }

        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(
        _ object: [String: Any],
        id: String,
        fallbackTitle: String
    ) -> ProviderUsageWindow? {
        guard let usedPercent = number(object["usedPercent"]) else {
            return nil
        }

        let remainingFraction = 1 - (usedPercent / 100)
        let durationMinutes = integer(object["windowDurationMins"])
        let resetDate = integer(object["resetsAt"]).flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }

        return ProviderUsageWindow(
            id: id,
            title: windowTitle(
                durationMinutes: durationMinutes,
                fallback: fallbackTitle
            ),
            remainingFraction: remainingFraction,
            resetsAt: resetDate
        )
    }

    private static func windowTitle(
        durationMinutes: Int?,
        fallback: String
    ) -> String {
        guard let durationMinutes, durationMinutes > 0 else { return fallback }

        if durationMinutes.isMultiple(of: 1_440) {
            let days = durationMinutes / 1_440
            return "\(days) дн."
        }

        if durationMinutes.isMultiple(of: 60) {
            let hours = durationMinutes / 60
            return "\(hours) ч."
        }

        return "\(durationMinutes) мин."
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        return nil
    }
}

enum AntigravityUsageParser {
    private struct Group {
        let id: String
        let lineIndex: Int
    }

    static func parse(
        _ output: String,
        now: Date = .now
    ) -> ProviderUsageSnapshot? {
        let cleaned = AgentOutputParser.clean(output)
        guard cleaned.localizedCaseInsensitiveContains("Models & Quota") else {
            return nil
        }

        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let groups = modelGroups(in: lines)
        guard !groups.isEmpty else { return nil }

        var parsedWindows: [ProviderUsageWindow] = []
        for (groupOffset, group) in groups.enumerated() {
            let groupEnd = groupOffset + 1 < groups.count
                ? groups[groupOffset + 1].lineIndex
                : lines.count
            parsedWindows.append(
                contentsOf: parseWindows(
                    in: lines,
                    range: group.lineIndex..<groupEnd,
                    groupID: group.id,
                    now: now
                )
            )
        }

        guard !parsedWindows.isEmpty else { return nil }
        let isComplete = Set(groups.map(\.id)).isSuperset(
            of: ["gemini", "claude-gpt"]
        )
        let isExhausted = isComplete && parsedWindows.allSatisfy {
            $0.remainingFraction == 0
        }

        return ProviderUsageSnapshot(
            agent: .antigravity,
            state: isExhausted ? .exhausted : .available,
            windows: parsedWindows,
            detail: isExhausted
                ? "Antigravity /usage сообщил, что доступные квоты исчерпаны."
                : "Лимиты обновлены через Antigravity /usage.",
            updatedAt: now,
            source: .officialCLI
        )
    }

    private static func modelGroups(in lines: [String]) -> [Group] {
        lines.enumerated().compactMap { index, line in
            let normalized = line.uppercased()
            if normalized.contains("GEMINI MODELS") {
                return Group(id: "gemini", lineIndex: index)
            }
            if normalized.contains("CLAUDE AND GPT MODELS") {
                return Group(id: "claude-gpt", lineIndex: index)
            }
            return nil
        }
    }

    private static func parseWindows(
        in lines: [String],
        range: Range<Int>,
        groupID: String,
        now: Date
    ) -> [ProviderUsageWindow] {
        let headings = range.compactMap { index -> (String, Int, String)? in
            let normalized = lines[index].lowercased()
            if normalized.contains("weekly limit") {
                return ("weekly", index, "7 дн.")
            }
            if normalized.contains("five hour limit")
                || normalized.contains("5 hour limit")
                || normalized.contains("5-hour limit") {
                return ("five-hour", index, "5 ч.")
            }
            return nil
        }

        return headings.enumerated().compactMap { offset, heading in
            let blockEnd = offset + 1 < headings.count
                ? headings[offset + 1].1
                : range.upperBound
            let block = Array(lines[heading.1..<blockEnd])
            guard let fraction = remainingFraction(in: block) else {
                return nil
            }

            return ProviderUsageWindow(
                id: "\(groupID)-\(heading.0)",
                title: heading.2,
                remainingFraction: fraction,
                resetsAt: resetDate(in: block, now: now)
            )
        }
    }

    private static func remainingFraction(in lines: [String]) -> Double? {
        for line in lines {
            if let precise = capture(
                pattern: #"\]\s*([0-9]+(?:\.[0-9]+)?)%"#,
                in: line
            ).flatMap(Double.init) {
                return precise / 100
            }
        }

        for line in lines {
            if let explicit = capture(
                pattern: #"([0-9]+(?:\.[0-9]+)?)%\s+remaining"#,
                in: line
            ).flatMap(Double.init) {
                return explicit / 100
            }
        }

        if lines.contains(where: {
            $0.localizedCaseInsensitiveContains("Quota available")
        }) {
            return 1
        }
        if lines.contains(where: {
            $0.localizedCaseInsensitiveContains("Quota exhausted")
        }) {
            return 0
        }
        return nil
    }

    private static func resetDate(in lines: [String], now: Date) -> Date? {
        guard let duration = lines.compactMap({ line in
            capture(pattern: #"Refreshes in\s+([^·\n]+)"#, in: line)
        }).first else {
            return nil
        }

        let days = capture(pattern: #"(\d+)\s*d"#, in: duration)
            .flatMap(Double.init) ?? 0
        let hours = capture(pattern: #"(\d+)\s*h"#, in: duration)
            .flatMap(Double.init) ?? 0
        let minutes = capture(pattern: #"(\d+)\s*m"#, in: duration)
            .flatMap(Double.init) ?? 0
        let seconds = days * 86_400 + hours * 3_600 + minutes * 60
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    private static func capture(pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }
}

private enum AntigravityUsageProbe {
    static func run(
        executablePath: String,
        workingDirectory: String,
        timeout: TimeInterval
    ) async -> Result<ProviderUsageSnapshot, AntigravityUsageProbeError> {
        let runner = PTYProcessRunner()
        let attemptID = UUID()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"

        let invocation = AgentCLIInvocation(
            attemptID: attemptID,
            executablePath: executablePath,
            arguments: [],
            workingDirectory: workingDirectory,
            environment: environment,
            terminalRows: 60,
            terminalColumns: 120
        )

        return await withTaskGroup(
            of: Result<ProviderUsageSnapshot, AntigravityUsageProbeError>.self,
            returning: Result<ProviderUsageSnapshot, AntigravityUsageProbeError>.self
        ) { group in
            group.addTask {
                await collectSnapshot(
                    from: invocation,
                    runner: runner
                )
            }
            group.addTask {
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else {
                    return .failure(.cancelled)
                }
                runner.cancel(attemptID: attemptID)
                return .failure(.timedOut)
            }

            let result = await group.next() ?? .failure(.cancelled)
            group.cancelAll()
            runner.cancel(attemptID: attemptID)
            return result
        }
    }

    private static func collectSnapshot(
        from invocation: AgentCLIInvocation,
        runner: PTYProcessRunner
    ) async -> Result<ProviderUsageSnapshot, AntigravityUsageProbeError> {
        let maximumOutputBytes = 512 * 1_024
        var rawOutput = Data()
        var sentUsageCommand = false

        do {
            for try await event in runner.events(invocation) {
                switch event {
                case let .output(data, _):
                    rawOutput.append(data)
                    if rawOutput.count > maximumOutputBytes {
                        rawOutput.removeFirst(rawOutput.count - maximumOutputBytes)
                    }

                    let screen = TerminalScreenRenderer.render(
                        String(decoding: rawOutput, as: UTF8.self),
                        rows: Int(invocation.terminalRows),
                        columns: Int(invocation.terminalColumns)
                    )

                    if containsUnsafePrompt(screen) {
                        runner.cancel(attemptID: invocation.attemptID)
                        return .failure(.requiresUserSetup)
                    }

                    if !sentUsageCommand, isReadyForSlashCommand(screen) {
                        guard runner.sendInput(
                            "/usage\r",
                            attemptID: invocation.attemptID
                        ) else {
                            runner.cancel(attemptID: invocation.attemptID)
                            return .failure(.writeFailed)
                        }
                        sentUsageCommand = true
                        continue
                    }

                    if sentUsageCommand,
                       isCompleteUsageScreen(screen),
                       let snapshot = AntigravityUsageParser.parse(screen),
                       hasAllRequiredWindows(snapshot) {
                        _ = runner.sendInput(
                            "\u{001B}",
                            attemptID: invocation.attemptID
                        )
                        return .success(snapshot)
                    }

                case let .finished(result):
                    return .failure(
                        sentUsageCommand
                            ? .endedBeforeQuota(exitCode: result.exitCode)
                            : .promptUnavailable(exitCode: result.exitCode)
                    )
                }
            }
        } catch let error as AgentExecutionError {
            if case .cancelled = error {
                return .failure(.cancelled)
            }
            return .failure(.launchFailed(error.localizedDescription))
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        return .failure(.endedBeforeQuota(exitCode: nil))
    }

    private static func isReadyForSlashCommand(_ screen: String) -> Bool {
        let normalized = screen.lowercased()
        guard normalized.contains("? for shortcuts"),
              !normalized.contains("signing in...")
        else {
            return false
        }

        return screen.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == ">" || trimmed.hasPrefix("> ")
            }
    }

    private static func containsUnsafePrompt(_ screen: String) -> Bool {
        let normalized = screen.lowercased()
        return [
            "do you trust this",
            "trust this folder",
            "trust this workspace",
            "choose an authentication method",
            "select an authentication method",
            "how would you like to authenticate"
        ].contains(where: normalized.contains)
    }

    private static func isCompleteUsageScreen(_ screen: String) -> Bool {
        let normalized = screen.lowercased()
        return normalized.contains("models & quota")
            && normalized.contains("gemini models")
            && normalized.contains("claude and gpt models")
            && normalized.contains("esc")
            && normalized.contains("close")
    }

    private static func hasAllRequiredWindows(
        _ snapshot: ProviderUsageSnapshot
    ) -> Bool {
        let requiredIDs: Set<String> = [
            "gemini-weekly",
            "gemini-five-hour",
            "claude-gpt-weekly",
            "claude-gpt-five-hour"
        ]
        return requiredIDs.isSubset(of: Set(snapshot.windows.map(\.id)))
    }
}

private enum AntigravityUsageProbeError: Error, Sendable {
    case launchFailed(String)
    case writeFailed
    case promptUnavailable(exitCode: Int32?)
    case endedBeforeQuota(exitCode: Int32?)
    case requiresUserSetup
    case timedOut
    case cancelled
}

extension AntigravityUsageProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "не удалось запустить PTY — \(message)"
        case .writeFailed:
            "не удалось отправить /usage в PTY"
        case let .promptUnavailable(exitCode):
            processExitDescription(
                prefix: "CLI завершился до появления безопасного prompt",
                exitCode: exitCode
            )
        case let .endedBeforeQuota(exitCode):
            processExitDescription(
                prefix: "CLI завершился до ответа /usage",
                exitCode: exitCode
            )
        case .requiresUserSetup:
            "CLI ожидает trust или вход; откройте agy в Terminal и завершите настройку"
        case .timedOut:
            "время ожидания /usage истекло"
        case .cancelled:
            "проверка отменена"
        }
    }

    private func processExitDescription(
        prefix: String,
        exitCode: Int32?
    ) -> String {
        guard let exitCode else { return prefix }
        return "\(prefix) (код \(exitCode))"
    }
}

private enum CodexUsageProbe {
    static func run(
        executablePath: String,
        timeout: TimeInterval
    ) -> Result<ProviderUsageSnapshot, CodexUsageProbeError> {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        defer {
            try? inputPipe.fileHandleForWriting.close()
            terminate(process)
        }

        do {
            try writeInitialize(to: inputPipe.fileHandleForWriting)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        let output = outputPipe.fileHandleForReading
        let descriptor = output.fileDescriptor
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt &+ timeoutNanoseconds
        var buffer = Data()
        var didFinishInitialization = false

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            let remainingMilliseconds = max(
                1,
                Int32(min((deadline - now) / 1_000_000, 250))
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, remainingMilliseconds)

            if pollResult < 0 {
                if errno == EINTR { continue }
                return .failure(.readFailed(String(cString: strerror(errno))))
            }

            if pollResult == 0 { continue }

            let readableEvents = Int16(POLLIN | POLLHUP)
            if pollDescriptor.revents & readableEvents != 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(descriptor, storage.baseAddress, storage.count)
                }
                if count == 0 {
                    return .failure(.processEndedBeforeResponse)
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return .failure(.readFailed(String(cString: strerror(errno))))
                }
                buffer.append(contentsOf: bytes.prefix(Int(count)))

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newlineIndex])
                    buffer.removeSubrange(...newlineIndex)
                    guard !line.isEmpty else { continue }

                    switch CodexRateLimitParser.responseID(in: line) {
                    case 1:
                        if let message = CodexRateLimitParser.responseError(in: line) {
                            return .failure(.serverError(message))
                        }
                        guard !didFinishInitialization else { continue }
                        do {
                            try writeRateLimitRead(to: inputPipe.fileHandleForWriting)
                            didFinishInitialization = true
                        } catch {
                            return .failure(.writeFailed(error.localizedDescription))
                        }

                    case 2:
                        if let message = CodexRateLimitParser.responseError(in: line) {
                            return .failure(.serverError(message))
                        }
                        guard let snapshot = CodexRateLimitParser.parseResponseLine(line) else {
                            return .failure(.malformedResponse)
                        }
                        return .success(snapshot)

                    default:
                        continue
                    }
                }
            }

            if pollDescriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                return .failure(.readFailed("канал app-server недоступен"))
            }

            if !process.isRunning, buffer.isEmpty {
                return .failure(.processEndedBeforeResponse)
            }
        }

        return .failure(.timedOut)
    }

    private static func writeInitialize(to handle: FileHandle) throws {
        try writeJSONLine(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "third-hand",
                        "title": "Third Hand",
                        "version": "0.1"
                    ],
                    "capabilities": NSNull()
                ]
            ],
            to: handle
        )
    }

    private static func writeRateLimitRead(to handle: FileHandle) throws {
        try writeJSONLine(
            ["method": "initialized"],
            to: handle
        )
        try writeJSONLine(
            [
                "id": 2,
                "method": "account/rateLimits/read",
                "params": NSNull()
            ],
            to: handle
        )
    }

    private static func writeJSONLine(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        for _ in 0..<50 where process.isRunning {
            usleep(10_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private enum CodexUsageProbeError: Error, Sendable {
    case launchFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case serverError(String)
    case processEndedBeforeResponse
    case malformedResponse
    case timedOut
}

extension CodexUsageProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "не удалось запустить процесс — \(message)"
        case let .writeFailed(message):
            "не удалось отправить запрос — \(message)"
        case let .readFailed(message):
            "не удалось прочитать ответ — \(message)"
        case let .serverError(message):
            message
        case .processEndedBeforeResponse:
            "app-server завершился до ответа"
        case .malformedResponse:
            "app-server вернул неизвестный формат"
        case .timedOut:
            "время ожидания истекло"
        }
    }
}
