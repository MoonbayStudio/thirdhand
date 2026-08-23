import Foundation

enum TaskEnvelopeBuilder {
    static func build(
        task: CodingTask,
        currentInstruction: String,
        attachments: [TaskAttachment],
        repositoryContext: RepositoryHandoffContext
    ) -> String {
        let specification = task.effectiveSpecification
        let persona = task.effectivePersona
        let completedSteps = task.steps.filter(\.isCompleted).map(\.title)
        let remainingSteps = task.steps.filter { !$0.isCompleted }.map(\.title)
        let validationSummary = task.validations.map { validation in
            let freshness: String
            switch validation.outcome {
            case .passed, .failed:
                freshness = validation.isFresh(for: task.gitSnapshot)
                    ? "fresh"
                    : "stale"
            case .notRun, .running, .cancelled:
                freshness = "not-applicable"
            }
            let fingerprint = validation.gitFingerprint ?? "none"
            let capturedAt = validation.finishedAt?.ISO8601Format() ?? "unknown"
            return "- \(validation.name): \(validation.outcome.title). \(validation.summary) [freshness: \(freshness); fingerprint: \(fingerprint); capturedAt: \(capturedAt)]"
        }
        let attachmentSummary = attachments.map {
            "- \($0.fileName): \($0.filePath)"
        }

        return """
        You are \(task.title), a persistent AI agent managed by Third Hand. Follow the personality contract below in every response while still being accurate and safe. Conversation history is intentionally unavailable. The repository is the source of truth.

        <agent_persona name="\(escapedAttribute(task.title))">
        \(persona.prompt)
        </agent_persona>

        <original_task>
        \(task.originalRequest.isEmpty ? currentInstruction : task.originalRequest)
        </original_task>

        <task_specification revision="\(specification.revision)">
        Current objective:
        \(specification.objective.isEmpty ? "- Not specified." : specification.objective)

        User requirement updates:
        \(bulletList(specification.requirementUpdates))

        Constraints:
        \(bulletList(specification.constraints))

        Acceptance criteria:
        \(bulletList(specification.acceptanceCriteria))

        Accepted product decisions:
        \(bulletList(specification.productDecisions))

        Out of scope or cancelled requirements — do not reintroduce:
        \(bulletList(specification.outOfScope))

        Open questions — do not guess:
        \(bulletList(specification.openQuestions))
        </task_specification>

        <current_instruction>
        \(currentInstruction)
        </current_instruction>

        <repository>
        \(task.repositoryPath)
        </repository>

        <git_status>
        \(repositoryContext.status)
        </git_status>

        <git_diff_stat>
        \(repositoryContext.diffStat)
        </git_diff_stat>

        <git_diff>
        \(repositoryContext.diff)
        </git_diff>

        <semantic_handoff>
        Architectural decisions:
        \(bulletList(task.handoff.decisions))

        Current progress:
        \(bulletList(task.handoff.progress))

        Known issues:
        \(bulletList(task.handoff.knownIssues))

        Recommended next step:
        \(task.handoff.nextStep)
        </semantic_handoff>

        <steps>
        Completed:
        \(bulletList(completedSteps))

        Remaining:
        \(bulletList(remainingSteps))
        </steps>

        <latest_validation_results>
        \(validationSummary.isEmpty ? "- No recorded build or test results." : validationSummary.joined(separator: "\n"))
        </latest_validation_results>

        <attached_files>
        \(attachmentSummary.isEmpty ? "- None." : attachmentSummary.joined(separator: "\n"))
        </attached_files>

        Mandatory continuation protocol:
        1. Inspect the repository and current git diff before changing anything.
        2. Do not assume previous changes are correct.
        3. Treat task_specification as the current contract. The original task is historical context.
        4. If current_instruction conflicts with task_specification, report the conflict instead of silently rewriting the contract.
        5. Determine what is implemented, incomplete, or architecturally wrong.
        6. Continue the Task in the repository and run relevant checks when practical.
        7. Finish with a concise user-facing summary.
        8. At the very end, add the following machine-readable block. Keep every array to at most four short items. completedSteps may contain only exact titles from the Remaining list above.

        <<<THIRD_HAND_STATUS>>>
        {"decisions":[],"progress":[],"knownIssues":[],"nextStep":"","completedSteps":[]}
        <<<END_THIRD_HAND_STATUS>>>
        """
    }

    private static func bulletList(_ values: [String]) -> String {
        values.isEmpty ? "- None." : values.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
