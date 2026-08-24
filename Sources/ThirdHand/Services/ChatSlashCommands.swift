import Foundation

enum ChatSlashCommandArgumentKind: Hashable, Sendable {
    case none
    case model
    case session
}

struct ChatSlashCommandDescriptor: Identifiable, Hashable, Sendable {
    let name: String
    let title: String
    let detail: String
    let systemImage: String
    let insertionText: String
    let argumentKind: ChatSlashCommandArgumentKind

    init(
        name: String,
        title: String,
        detail: String,
        systemImage: String,
        insertionText: String,
        argumentKind: ChatSlashCommandArgumentKind = .none
    ) {
        self.name = name
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.insertionText = insertionText
        self.argumentKind = argumentKind
    }

    var id: String { name }

    static let all: [Self] = [
        Self(
            name: "/context",
            title: "Контекст",
            detail: "Показать объём памяти, checkpoint и активную CLI-сессию",
            systemImage: "gauge.with.dots.needle.33percent",
            insertionText: "/context"
        ),
        Self(
            name: "/compact",
            title: "Компактный",
            detail: "Сжать контекст чата и начать чистую нативную сессию",
            systemImage: "circle.lefthalf.filled",
            insertionText: "/compact"
        ),
        Self(
            name: "/model",
            title: "Модель",
            detail: "Показать или сменить модель текущего агента",
            systemImage: "cube",
            insertionText: "/model",
            argumentKind: .model
        ),
        Self(
            name: "/session",
            title: "Сессия",
            detail: "Статус, resume, новая или забытая CLI-сессия",
            systemImage: "link",
            insertionText: "/session status",
            argumentKind: .session
        ),
        Self(
            name: "/handoff",
            title: "Handoff",
            detail: "Подготовить переносимый checkpoint для другого провайдера",
            systemImage: "arrow.triangle.branch",
            insertionText: "/handoff"
        ),
        Self(
            name: "/help",
            title: "Команды",
            detail: "Показать все slash-команды и примеры",
            systemImage: "questionmark.circle",
            insertionText: "/help"
        )
    ]

    static func suggestions(for draft: String) -> [Self] {
        guard let fragment = activeFragment(in: draft) else { return [] }
        let normalized = fragment.text.lowercased()
        return all.filter { descriptor in
            normalized == "/" || descriptor.name.hasPrefix(normalized)
        }
    }

    static func activeFragment(
        in draft: String
    ) -> (text: String, range: NSRange)? {
        let source = draft as NSString
        guard source.length > 0 else { return nil }

        var start = source.length
        while start > 0,
              !isWhitespace(source.character(at: start - 1)) {
            start -= 1
        }

        guard start < source.length else { return nil }
        let range = NSRange(location: start, length: source.length - start)
        let fragment = source.substring(with: range)
        guard fragment.hasPrefix("/") else { return nil }
        return (fragment, range)
    }

    static func recognizedCompletion(
        in draft: String
    ) -> (command: Self, replacementRange: NSRange)? {
        let source = draft as NSString
        var location = 0
        var latestCompletion: (command: Self, replacementRange: NSRange)?

        while location < source.length {
            while location < source.length,
                  isWhitespace(source.character(at: location)) {
                location += 1
            }
            let tokenStart = location
            while location < source.length,
                  !isWhitespace(source.character(at: location)) {
                location += 1
            }
            let tokenEnd = location
            guard tokenStart < tokenEnd else { break }

            if tokenEnd < source.length {
                let commandName = source.substring(
                    with: NSRange(
                        location: tokenStart,
                        length: tokenEnd - tokenStart
                    )
                ).lowercased()
                if let command = all.first(where: { $0.name == commandName }) {
                    var replacementEnd = tokenEnd
                    while replacementEnd < source.length,
                          isWhitespace(source.character(at: replacementEnd)) {
                        replacementEnd += 1
                    }
                    latestCompletion = (
                        command,
                        NSRange(
                            location: tokenStart,
                            length: replacementEnd - tokenStart
                        )
                    )
                }
            }
        }
        return latestCompletion
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(
            UnicodeScalar(character) ?? UnicodeScalar(0)
        )
    }
}

struct ChatSlashCommandOption: Identifiable, Hashable, Sendable {
    let id: String
    let commandName: String
    let title: String
    let detail: String
    let systemImage: String
    let argumentText: String
    let isCurrent: Bool

    init(
        id: String,
        commandName: String,
        title: String,
        detail: String,
        systemImage: String,
        argumentText: String,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.commandName = commandName
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.argumentText = argumentText
        self.isCurrent = isCurrent
    }

    var commandText: String {
        let argument = argumentText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return argument.isEmpty ? commandName : "\(commandName) \(argument)"
    }

