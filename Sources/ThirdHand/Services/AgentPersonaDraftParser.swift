import Foundation

struct AgentPersonaSeed: Hashable, Sendable {
    let name: String
    let prompt: String
    let avatarEmoji: String
    let avatarColor: AgentAvatarColor
}

enum AgentPersonaDraftParser {
    static func parse(_ description: String) -> AgentPersonaSeed {
        let prompt = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = prompt.lowercased()

        return AgentPersonaSeed(
            name: extractedName(from: prompt) ?? "Новый агент",
            prompt: prompt,
            avatarEmoji: avatar(for: normalized),
            avatarColor: color(for: normalized)
        )
    }

    private static func extractedName(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:^|\s)(?:ты|тебя\s+зовут)\s*[—–-]?\s*([\p{L}\p{N}_-]{2,24})"#,
            #"(?i)(?:назови\s+(?:его|ее|её|агента)|имя)\s*[:—–-]?\s*([\p{L}\p{N}_-]{2,24})"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }

            let candidate = String(text[matchRange])
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if !candidate.isEmpty {
                return candidate.prefix(1).uppercased() + String(candidate.dropFirst())
            }
        }

        return nil
    }

    private static func avatar(for text: String) -> String {
        if containsAny(text, ["дизайн", "designer", "иллюстр", "ui", "ux"]) { return "🎨" }
        if containsAny(text, ["исслед", "research", "аналит", "данн"]) { return "🔎" }
        if containsAny(text, ["тест", "qa", "качест"]) { return "🧪" }
        if containsAny(text, ["продукт", "менедж", "product"]) { return "🧭" }
        if containsAny(text, ["писател", "редактор", "текст", "writer"]) { return "✍️" }
        if containsAny(text, ["разработ", "код", "developer", "програм"]) { return "🧑‍💻" }
        return "✨"
    }

    private static func color(for text: String) -> AgentAvatarColor {
        if containsAny(text, ["дизайн", "иллюстр", "творч"]) { return .pink }
        if containsAny(text, ["исслед", "аналит", "данн"]) { return .teal }
        if containsAny(text, ["тест", "qa", "качест"]) { return .green }
        if containsAny(text, ["продукт", "менедж"]) { return .orange }
        if containsAny(text, ["разработ", "код", "developer", "програм"]) { return .blue }
        return .indigo
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }
}
