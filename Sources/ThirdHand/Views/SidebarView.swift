import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
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
        .listStyle(.sidebar)
        .contentMargins(.top, 10, for: .scrollContent)
        .navigationTitle("Агенты")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .onAppear {
            if store.selection == nil {
                store.selection = store.agents.first?.id
            }
        }
        .onChange(of: store.selection) { _, agentID in
            guard let agentID else { return }
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
                Button {
                    store.beginAgentCreation()
                } label: {
                    Label("Создать агента", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("create-agent-button")

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
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
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
                    .foregroundStyle(activeRun?.agent.tint ?? Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Text(agent.effectiveRoutingMode == .automatic ? "Авто" : (agent.currentAgent?.shortName ?? "ИИ"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Агент \(agent.title), \(subtitle)")
    }

    private var subtitle: String {
        switch agent.onboardingStage {
        case .introducing:
            return "печатает…"
        case .awaitingIdentity:
            return "ждёт описания"
        case .configuring:
            return "настраивает профиль…"
        case nil:
            break
        }

        if let activeRun, let activity {
            return "\(activeRun.agent.shortName) · \(activity.current.title.lowercased())"
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