    static func modelOptions(
        _ models: [AgentValueOption],
        selectedID: String?,
        sourceTitle: String
    ) -> [Self] {
        var seenIDs = Set<String>()
        return models.compactMap { model in
            guard seenIDs.insert(model.id.lowercased()).inserted else {
                return nil
            }
            let isSelected = selectedID.map {
                $0.caseInsensitiveCompare(model.id) == .orderedSame
            } ?? false
            let detail = [
                isSelected ? "Текущая модель" : nil,
                model.detail,
                sourceTitle
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

            return Self(
                id: "model:\(model.id)",
                commandName: "/model",
                title: model.title,
                detail: detail,
                systemImage: isSelected ? "checkmark.circle.fill" : "cube",
                argumentText: model.id,
                isCurrent: isSelected
            )
        }
    }

    static func sessionOptions(
        bindings: [AgentSessionBinding]
    ) -> [Self] {
        let actions = [
            Self(
                id: "session:status",
                commandName: "/session",
                title: "Показать статус",
                detail: "Активная и сохранённые CLI-сессии",
                systemImage: "info.circle",
                argumentText: "status"
            ),
            Self(
                id: "session:new",
                commandName: "/session",
                title: "Новая сессия",
                detail: "Сбросить текущую привязку перед следующим сообщением",
                systemImage: "plus.circle",
                argumentText: "new"
            ),
            Self(
                id: "session:forget",
                commandName: "/session",
                title: "Забыть привязку",
                detail: "Не удаляет файлы сессии самого CLI",
                systemImage: "link.badge.minus",
                argumentText: "forget"
            )
        ]

        var seenSessionIDs = Set<String>()
        let savedSessions = bindings.compactMap { binding -> Self? in
            guard seenSessionIDs.insert(binding.sessionID).inserted else {
                return nil
            }
            return Self(
                id: "session:resume:\(binding.sessionID)",
                commandName: "/session",
                title: "Возобновить сохранённую",
                detail: "\(binding.agent.shortName) · \(binding.scope.title) · \(binding.sessionID)",
                systemImage: "arrow.clockwise.circle",
                argumentText: "resume \(binding.sessionID)"
            )
        }

        let manualResume = Self(
            id: "session:resume-manual",
            commandName: "/session",
            title: "Resume по ID…",
            detail: "Подставить идентификатор другой CLI-сессии вручную",
            systemImage: "arrow.clockwise",
            argumentText: "resume "
        )
        return actions + savedSessions + [manualResume]
    }
}

enum ChatSessionCommand: Hashable, Sendable {
    case status
    case new
    case forget
    case resume(String)
}

enum ChatSlashCommand: Hashable, Sendable {
    case help
    case context
    case compact
    case handoff
    case model(String?)
    case session(ChatSessionCommand)
}

struct ChatSlashCommandParseError: LocalizedError, Hashable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum ChatSlashCommandParser {
    static func parse(_ input: String) throws -> ChatSlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let components = trimmed.split(
            maxSplits: 1,
            whereSeparator: \.isWhitespace
        )
        let name = components.first.map(String.init)?.lowercased() ?? ""
        let argument = components.count > 1
            ? String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch name {
        case "/help":
            try requireEmpty(argument, command: name)
            return .help
        case "/context":
            try requireEmpty(argument, command: name)
            return .context
        case "/compact":
            try requireEmpty(argument, command: name)
            return .compact
        case "/handoff":
            try requireEmpty(argument, command: name)
            return .handoff
        case "/model":
            return .model(argument.isEmpty ? nil : argument)
        case "/session":
            return try .session(parseSession(argument))
        default:
            throw ChatSlashCommandParseError(
                message: "Неизвестная команда \(name). Введите /help."
            )
        }
    }

    private static func parseSession(_ argument: String) throws -> ChatSessionCommand {
        guard !argument.isEmpty else { return .status }
        let components = argument.split(
            maxSplits: 1,
            whereSeparator: \.isWhitespace
        )
        let action = components.first.map(String.init)?.lowercased() ?? "status"
        let value = components.count > 1
            ? String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch action {
        case "status", "list":
            guard value.isEmpty else {
                throw ChatSlashCommandParseError(
                    message: "Использование: /session status"
                )
            }
            return .status
        case "new":
            guard value.isEmpty else {
                throw ChatSlashCommandParseError(
                    message: "Использование: /session new"
                )
            }
            return .new
        case "forget", "clear":
            guard value.isEmpty else {
                throw ChatSlashCommandParseError(
                    message: "Использование: /session forget"
                )
            }
            return .forget
        case "resume":
            guard !value.isEmpty else {
                throw ChatSlashCommandParseError(
                    message: "Использование: /session resume <session-id>"
                )
            }
            return .resume(value)
        default:
            throw ChatSlashCommandParseError(
                message: "Использование: /session status | new | forget | resume <session-id>"
            )
        }
    }

    private static func requireEmpty(_ argument: String, command: String) throws {
        guard argument.isEmpty else {
            throw ChatSlashCommandParseError(message: "Использование: \(command)")
        }
    }
}
