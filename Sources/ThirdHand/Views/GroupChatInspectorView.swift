import SwiftUI

struct GroupChatInspectorView: View {
    @Environment(AppStore.self) private var store
    let group: AgentGroupChat

    @State private var titleDraft: String

    init(group: AgentGroupChat) {
        self.group = group
        _titleDraft = State(initialValue: group.title)
    }

    private var isRunning: Bool {
        store.activeGroupRuns[group.id] != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                titleSection
                Divider()
                participantsSection
                Divider()
                addressingSection
                Divider()
                deleteSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
        .background(.ultraThinMaterial)
        .navigationTitle("Группа")
        .onChange(of: group.id) { _, _ in
            titleDraft = group.title
        }
        .onChange(of: group.title) { _, newTitle in
            guard titleDraft == group.title || !titleDraft.isEmpty else { return }
            titleDraft = newTitle
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            avatarStack

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("\(group.participantIDs.count) участника")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var avatarStack: some View {
        let participants = store.participants(for: group)
        return HStack(spacing: -12) {
            ForEach(Array(participants.prefix(3).enumerated()), id: \.element.id) { index, participant in
                PersonaAvatarView(
                    imageData: participant.effectivePersona.avatarImageData,
                    name: participant.title,
                    color: participant.effectivePersona.avatarColor,
                    size: 46
                )
                .overlay {
                    Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                }
                .zIndex(Double(3 - index))
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Название")
            TextField("Название чата", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
                .onSubmit(saveTitle)

            Button("Сохранить название", action: saveTitle)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    isRunning
                        || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || titleDraft == group.title
                )
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Участники")

            if store.groupChatEligibleAgents.isEmpty {
                Text("Нет доступных агентов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.groupChatEligibleAgents) { agent in
                    participantToggle(agent)
                }
            }

            Text("Минимум 2, максимум 8. Новый состав получит общую историю при следующем сообщении.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func participantToggle(_ agent: CodingTask) -> some View {
        let isSelected = group.participantIDs.contains(agent.id)
        return Toggle(isOn: participantBinding(agent.id)) {
            HStack(spacing: 9) {
                PersonaAvatarView(
                    imageData: agent.effectivePersona.avatarImageData,
                    name: agent.title,
                    color: agent.effectivePersona.avatarColor,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(GroupChatPromptBuilder.shortRole(for: agent))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(
            isRunning
                || (isSelected && group.participantIDs.count <= 2)
                || (!isSelected && group.participantIDs.count >= 8)
        )
    }

    private var addressingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Обращения по имени")
            Label("Символ @ не нужен", systemImage: "textformat")
                .font(.callout.weight(.medium))
            Text(addressingExample)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var addressingExample: String {
        let participants = store.participants(for: group)
        guard participants.count >= 2 else {
            return "Добавьте ещё одного участника."
        }
        return "Напишите: «\(participants[0].title), обсудите с \(participants[1].title)…». Если не указать ни одного имени, ответит вся группа."
    }

    private var deleteSection: some View {
        Button("Удалить групповой чат…", role: .destructive) {
            store.requestGroupChatDeletion(group.id)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .disabled(isRunning)
    }

    private func participantBinding(_ agentID: UUID) -> Binding<Bool> {
        Binding(
            get: { group.participantIDs.contains(agentID) },
            set: { isSelected in
                var ids = group.participantIDs
                if isSelected {
                    if !ids.contains(agentID) {
                        ids.append(agentID)
                    }
                } else {
                    ids.removeAll { $0 == agentID }
                }
                store.updateGroupParticipants(ids, groupID: group.id)
            }
        )
    }

    private func saveTitle() {
        store.renameGroupChat(group.id, title: titleDraft)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
