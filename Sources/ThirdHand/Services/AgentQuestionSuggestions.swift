import Foundation

enum AgentQuestionSuggestions {
    static func requiresUserResponse(from text: String) -> Bool {
        if !choices(from: text).isEmpty {
            return true
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return false }
        return lastLine.hasSuffix("?")
            || lastLine.hasSuffix("？")
    }

    static func choices(from text: String) -> [String] {
        let normalizedText = text.lowercased()
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let listed = lines.compactMap(extractChoice).prefix(4)
        let looksLikeChoicePrompt = text.contains("?")
            || normalizedText.contains("выберите")
            || normalizedText.contains("какой вариант")
            || normalizedText.contains("choose")
            || normalizedText.contains("which option")
        if listed.count >= 2, looksLikeChoicePrompt {
            return Array(listed)
        }

        guard let lastLine = lines.last,
              lastLine.contains("?") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        else {
            return []
        }

        let confirmationMarkers = [
            "да/нет", "(y/n)", "[y/n]", "продолж", "разреш", "подтверд",
            "соглас", "хотите", "нужно ли", "можно ли", "proceed", "continue",
            "do you want", "would you like", "confirm"
        ]
        guard confirmationMarkers.contains(where: normalizedText.contains) else {
            return []
        }
        return ["Да", "Нет"]
    }

    private static func extractChoice(from line: String) -> String? {
        let patterns = [
            #"^(?:[-*•])\s+(.{1,100})$"#,
            #"^\d+[.)]\s+(.{1,100})$"#,
            #"^[A-Za-zА-Яа-я][.)]\s+(.{1,100})$"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                  ),
                  let range = Range(match.range(at: 1), in: line)
            else {
                continue
            }

            let value = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasSuffix("?") ? String(value.dropLast()) : value
        }
        return nil
    }
}
