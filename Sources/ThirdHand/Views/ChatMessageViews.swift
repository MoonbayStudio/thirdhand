import SwiftUI
import UniformTypeIdentifiers

struct ChatMessageRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let message: TaskMessage
    let agentPersona: AgentPersona?
    let agentName: String
    let quickReplies: [String]
    let onQuickReply: (String) -> Void
    let onCustomReply: () -> Void

    init(
        message: TaskMessage,
        agentPersona: AgentPersona? = nil,
        agentName: String = "Агент",
        quickReplies: [String] = [],
        onQuickReply: @escaping (String) -> Void = { _ in },
        onCustomReply: @escaping () -> Void = {}
    ) {
        self.message = message
        self.agentPersona = agentPersona
        self.agentName = agentName
        self.quickReplies = quickReplies
        self.onQuickReply = onQuickReply
        self.onCustomReply = onCustomReply
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom) {
                Spacer(minLength: 120)
                messageBubble
                    .background(
                        Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.11),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                    }
            }

        case .agent:
            HStack(alignment: .top, spacing: 10) {
                PersonaAvatarView(
                    imageData: agentPersona?.avatarImageData,
                    name: agentName,
                    color: agentPersona?.avatarColor ?? .indigo,
                    size: 30
                )

                VStack(alignment: .leading, spacing: 8) {
                    messageBubble
                        .background(
                            .thinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.separator.opacity(0.28), lineWidth: 0.5)
                        }

                    if !quickReplies.isEmpty {
                        QuickReplyButtons(
                            replies: quickReplies,
                            onReply: onQuickReply,
                            onCustomReply: onCustomReply
                        )
                    }
                }

                Spacer(minLength: 120)
            }

        case .system:
            systemEvent
        }
    }

    private var systemEvent: some View {
        let isError = message.text.localizedCaseInsensitiveContains("error")
            || message.text.localizedCaseInsensitiveContains("ошиб")
            || message.text.localizedCaseInsensitiveContains("failed")
        let tint = isError ? Color.red : Color.secondary

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)

            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 620, alignment: .leading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.fileAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(message.fileAttachments) { attachment in
                        Label(attachment.fileName, systemImage: attachment.systemImage)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                }
            }

            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620, alignment: .leading)
    }
}

struct AgentTypingRow: View {
    let persona: AgentPersona
    let agentName: String

    @State private var isAnimating = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PersonaAvatarView(
                imageData: persona.avatarImageData,
                name: agentName,
                color: persona.avatarColor,
                size: 30
            )

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(isAnimating ? 1 : 0.58)
                        .opacity(isAnimating ? 0.95 : 0.35)
                        .animation(
                            .easeInOut(duration: 0.52)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.14),
                            value: isAnimating
                        )
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator.opacity(0.28), lineWidth: 0.5)
            }

            Spacer(minLength: 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            isAnimating = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agentName) печатает")
    }
}

struct AgentWorkingRow: View {
    let run: AgentRunState
    let liveOutput: AgentLiveOutput?
    let persona: AgentPersona?
    let agentName: String
    let showsRawOutput: Bool
    let onRevealLiveOutput: () -> Void

    private var activity: AgentActivityPresentation {
        AgentActivityClassifier.presentation(for: run, output: liveOutput)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PersonaAvatarView(
                    imageData: persona?.avatarImageData,
                    name: agentName,
                    color: persona?.avatarColor ?? .indigo,
                    size: 36
                )

                ProgressView()
                    .controlSize(.mini)
                    .tint(run.agent.tint)
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.current.title)
                            .font(.callout.weight(.semibold))
                        Text(activity.current.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(run.agent.displayName)
                            .font(.caption.weight(.medium))
                        AgentRunElapsedText(startedAt: run.startedAt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(activity.recent.enumerated()), id: \.offset) { index, stage in
                            let isCurrent = index == activity.recent.count - 1
                            Label(stage.title, systemImage: stage.systemImage)
                                .font(.caption2.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? run.agent.tint : Color.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    isCurrent ? run.agent.tint.opacity(0.1) : Color.secondary.opacity(0.07),
                                    in: Capsule()
                                )
                        }
                    }
                }

                if let liveOutput,
                   !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(run.agent.tint)
                            .frame(width: 5, height: 5)
                        Text("Последнее событие")
                        Text(liveOutput.updatedAt, format: .dateTime.hour().minute().second())
                        if liveOutput.wasTruncated {
                            Text("· вывод сокращён")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                if showsRawOutput,
                   let liveOutput,
                   !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()

                    Text(trailingLines(liveOutput.text, maximumCount: 8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                } else if liveOutput?.text.isEmpty == false {
                    Button(action: onRevealLiveOutput) {
                        Label("Показать технический вывод", systemImage: "terminal")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 650, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    run.agent.tint.opacity(0.11),
                    Color(nsColor: .controlBackgroundColor).opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(run.agent.tint.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trailingLines(_ value: String, maximumCount: Int) -> String {
        value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        .suffix(maximumCount)
        .joined(separator: "\n")
    }
}

struct AgentActivityAccessory: View {
    let run: AgentRunState
    let output: AgentLiveOutput?

    private var activity: AgentActivityPresentation {
        AgentActivityClassifier.presentation(for: run, output: output)
    }

    var body: some View {
        HStack(spacing: 8) {
            ActivityPulse(tint: run.agent.tint, compact: true)

            Text(run.agent.shortName)
                .fontWeight(.semibold)

            Text("·")
                .foregroundStyle(.tertiary)

            Label(activity.current.title, systemImage: activity.current.systemImage)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            AgentRunElapsedText(startedAt: run.startedAt)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(run.agent.tint.opacity(0.075), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(run.agent.tint.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DraftAttachmentChip: View {
    let attachment: TaskAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.systemImage)
                .foregroundStyle(.secondary)

            Text(attachment.fileName)
                .lineLimit(1)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Убрать файл")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 25)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 240)
    }
}

private struct QuickReplyButtons: View {
    let replies: [String]
    let onReply: (String) -> Void
    let onCustomReply: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                buttons(lineLimit: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                buttons(lineLimit: 3)
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func buttons(lineLimit: Int) -> some View {
        ForEach(Array(replies.prefix(4).enumerated()), id: \.offset) { _, reply in
            Button {
                onReply(reply)
            } label: {
                Text(reply)
                    .lineLimit(lineLimit)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.bordered)
            .help("Ответить: \(reply)")
        }

        Button("Другой ответ…") {
            onCustomReply()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

extension TaskAttachment {
    var systemImage: String {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier)
        else {
            return "doc"
        }

        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .sourceCode) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if contentType.conforms(to: .plainText) { return "doc.text" }
        return "doc"
    }
}
