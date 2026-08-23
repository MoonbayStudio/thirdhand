import Foundation

enum ConversationEnvelopeBuilder {
    private static let maximumHistoryMessages = 20
    private static let maximumMessageCharacters = 2_400

    static func build(
        task: CodingTask,
        currentInstruction: String,
        attachments: [TaskAttachment]
    ) -> String {
        let persona = task.effectivePersona
        var history = task.chatMessages.filter { $0.role != .system }
        if let latest = history.last,
           latest.role == .user,
           normalized(latest.text) == normalized(currentInstruction) {
            history.removeLast()
        }

        let recentHistory = history.suffix(maximumHistoryMessages).map { message in
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
        let continuationContext = task.conversationHandoff.map { handoff in
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
        \(recentHistory.isEmpty ? "История пока пуста." : recentHistory.joined(separator: "\n"))
        </recent_conversation>

        <provider_handoff>
        \(continuationContext ?? "Сжатого контекста переключения нет.")
        </provider_handoff>

        <current_user_message>
        \(currentInstruction)
        </current_user_message>

        <attached_files>
        \(attachmentSummary.isEmpty ? "- Нет." : attachmentSummary.joined(separator: "\n"))
        </attached_files>
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
