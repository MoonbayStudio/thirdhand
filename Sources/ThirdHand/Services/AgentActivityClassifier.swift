import Foundation

enum AgentActivityStage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case preparing
    case compressingContext
    case analyzing
    case readingFiles
    case readingSources
    case searching
    case runningCommand
    case editing
    case verifying
    case responding
    case working
    case stopping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preparing: AppLocalization.string("Готовит контекст")
        case .compressingContext: AppLocalization.string("Сжимает контекст")
        case .analyzing: AppLocalization.string("Анализирует задачу")
        case .readingFiles: AppLocalization.string("Читает файлы")
        case .readingSources: AppLocalization.string("Читает источники")
        case .searching: AppLocalization.string("Ищет по проекту")
        case .runningCommand: AppLocalization.string("Выполняет команду")
        case .editing: AppLocalization.string("Вносит изменения")
        case .verifying: AppLocalization.string("Проверяет результат")
        case .responding: AppLocalization.string("Формирует ответ")
        case .working: AppLocalization.string("Работает над задачей")
        case .stopping: AppLocalization.string("Останавливается")
        }
    }

    var detail: String {
        switch self {
        case .preparing: AppLocalization.string("Собирает Task, Git-снимок и handoff")
        case .compressingContext: AppLocalization.string("Готовит постоянный checkpoint для новой сессии или handoff")
        case .analyzing: AppLocalization.string("Определяет следующий шаг")
        case .readingFiles: AppLocalization.string("Изучает содержимое репозитория")
        case .readingSources: AppLocalization.string("Просматривает внешние материалы")
        case .searching: AppLocalization.string("Находит нужный код и контекст")
        case .runningCommand: AppLocalization.string("Использует CLI-инструменты")
        case .editing: AppLocalization.string("Обновляет файлы рабочего дерева")
        case .verifying: AppLocalization.string("Запускает сборку или тесты")
        case .responding: AppLocalization.string("Собирает итог для чата")
        case .working: AppLocalization.string("Исполнитель готовит ответ")
        case .stopping: AppLocalization.string("Завершает текущий процесс")
        }
    }

    var systemImage: String {
        switch self {
        case .preparing: "shippingbox"
        case .compressingContext: "arrow.triangle.2.circlepath"
        case .analyzing: "brain.head.profile"
        case .readingFiles: "doc.text.magnifyingglass"
        case .readingSources: "globe"
        case .searching: "magnifyingglass"
        case .runningCommand: "terminal"
        case .editing: "square.and.pencil"
        case .verifying: "checkmark.seal"
        case .responding: "text.bubble"
        case .working: "sparkles"
        case .stopping: "stop.circle"
        }
    }
}

struct AgentActivityPresentation: Hashable, Sendable {
    let current: AgentActivityStage
    let recent: [AgentActivityStage]
    let lastEventAt: Date?
}

enum AgentActivityClassifier {
    static func presentation(
        for run: AgentRunState,
        output: AgentLiveOutput?
    ) -> AgentActivityPresentation {
        switch run.phase {
        case .preparing:
            return AgentActivityPresentation(
                current: .preparing,
                recent: [.preparing],
                lastEventAt: nil
            )
        case .compressingContext:
            return AgentActivityPresentation(
                current: .compressingContext,
                recent: [.compressingContext],
                lastEventAt: output?.updatedAt
            )
        case .stopping:
            return AgentActivityPresentation(
                current: .stopping,
                recent: [.stopping],
                lastEventAt: output?.updatedAt
            )
        case .running:
            break
        }

        guard let output,
              !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return AgentActivityPresentation(
                current: .working,
                recent: [.working],
                lastEventAt: nil
            )
        }

        var recent: [AgentActivityStage] = []
        for line in output.text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let stage = stage(for: String(line)) else { continue }
            if recent.last != stage {
                recent.append(stage)
            }
        }

        let compactRecent = Array(recent.suffix(4))
        return AgentActivityPresentation(
            current: compactRecent.last ?? .working,
            recent: compactRecent.isEmpty ? [.working] : compactRecent,
            lastEventAt: output.updatedAt
        )
    }

    private static func stage(for line: String) -> AgentActivityStage? {
        let value = line.lowercased()
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "exec", "command", "shell":
            return .runningCommand
        case "analysis", "thinking", "reasoning":
            return .analyzing
        case "read", "view":
            return .readingFiles
        case "web", "browser", "fetch":
            return .readingSources
        case "search":
            return .searching
        case "edit", "patch", "write":
            return .editing
        case "test", "build", "verify":
            return .verifying
        case "final", "response", "assistant", "codex":
            return .responding
        default:
            break
        }

        let groups: [(AgentActivityStage, [String])] = [
            (.verifying, [
                "swift test", "xcodebuild", "npm test", "pnpm test", "pytest",
                "cargo test", "gradle test", "running tests", "build complete"
            ]),
            (.editing, [
                "apply_patch", "write_file", "edit_file", "updated file",
                "edited file", "patching", "writing file"
            ]),
            (.readingSources, [
                "search_query", "web_search", "web.run", "fetching url",
                "opening url", "open url", "web fetch"
            ]),
            (.readingFiles, [
                "read_file", "reading file", "open_file", "view_image",
                "sed -n", "cat "
            ]),
            (.searching, [
                "searching", "code search", "file search", "rg ", "grep ", "find "
            ]),
            (.runningCommand, [
                "exec_command", "shell_command", "running command", "command output"
            ]),
            (.responding, [
                "final answer", "final_response", "writing response", "agent_response"
            ]),
            (.analyzing, [
                "analysis", "thinking", "planning", "reasoning"
            ])
        ]

        return groups.first { _, markers in
            markers.contains(where: value.contains)
        }?.0
    }
}
