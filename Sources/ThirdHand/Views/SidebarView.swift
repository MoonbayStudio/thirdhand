import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            if !store.sortedGroupChats.isEmpty {
                Section("Групповые чаты") {
                    ForEach(store.sortedGroupChats) { group in
                        SidebarGroupChatRow(
                            group: group,
                            participants: store.participants(for: group),
                            activeRun: store.activeGroupRuns[group.id]
                        )
                        .tag(group.id)
                        .contextMenu {
                            if store.activeGroupRuns[group.id] != nil {
                                Button("Остановить обсуждение") {
                                    Task { await store.stopGroupChat(groupID: group.id) }
                                }
                            }

                            Button("Настроить участников") {
                                store.selection = group.id
                                store.isShowingInspector = true
                            }

                            Divider()

                            Button("Удалить групповой чат…", role: .destructive) {
                                store.requestGroupChatDeletion(group.id)
                            }
                        }
                    }
                }
            }

            Section("Агенты") {
                if store.agents.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Здесь появятся ваши агенты")
                            .font(.callout.weight(.medium))
                        Text("Создайте агента и начните отдельный чат.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(store.agents) { agent in
                        SidebarAgentRow(
                            agent: agent,
                            activeRun: store.activeRuns[agent.id],
                            liveOutput: store.liveAgentOutputs[agent.id]
                        )
                        .tag(agent.id)
                        .contextMenu {
                            if store.activeRuns[agent.id] != nil {
                                Button("Остановить") {
                                    Task { await store.stopAgentRun(taskID: agent.id) }
                                }
                            }

                            Button("Настроить агента") {
                                store.selection = agent.id
                                store.isShowingInspector = true
                            }

                            Divider()

                            Button("Удалить агента…", role: .destructive) {
                                store.requestTaskDeletion(agent.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 10, for: .scrollContent)
        .navigationTitle("Агенты")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .onAppear {
            if store.selection == nil {
                store.selection = store.agents.first?.id ?? store.sortedGroupChats.first?.id
            }
        }
        .onChange(of: store.selection) { _, agentID in
            guard let agentID,
                  store.tasks.contains(where: { $0.id == agentID })
            else {
                store.isShowingInspector = true
                return
            }
            store.isShowingInspector = true
            guard store.activeRuns[agentID] == nil,
                  store.activeValidations[agentID] == nil
            else {
                return
            }
            Task {
                await store.refreshGit(taskID: agentID, recordActivity: false)
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Menu {
                    Button {
                        store.beginAgentCreation()
                    } label: {
                        Label("Создать агента", systemImage: "person.crop.circle.badge.plus")
                    }

                    Button {
                        store.isShowingNewGroupChatSheet = true
                    } label: {
                        Label("Создать групповой чат…", systemImage: "person.3.fill")
                    }
                } label: {
                    Label("Создать", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityIdentifier("create-conversation-menu")

                Spacer(minLength: 12)

                Button {
                    store.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Настройки провайдеров")
                .accessibilityIdentifier("open-settings-button")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
    }
}

private struct SidebarGroupChatRow: View {
    let group: AgentGroupChat
    let participants: [CodingTask]
    let activeRun: GroupChatRunState?

    var body: some View {
        HStack(spacing: 10) {
            avatarStack

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(activeRun == nil ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Text("\(participants.count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Групповой чат \(group.title), \(participants.count) участника")
    }

    private var avatarStack: some View {
        HStack(spacing: -13) {
            ForEach(Array(participants.prefix(2).enumerated()), id: \.element.id) { index, participant in
                PersonaAvatarView(
                    imageData: participant.effectivePersona.avatarImageData,
                    name: participant.title,
                    color: participant.effectivePersona.avatarColor,
                    size: 35
                )
                .overlay {
                    Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                }
                .zIndex(Double(2 - index))
            }
        }
        .frame(width: 46, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusTint)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                }
        }
    }

    private var subtitle: String {
        if let activeRun {
            return activeRun.phase == .summarizing
                ? "\(activeRun.currentAgentName) подводит итог…"
                : "\(activeRun.currentAgentName) отвечает…"
        }
        if let preview = group.lastPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            return preview.replacingOccurrences(of: "\n", with: " ")
        }
        return participants.map(\.title).joined(separator: ", ")
    }

    private var statusTint: Color {
        if activeRun != nil { return .blue }
        switch group.status {
        case .ready: return .green
        case .discussing: return .blue
        case .needsAttention: return .red
        }
    }
}

private struct SidebarAgentRow: View {
    let agent: CodingTask
    let activeRun: AgentRunState?
    let liveOutput: AgentLiveOutput?

    private var persona: AgentPersona { agent.effectivePersona }

    private var activity: AgentActivityPresentation? {
        activeRun.map {
            AgentActivityClassifier.presentation(for: $0, output: liveOutput)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PersonaAvatarView(
                    imageData: persona.avatarImageData,
                    name: agent.title,
                    color: persona.avatarColor,
                    size: 40
                )

                Circle()
                    .fill(statusTint)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if persona.needsReview {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Проверьте черновик профиля")
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(activeRun?.executionTarget.tint ?? Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Text(
                agent.effectiveRoutingMode == .automatic
                    ? AppLocalization.string("Авто")
                    : agent.configuredExecutionSource == .api
                        ? agent.configuredAPITarget
                            .map { AgentExecutionTarget.api($0).shortName }
                            ?? AppLocalization.string("API")
                        : (agent.currentAgent?.shortName ?? AppLocalization.string("ИИ"))
            )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.string("Агент \(agent.title), \(subtitle)")
        )
    }

    private var subtitle: String {
        switch agent.onboardingStage {
        case .introducing:
            return AppLocalization.string("печатает…")
        case .awaitingIdentity:
            return AppLocalization.string("ждёт описания")
        case .configuring:
            return AppLocalization.string("настраивает профиль…")
        case nil:
            break
        }

        if let activeRun, !activeRun.presentsDetailedActivity {
            return AppLocalization.string("печатает…")
        }
        if let activeRun, let activity {
            return "\(activeRun.executionTarget.shortName) · \(activity.current.title.lowercased())"
        }
        if let lastMessage = agent.chatMessages.last?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !lastMessage.isEmpty {
            return lastMessage.replacingOccurrences(of: "\n", with: " ")
        }
        return persona.prompt.replacingOccurrences(of: "\n", with: " ")
    }

    private var statusTint: Color {
        if agent.onboardingStage != nil { return .blue }
        if activeRun != nil { return .blue }
        if persona.needsReview { return .orange }
        return agent.status == .needsAttention ? .red : .green
    }
}
