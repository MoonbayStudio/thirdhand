import Foundation

struct AgentProgressReport: Codable, Equatable, Sendable {
    var decisions: [String]
    var progress: [String]
    var knownIssues: [String]
    var nextStep: String
    var completedSteps: [String]
}

struct ParsedAgentResponse: Equatable, Sendable {
    let displayText: String
    let progressReport: AgentProgressReport?
}

enum AgentProgressReportParser {
    static let openingMarker = "<<<THIRD_HAND_STATUS>>>"
    static let closingMarker = "<<<END_THIRD_HAND_STATUS>>>"

    static func parse(_ response: String) -> ParsedAgentResponse {
        guard let openingRange = response.range(of: openingMarker, options: .backwards),
              let closingRange = response.range(
                of: closingMarker,
                range: openingRange.upperBound..<response.endIndex
              )
        else {
            return ParsedAgentResponse(
                displayText: response.trimmingCharacters(in: .whitespacesAndNewlines),
                progressReport: nil
            )
        }

        let jsonText = response[openingRange.upperBound..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentProgressReport.self, from: data)
        else {
            return ParsedAgentResponse(
                displayText: response.trimmingCharacters(in: .whitespacesAndNewlines),
                progressReport: nil
            )
        }

        let prefix = String(response[..<openingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(response[closingRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = [prefix, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return ParsedAgentResponse(
            displayText: displayText.isEmpty ? "Агент завершил этап." : displayText,
            progressReport: sanitized(decoded)
        )
    }

    private static func sanitized(_ report: AgentProgressReport) -> AgentProgressReport {
        AgentProgressReport(
            decisions: sanitizeList(report.decisions),
            progress: sanitizeList(report.progress),
            knownIssues: sanitizeList(report.knownIssues),
            nextStep: sanitize(report.nextStep, maximumCharacters: 600),
            completedSteps: sanitizeList(report.completedSteps, maximumCount: 12)
        )
    }

    private static func sanitizeList(
        _ values: [String],
        maximumCount: Int = 4
    ) -> [String] {
        Array(
            values
                .map { sanitize($0, maximumCharacters: 600) }
                .filter { !$0.isEmpty }
                .prefix(maximumCount)
        )
    }

    private static func sanitize(_ value: String, maximumCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters))
    }
}
