import Foundation

enum AgentNameMentionResolver {
    static func mentionedParticipants(
        in text: String,
        participants: [CodingTask]
    ) -> [CodingTask] {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = participants.compactMap { participant -> (CodingTask, Int)? in
            let nameAlternatives = nameVariants(for: participant.title)
                .map(NSRegularExpression.escapedPattern)
                .joined(separator: "|")
            let pattern = "(?<![\\p{L}\\p{N}_])(?:\(nameAlternatives))(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ), let match = expression.firstMatch(
                in: text,
                range: searchRange
            ) else {
                return nil
            }
            return (participant, match.range.location)
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
                }
                return lhs.1 < rhs.1
            }
            .map(\.0)
    }

    private static func nameVariants(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              trimmed.range(
                  of: "^[А-Яа-яЁё]+$",
                  options: .regularExpression
              ) != nil,
              let last = trimmed.lowercased().last
        else {
            return [trimmed]
        }

        let stem = String(trimmed.dropLast())
        let endings: [String]
        switch last {
        case "а":
            endings = ["а", "ы", "и", "е", "у", "ой", "ою", "ей", "ею"]
        case "я":
            endings = ["я", "и", "е", "ю", "ей", "ею"]
        default:
            return [trimmed]
        }

        return Array(Set([trimmed] + endings.map { stem + $0 }))
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count > rhs.count
            }
    }
}

enum GroupChatPromptBuilder {
    private static let maximumMessageCharacters = 1_800
    private static let maximumPersonaCharacters = 2_800
    private static let maximumTranscriptMessages = 36

    static func participantIntroduction(_ participants: [CodingTask]) -> String {
        let descriptions = participants.map { participant in
            "\(participant.title) — \(shortRole(for: participant))"
        }
        return "В чат добавлены: \(descriptions.joined(separator: "; ")). Каждый участник видит состав группы и общую историю беседы."
    }

    static func shortRole(for participant: CodingTask) -> String {
        var prompt = participant.effectivePersona.prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedName = NSRegularExpression.escapedPattern(for: participant.title)
        let prefixes = [
            "^\\s*Ты\\s*[—-]\\s*\(escapedName)\\s*[,.:—-]?\\s*",
            "^\\s*You\\s+are\\s+\(escapedName)\\s*[,.:—-]?\\s*"
        ]
        for pattern in prefixes {
            if let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) {
                let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
                prompt = expression.stringByReplacingMatches(
                    in: prompt,
                    range: range,
                    withTemplate: ""
                )
            }
        }

        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let firstSentence = firstLine.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { ".!?".contains($0) }
        ).first.map(String.init) ?? firstLine
        let normalized = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "участник группового обсуждения" }
        guard normalized.count > 120 else { return normalized }
        return String(normalized.prefix(120)) + "…"
    }

    static func discussionPrompt(
        group: AgentGroupChat,
        participants: [CodingTask],
        speaker: CodingTask,
        currentUserMessage: String,
        turn: Int,
        totalTurns: Int
    ) -> String {
        """
        Ты — \(speaker.title), участник группового чата «\(group.title)» в Third Hand.

        <your_persona name="\(escapedAttribute(speaker.title))">
        \(limited(speaker.effectivePersona.prompt, to: maximumPersonaCharacters))
        </your_persona>

        <group_members>
        \(roster(participants))
        </group_members>

        Все перечисленные агенты знают, что добавлены в один чат, видят общую историю и могут обращаться друг к другу по обычным именам без символа @.

        Правила текущего обсуждения:
        - Сейчас твоя очередь \(turn) из \(totalTurns). Говори только от лица \(speaker.title) и сохраняй характер этой личности.
        - Реагируй на конкретные аргументы других участников: соглашайся, уточняй или возражай по существу.
        - Обращайся к другим агентам по имени без @, когда это естественно.
        - Внеси один содержательный вклад. Не повторяй весь контекст и не пиши финальное резюме за всю группу.
        - Не добавляй своё имя как префикс: интерфейс уже покажет автора сообщения.
        - Это обсуждение, а не запуск работы с файлами: не меняй репозиторий, не запускай команды и не утверждай, что сделал это.
        - Отвечай на языке последнего сообщения пользователя.

        <visible_group_transcript>
        \(transcript(group.messages))
        </visible_group_transcript>

        <discussion_request>
        \(limited(currentUserMessage, to: 4_000))
        </discussion_request>

        Верни только естественную реплику \(speaker.title), без служебных пометок.
        """
    }

    static func summaryPrompt(
        group: AgentGroupChat,
        participants: [CodingTask],
        facilitator: CodingTask,
        currentUserMessage: String
    ) -> String {
        """
        Ты — \(facilitator.title). Заверши групповое обсуждение «\(group.title)» коротким ответом пользователю.

        <group_members>
        \(roster(participants))
        </group_members>

        <visible_group_transcript>
        \(transcript(group.messages))
        </visible_group_transcript>

        <original_request>
        \(limited(currentUserMessage, to: 4_000))
        </original_request>

        Сформулируй только итог обсуждения:
        - о чём участники договорились;
        - какие разногласия остались, если они есть;
        - какой следующий шаг они предлагают.

        Не придумывай согласие, которого не было в репликах. Обращайся прямо к пользователю, не добавляй имя автора или служебный заголовок — интерфейс сам покажет «Итог обсуждения».
        """
    }

    private static func roster(_ participants: [CodingTask]) -> String {
        participants.map { participant in
            """
            <member name="\(escapedAttribute(participant.title))">
            \(limited(participant.effectivePersona.prompt, to: maximumPersonaCharacters))
            </member>
            """
        }
        .joined(separator: "\n")
    }

    private static func transcript(_ messages: [GroupChatMessage]) -> String {
        let lines = messages.suffix(maximumTranscriptMessages).map { message in
            let speaker: String
            switch message.role {
            case .user:
                speaker = "Пользователь"
            case .agent:
                speaker = message.senderName ?? "Агент"
            case .summary:
                speaker = "Итог обсуждения"
            case .system:
                speaker = "Система"
            }
            return "\(speaker): \(limited(message.text, to: maximumMessageCharacters))"
        }
        return lines.isEmpty ? "История пока пуста." : lines.joined(separator: "\n")
    }

    private static func limited(_ value: String, to maximumCharacters: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
