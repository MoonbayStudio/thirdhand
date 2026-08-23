import Foundation
import UniformTypeIdentifiers

struct PreparedAgentInvocation: Sendable {
    let invocation: AgentCLIInvocation
    let responseFileURL: URL?
}

enum AgentCLIInvocationFactory {
    static func prepare(
        request: AgentExecutionRequest,
        temporaryDirectory: URL
    ) -> PreparedAgentInvocation {
        var environment = ExecutableResolver.environment(
            forExecutablePath: request.executablePath
        )
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"

        let attachmentDirectories = externalAttachmentDirectories(
            request.attachments,
            repositoryPath: request.repositoryPath
        )

        switch request.agent {
        case .codex:
            let responseFileURL = temporaryDirectory
                .appendingPathComponent("\(request.attemptID.uuidString)-codex-response.txt")
            var arguments: [String] = []

            if let approvalPolicy = request.configuration[AgentOptionID.approvalPolicy.rawValue] {
                arguments += ["--ask-for-approval", approvalPolicy]
            }

            arguments += [
                "exec",
                "--color", "never",
                "--cd", request.repositoryPath,
                "--output-last-message", responseFileURL.path
            ]

            if let model = request.configuration[AgentOptionID.model.rawValue] {
                arguments += ["--model", model]
            }
            if let sandbox = request.configuration[AgentOptionID.sandboxMode.rawValue] {
                arguments += ["--sandbox", sandbox]
            }
            if let effort = request.configuration[AgentOptionID.reasoningEffort.rawValue] {
                arguments += ["--config", tomlOverride(key: "model_reasoning_effort", value: effort)]
            }
            if request.configuration[AgentOptionID.speedTier.rawValue] == "priority" {
                arguments += [
                    "--config", "features.fast_mode=true",
                    "--config", tomlOverride(key: "service_tier", value: "fast")
                ]
            }
            if !request.isGitRepository {
                arguments.append("--skip-git-repo-check")
            }

            for directory in attachmentDirectories {
                arguments += ["--add-dir", directory]
            }
            for attachment in request.attachments where isImage(attachment) {
                arguments += ["--image", attachment.filePath]
            }
            arguments.append(request.prompt)

            return PreparedAgentInvocation(
                invocation: invocation(request: request, arguments: arguments, environment: environment),
                responseFileURL: responseFileURL
            )

        case .claudeCode:
            var arguments = [
                "--print",
                "--input-format", "text",
                "--output-format", "json",
                "--no-session-persistence"
            ]

            if let model = request.configuration[AgentOptionID.model.rawValue], model != "default" {
                arguments += ["--model", model]
            }
            if let effort = request.configuration[AgentOptionID.reasoningEffort.rawValue] {
                arguments += ["--effort", effort]
            }
            if let permissionMode = request.configuration[AgentOptionID.permissionMode.rawValue] {
                arguments += ["--permission-mode", permissionMode]
            }
            for directory in attachmentDirectories {
                arguments += ["--add-dir", directory]
            }
            arguments.append(request.prompt)

            return PreparedAgentInvocation(
                invocation: invocation(request: request, arguments: arguments, environment: environment),
                responseFileURL: nil
            )

        case .antigravity:
            var arguments: [String] = []

            if let model = request.configuration[AgentOptionID.model.rawValue] {
                arguments += ["--model", model]
            }
            if let mode = request.configuration[AgentOptionID.executionMode.rawValue] {
                arguments += ["--mode", mode]
            }
            if request.configuration[AgentOptionID.sandboxMode.rawValue] == "enabled" {
                arguments.append("--sandbox")
            }
            for directory in attachmentDirectories {
                arguments += ["--add-dir", directory]
            }
            arguments += ["--print-timeout", "5m", "--print=\(request.prompt)"]

            return PreparedAgentInvocation(
                invocation: invocation(request: request, arguments: arguments, environment: environment),
                responseFileURL: nil
            )
        }
    }

    private static func invocation(
        request: AgentExecutionRequest,
        arguments: [String],
        environment: [String: String]
    ) -> AgentCLIInvocation {
        AgentCLIInvocation(
            attemptID: request.attemptID,
            executablePath: request.executablePath,
            arguments: arguments,
            workingDirectory: request.repositoryPath,
            environment: environment
        )
    }

    private static func externalAttachmentDirectories(
        _ attachments: [TaskAttachment],
        repositoryPath: String
    ) -> [String] {
        let repositoryURL = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        let repositoryPrefix = repositoryURL.path.hasSuffix("/")
            ? repositoryURL.path
            : repositoryURL.path + "/"

        return Array(Set(attachments.compactMap { attachment in
            let fileURL = attachment.fileURL.standardizedFileURL
            guard !fileURL.path.hasPrefix(repositoryPrefix) else { return nil }
            return fileURL.deletingLastPathComponent().path
        })).sorted()
    }

    private static func isImage(_ attachment: TaskAttachment) -> Bool {
        guard let identifier = attachment.contentTypeIdentifier,
              let contentType = UTType(identifier)
        else {
            return false
        }
        return contentType.conforms(to: .image)
    }

    private static func tomlOverride(key: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)=\"\(escaped)\""
    }
}
