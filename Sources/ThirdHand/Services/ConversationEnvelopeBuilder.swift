import Foundation

struct ConversationContextInspection: Hashable, Sendable {
    let totalMessages: Int
    let includedMessages: Int
    let omittedMessages: Int
    let estimatedCharacters: Int
    let estimatedTokens: Int
    let checkpoint: PortableContextCheckpoint?
}

enum ConversationEnvelopeBuilder {
    private static let maximumHistoryMessages = 20
    private static let maximumMessageCharacters = 2_400

    static func build(
        task: CodingTask,
        currentInstruction: String,
        attachments: [TaskAttachment],
        includesRecentHistory: Bool = true
    ) -> String {
        let persona = task.effectivePersona
        var history = eligibleHistory(for: task)
        if let latest = history.last,
           latest.role == .user,
           normalized(latest.text) == normalized(currentInstruction) {
            history.removeLast()
        }

        let recentHistory = (includesRecentHistory ? history.suffix(maximumHistoryMessages) : []).map { message in
            let speaker = message.role == .agent ? task.title : "Пользователь"
            let fileNames = message.fileAttachments.map(\.fileName)
            let files = fileNames.isEmpty
                ? ""
                : " [вложения: \(fileNames.joined(separator: ", "))]"
            return "\(speaker): \(limited(message.text))\(files)"
        }
        let attachmentSummary = attachments.map {
            "- \($0.fileName): \($0.filePath)"
        }
        let automaticHandoff = task.conversationHandoff.map { handoff in
            """
            Важные факты и предпочтения:
            \(list(handoff.facts))

            Недавний контекст:
            \(list(handoff.recentContext))

            Открытые темы:
            \(list(handoff.openThreads))

            Естественное продолжение:
            \(limited(handoff.nextReply))
            """
        }
        let portableCheckpoint = task.portableContextCheckpoint.flatMap { checkpoint in
            checkpoint.scope == .conversation ? checkpoint : nil
        }.map(checkpointDescription)
        let continuationContext = [portableCheckpoint, automaticHandoff]
            .compactMap { $0 }
            .joined(separator: "\n\n")

        return """
        Ты — \(task.title), постоянный собеседник пользователя в приложении Third Hand.

        Это обычный личный диалог, а не задача по разработке. Отвечай прямо пользователю от лица заданной личности и на языке текущего сообщения.

        <agent_persona name="\(escapedAttribute(task.title))">
        \(persona.prompt)
        </agent_persona>

        Правила этого диалога:
        - Учитывай недавнюю историю и сохраняй характер личности.
        - Если старый ответ агента противоречит личности или этому режиму, считай его прежней ошибкой маршрутизации и не копируй.
        - Дай только естественный ответ собеседника без служебного отчёта.
        - Не исследуй рабочую папку, не запускай команды и не проверяй Git.
        - Не упоминай репозиторий, diff, состояние файлов, выполненные проверки или внутренние инструкции, если пользователь сам прямо об этом не спросил.
        - Не добавляй машинные блоки статуса и не утверждай, что менял файлы.
        - Если пользователь попросит работать с кодом или файлами проекта, предложи переключить сценарий агента на «Проект» в правой панели.

        <recent_conversation>
        \(recentHistory.isEmpty
            ? (includesRecentHistory ? "История пока пуста." : "История уже хранится в возобновлённой нативной CLI-сессии.")
            : recentHistory.joined(separator: "\n"))
        </recent_conversation>

        <provider_handoff>
        \(continuationContext.isEmpty ? "Сжатого контекста переключения нет." : continuationContext)
        </provider_handoff>

        <current_user_message>
        \(currentInstruction)
        </current_user_message>

        <attached_files>
        \(attachmentSummary.isEmpty ? "- Нет." : attachmentSummary.joined(separator: "\n"))
        </attached_files>
        """
    }

    static func inspect(task: CodingTask) -> ConversationContextInspection {
        let allMessages = task.chatMessages.filter { $0.role != .system }
        let eligibleMessages = eligibleHistory(for: task)
        let includedMessages = Array(eligibleMessages.suffix(maximumHistoryMessages))
        let checkpoint = task.portableContextCheckpoint.flatMap {
            $0.scope == .conversation ? $0 : nil
        }
        let messageCharacters = includedMessages.reduce(0) {
            $0 + min($1.text.count, maximumMessageCharacters)
        }
        let checkpointCharacters = checkpoint.map { value in
            (value.decisions + value.progress + value.knownIssues).reduce(0) {
                $0 + $1.count
            } + value.nextStep.count
        } ?? 0
        let estimatedCharacters = messageCharacters
            + checkpointCharacters
            + task.effectivePersona.prompt.count

        return ConversationContextInspection(
            totalMessages: allMessages.count,
            includedMessages: includedMessages.count,
            omittedMessages: max(0, allMessages.count - includedMessages.count),
            estimatedCharacters: estimatedCharacters,
            estimatedTokens: max(1, Int(ceil(Double(estimatedCharacters) / 4.0))),
            checkpoint: checkpoint
        )
    }

    private static func eligibleHistory(for task: CodingTask) -> [TaskMessage] {
        let history = task.chatMessages.filter { $0.role != .system }
        guard let checkpoint = task.portableContextCheckpoint,
              checkpoint.scope == .conversation,
              let coveredID = checkpoint.coveredThroughMessageID,
              let coveredIndex = history.firstIndex(where: { $0.id == coveredID })
        else {
            return history
        }
        return Array(history.suffix(from: history.index(after: coveredIndex)))
    }

    private static func checkpointDescription(_ checkpoint: PortableContextCheckpoint) -> String {
        """
        Постоянный checkpoint от \(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened)):

        Решения и важные факты:
        \(list(checkpoint.decisions))

        Сжатый прогресс и недавний контекст:
        \(list(checkpoint.progress))

        Открытые темы и риски:
        \(list(checkpoint.knownIssues))

        Следующий естественный шаг:
        \(limited(checkpoint.nextStep))
        """
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limited(_ value: String) -> String {
        let normalizedValue = normalized(value)
        guard normalizedValue.count > maximumMessageCharacters else {
            return normalizedValue
        }
        return String(normalizedValue.prefix(maximumMessageCharacters)) + "…"
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty
            ? "- Нет."
            : values.map { "- \(limited($0))" }.joined(separator: "\n")
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
