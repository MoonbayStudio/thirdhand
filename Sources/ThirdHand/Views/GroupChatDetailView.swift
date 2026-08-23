import SwiftUI

struct GroupChatDetailView: View {
    @Environment(AppStore.self) private var store
    let group: AgentGroupChat

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    private var participants: [CodingTask] {
        store.participants(for: group)
    }

    private var mentionedParticipants: [CodingTask] {
        store.mentionedParticipants(in: draft, group: group)
    }

    private var activeRun: GroupChatRunState? {
        store.activeGroupRuns[group.id]
    }

    var body: some View {
        TransparentVSplitView(
            top: messageList,
            bottom: composer,
            minimumTopHeight: 240,
            minimumBottomHeight: 145,
            idealBottomHeight: 175,
            maximumBottomHeight: 310
        )
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toolbarIdentity
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    InspectorToggleButton()
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    InspectorToggleButton()
                }
            }
        }
        .background {
            DetailCanvasBackground()
        }
        .onAppear {
            isComposerFocused = true
        }
        .onChange(of: group.id) {
            draft = ""
            isComposerFocused = true
        }
    }

    private var toolbarIdentity: some View {
        HStack(spacing: 10) {
            participantAvatarStack(size: 29, maximumCount: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(participantNames)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: 270, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Групповой чат \(group.title), участники: \(participantNames)")
    }

    private var participantNames: String {
        let names = participants.map(\.title)
        return names.isEmpty ? "Нет доступных участников" : names.joined(separator: ", ")
    }

    private func participantAvatarStack(
        size: CGFloat,
        maximumCount: Int
    ) -> some View {
        HStack(spacing: -8) {
            ForEach(Array(participants.prefix(maximumCount).enumerated()), id: \.element.id) { index, participant in
                PersonaAvatarView(
                    imageData: participant.effectivePersona.avatarImageData,
                    name: participant.title,
                    color: participant.effectivePersona.avatarColor,
                    size: size
                )
                .overlay {
                    Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                }
                .zIndex(Double(maximumCount - index))
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 17) {
                    if !group.messages.contains(where: { $0.role == .user }) {
                        discussionHint
                    }

                    ForEach(group.messages) { message in
                        GroupChatMessageRow(
                            message: message,
                            sender: message.senderAgentID.flatMap { senderID in
                                store.tasks.first { $0.id == senderID }
                            }
                        )
                        .id(message.id)
                    }

                    if let activeRun {
                        GroupChatTypingRow(
                            run: activeRun,
                            participant: store.tasks.first { $0.id == activeRun.currentAgentID }
                        )
                        .id("group-run-\(activeRun.attemptID.uuidString)")
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: group.messages.count) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: activeRun?.attemptID) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
    }

    private var discussionHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Позовите агентов по имени", systemImage: "text.bubble")
                .font(.headline)
            Text(examplePrompt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Если имён в сообщении нет, обсуждать будут все участники группы.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.28), lineWidth: 0.5)
        }
    }

    private var examplePrompt: String {
        guard participants.count >= 2 else {
            return "Добавьте ещё одного агента в правой панели."
        }
        return "Например: «\(participants[0].title), обсудите с \(participants[1].title) идею приложения». Символ @ не нужен."
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(participants) { participant in
                        let isMentioned = mentionedParticipants.contains { $0.id == participant.id }
                        Button {
                            insertName(participant.title)
                        } label: {
                            HStack(spacing: 5) {
                                if isMentioned {
                                    Image(systemName: "checkmark")
                                }
                                Text(participant.title)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(isMentioned ? Color.accentColor : Color.secondary)
                            .background(
                                isMentioned
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.secondary.opacity(0.075),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Вставить имя \(participant.title)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Сообщение группе…",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .disabled(activeRun != nil || participants.count < 2)
                .onSubmit(send)
                .accessibilityIdentifier("group-chat-composer")

                HStack(spacing: 8) {
                    if mentionedParticipants.isEmpty {
                        Text("Без имени ответят все")
                    } else {
                        Text("Отвечают: \(mentionedParticipants.map(\.title).joined(separator: ", "))")
                    }
                    Spacer(minLength: 12)

                    if activeRun != nil {
                        Button {
                            Task { await store.stopGroupChat(groupID: group.id) }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.red, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Остановить обсуждение")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(
                                    canSend ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Начать обсуждение")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeRun == nil
            && participants.count >= 2
    }

    private func insertName(_ name: String) {
        guard !draft.localizedCaseInsensitiveContains(name) else {
            isComposerFocused = true
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? "\(name), " : "\(trimmed) \(name), "
        isComposerFocused = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeRun == nil, participants.count >= 2 else { return }
        draft = ""
        isComposerFocused = true
        Task {
            await store.submitGroupMessage(groupID: group.id, text: text)
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        let target: AnyHashable?
        if let activeRun {
            target = "group-run-\(activeRun.attemptID.uuidString)"
        } else {
            target = group.messages.last?.id
        }
        guard let target else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }
}

private struct GroupChatMessageRow: View {
    let message: GroupChatMessage
    let sender: CodingTask?

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom) {
                Spacer(minLength: 110)
                messageBubble
                    .background(
                        Color.accentColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }

        case .agent:
            HStack(alignment: .top, spacing: 10) {
                PersonaAvatarView(
                    imageData: sender?.effectivePersona.avatarImageData,
                    name: message.senderName ?? sender?.title ?? "Агент",
                    color: sender?.effectivePersona.avatarColor ?? .indigo,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(message.senderName ?? sender?.title ?? "Агент")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sender?.effectivePersona.avatarColor.tint ?? Color.secondary)
                    messageBubble
                        .background(
                            .thinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.separator.opacity(0.28), lineWidth: 0.5)
                        }
                }

                Spacer(minLength: 90)
            }

        case .summary:
            VStack(alignment: .leading, spacing: 8) {
                Label("Итог обсуждения", systemImage: "checkmark.bubble.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                executionFooter
            }
            .padding(14)
            .frame(maxWidth: 650, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.7)
            }
            .frame(maxWidth: .infinity)

        case .system:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.3.sequence.fill")
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 650, alignment: .leading)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
        }
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            executionFooter
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var executionFooter: some View {
        HStack(spacing: 6) {
            Text(message.createdAt, format: .dateTime.hour().minute())
            if let source = message.executionSource,
               let targetName = message.executionTargetName {
                Text("·")
                Label(
                    "\(source.title) · \(targetName)",
                    systemImage: source == .cli ? "terminal" : "key.horizontal"
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct GroupChatTypingRow: View {
    let run: GroupChatRunState
    let participant: CodingTask?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PersonaAvatarView(
                imageData: participant?.effectivePersona.avatarImageData,
                name: run.currentAgentName,
                color: participant?.effectivePersona.avatarColor ?? .indigo,
                size: 32
            )

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(.thinMaterial, in: Capsule())

            Spacer(minLength: 90)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var statusText: String {
        switch run.phase {
        case .discussing:
            "\(run.currentAgentName) отвечает через \(run.executionTarget.shortName)…"
        case .summarizing:
            "\(run.currentAgentName) подводит итог через \(run.executionTarget.shortName)…"
        }
    }
}
