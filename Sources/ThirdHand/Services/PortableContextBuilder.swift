import Foundation

enum PortableContextBuilder {
    private static let maximumContextCharacters = 32_000

    static func compressionRequest(
        for task: CodingTask,
        interactionMode: AgentInteractionMode,
        agent: AgentKind
    ) -> AgentHandoffCompressionRequest {
        let scope = AgentSessionScope(interactionMode: interactionMode)
        let existingCheckpoint = task.portableContextCheckpoint.flatMap {
            $0.scope == scope ? $0 : nil
        }
        let messages = uncoveredMessages(in: task, checkpoint: existingCheckpoint)
            .suffix(24)
            .map { message in
                let speaker: String
                switch message.role {
                case .user: speaker = "Пользователь"
                case .agent: speaker = task.title
                case .system: speaker = "Система"
                }
                return "- \(speaker): \(limited(message.text, to: 1_600))"
            }
        let existingText = existingCheckpoint.map { checkpoint in
            """
            Решения и факты:
            \(list(checkpoint.decisions))
            Прогресс и недавний контекст:
            \(list(checkpoint.progress))
            Открытые темы и риски:
            \(list(checkpoint.knownIssues))
            Следующий шаг:
            \(limited(checkpoint.nextStep, to: 1_200))
            """
        } ?? "- Нет предыдущего checkpoint."

        let modeInstruction: String
        if interactionMode == .workspace {
            modeInstruction = """
            Это работа с проектом. Сохрани принятые решения, реально выполненную работу, непроверенные места и один конкретный следующий шаг. Не воспроизводи код целиком: следующий агент самостоятельно прочитает рабочее дерево и Git diff.

            Текущий semantic handoff:
            Решения: \(list(task.handoff.decisions))
            Прогресс: \(list(task.handoff.progress))
            Риски: \(list(task.handoff.knownIssues))
            Следующий шаг: \(limited(task.handoff.nextStep, to: 1_200))
            """
        } else {
            modeInstruction = """
            Это личный диалог. Сохрани устойчивые факты и предпочтения пользователя, эмоциональный контекст, незакрытые темы и естественное продолжение. Не превращай разговор в задачу по разработке.
            """
        }

        let context = """
        Пользователь вручную запросил компактный переносимый checkpoint в Third Hand. Он будет сохранён приложением, использован при новом CLI-сеансе и передан другому провайдеру во время handoff.

        <agent name="\(task.title)">
        \(limited(task.effectivePersona.prompt, to: 3_000))
        </agent>

        <mode>
        \(modeInstruction)
        </mode>

        <existing_checkpoint>
        \(existingText)
        </existing_checkpoint>

        <uncompressed_tail>
        \(messages.isEmpty ? "- Новых сообщений нет." : messages.joined(separator: "\n"))
        </uncompressed_tail>

        Верни только фактический checkpoint. Не утверждай, что работа выполнена, если этого нет в контексте.
        """

        return AgentHandoffCompressionRequest(
            previousAgent: agent,
            nextAgent: agent,
            context: limited(context, to: maximumContextCharacters),
            interactionMode: interactionMode
        )
    }

    static func localFallback(
        for task: CodingTask,
        interactionMode: AgentInteractionMode
    ) -> CompressedAgentHandoff {
        let scope = AgentSessionScope(interactionMode: interactionMode)
        let existingCheckpoint = task.portableContextCheckpoint.flatMap {
            $0.scope == scope ? $0 : nil
        }

        if interactionMode == .workspace {
            return CompressedAgentHandoff(
                decisions: Array(task.handoff.decisions.suffix(4)),
                progress: Array(task.handoff.progress.suffix(4)),
                knownIssues: Array(task.handoff.knownIssues.suffix(4)),
                nextStep: task.handoff.nextStep.isEmpty
                    ? "Продолжить с проверки рабочего дерева и актуального Git diff."
                    : limited(task.handoff.nextStep, to: 1_000),
                modelID: "локальное сжатие"
            )
        }

        let recent = uncoveredMessages(in: task, checkpoint: existingCheckpoint)
            .suffix(6)
            .map { message in
                let speaker = message.role == .agent ? task.title : "Пользователь"
                return "\(speaker): \(limited(message.text, to: 600))"
            }
        return CompressedAgentHandoff(
            decisions: existingCheckpoint?.decisions ?? [],
            progress: recent.isEmpty
                ? (existingCheckpoint?.progress ?? [])
                : Array(recent),
            knownIssues: existingCheckpoint?.knownIssues ?? [],
            nextStep: "Продолжить диалог с учётом checkpoint и следующего сообщения пользователя.",
            modelID: "локальное сжатие"
        )
    }

    static func checkpoint(
        from handoff: CompressedAgentHandoff,
        task: CodingTask,
        interactionMode: AgentInteractionMode
    ) -> PortableContextCheckpoint {
        let messages = task.chatMessages.filter { $0.role != .system }
        let characterCount = messages.reduce(0) { $0 + $1.text.count }
        return PortableContextCheckpoint(
            scope: AgentSessionScope(interactionMode: interactionMode),
            decisions: handoff.decisions,
            progress: handoff.progress,
            knownIssues: handoff.knownIssues,
            nextStep: handoff.nextStep,
            coveredThroughMessageID: messages.last?.id,
            sourceMessageCount: messages.count,
            estimatedOriginalTokens: max(1, Int(ceil(Double(characterCount) / 4.0))),
            modelID: handoff.modelID
        )
    }

    private static func uncoveredMessages(
        in task: CodingTask,
        checkpoint: PortableContextCheckpoint?
    ) -> [TaskMessage] {
        let messages = task.chatMessages.filter { $0.role != .system }
        guard let coveredID = checkpoint?.coveredThroughMessageID,
              let index = messages.firstIndex(where: { $0.id == coveredID })
        else {
            return messages
        }
        return Array(messages.suffix(from: messages.index(after: index)))
    }

    private static func list(_ values: [String]) -> String {
        let entries = values.suffix(6).map { "- \(limited($0, to: 700))" }
        return entries.isEmpty ? "- Нет." : entries.joined(separator: "\n")
    }

    private static func limited(_ value: String, to maximumCharacters: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }
}
